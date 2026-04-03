#!/usr/bin/env python3
import errno
import fcntl
import html
import json
import os
import re
import signal
import sys
import time
from collections import OrderedDict
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:
    import requests  # type: ignore
except Exception:  # pragma: no cover
    requests = None

import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

WORK_DIR = Path("/root/TrafficCop")
CONFIG_FILE = WORK_DIR / "node_config.txt"
LOG_FILE = WORK_DIR / "node.log"
CRON_LOG = WORK_DIR / "node_cron.log"
STATE_JSON = WORK_DIR / "node_state.json"
LAST_NODE_TXT = WORK_DIR / "last_node.txt"
CACHE_JSON = WORK_DIR / ".node_http_cache.json"
PID_FILE = WORK_DIR / ".node_python.pid"
LOCK_FILE = WORK_DIR / ".node_python.lock"
LOG_RESET_FILE = WORK_DIR / ".log_last_reset_day"

DEFAULT_URL = "https://rss.nodeseek.com/?sortBy=postTime"
MAX_STATE_ENTRIES = 200
MATCH_WINDOW = 30
MANUAL_PUSH_WINDOW = 20
HTTP_TIMEOUT = 10
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36"
)


def ensure_workdir() -> None:
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    for p in (LOG_FILE, CRON_LOG):
        if not p.exists():
            p.touch()


def now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def fmt_time() -> str:
    return datetime.now().strftime("%Y.%m.%d.%H:%M")


class Logger:
    def __init__(self, debug: bool = False):
        self.debug = debug

    def _write(self, path: Path, message: str) -> None:
        with path.open("a", encoding="utf-8") as fh:
            fh.write(f"{now_str()} {message}\n")

    def info(self, message: str) -> None:
        if self.debug:
            self._write(LOG_FILE, message)

    def event(self, message: str) -> None:
        self._write(CRON_LOG, message)

    def error(self, message: str) -> None:
        self._write(LOG_FILE, message)


def parse_shell_config(path: Path) -> Dict[str, str]:
    data: Dict[str, str] = {}
    if not path.exists() or path.stat().st_size == 0:
        return data
    pattern = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
    with path.open("r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            m = pattern.match(line)
            if not m:
                continue
            key, raw_val = m.group(1), m.group(2).strip()
            if len(raw_val) >= 2 and raw_val[0] == raw_val[-1] and raw_val[0] in {'"', "'"}:
                val = raw_val[1:-1]
                val = val.replace(r'\"', '"').replace(r"\\", "\\")
            else:
                val = raw_val
            data[key] = val
    return data


def load_runtime_config() -> Dict[str, str]:
    cfg = parse_shell_config(CONFIG_FILE)
    cfg.setdefault("NS_URL", DEFAULT_URL)
    cfg.setdefault("INTERVAL_SEC", "20")
    cfg.setdefault("KEYWORDS", "")
    cfg.setdefault("DEBUG_LOG", "0")
    return cfg


def validate_config(cfg: Dict[str, str]) -> Tuple[bool, str]:
    required = ["TG_BOT_TOKEN", "TG_PUSH_CHAT_ID", "NS_URL"]
    for key in required:
        if not cfg.get(key):
            return False, f"配置不完整，缺少 {key}"
    try:
        interval = int(cfg.get("INTERVAL_SEC", "20"))
    except ValueError:
        return False, "INTERVAL_SEC 必须是数字"
    if interval < 15:
        return False, "INTERVAL_SEC 最低 15"
    return True, ""


def safe_int(value: str, default: int = 0) -> int:
    try:
        return int(value)
    except Exception:
        return default


class Transport:
    def get(self, url: str, headers: Dict[str, str], timeout: int):
        raise NotImplementedError

    def post_form(self, url: str, data: Dict[str, str], timeout: int):
        raise NotImplementedError


class RequestsTransport(Transport):
    def __init__(self):
        self.session = requests.Session()  # type: ignore[union-attr]
        adapter = requests.adapters.HTTPAdapter(pool_connections=2, pool_maxsize=4)  # type: ignore[attr-defined]
        self.session.mount("https://", adapter)
        self.session.mount("http://", adapter)

    def get(self, url: str, headers: Dict[str, str], timeout: int):
        resp = self.session.get(url, headers=headers, timeout=timeout)
        return resp.status_code, dict(resp.headers), resp.content

    def post_form(self, url: str, data: Dict[str, str], timeout: int):
        resp = self.session.post(url, data=data, timeout=timeout)
        return resp.status_code, dict(resp.headers), resp.content


class UrllibTransport(Transport):
    def __init__(self):
        self.opener = urllib.request.build_opener()

    def get(self, url: str, headers: Dict[str, str], timeout: int):
        req = urllib.request.Request(url=url, headers=headers, method="GET")
        try:
            with self.opener.open(req, timeout=timeout) as resp:
                return resp.getcode(), dict(resp.headers.items()), resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, dict(exc.headers.items()) if exc.headers else {}, exc.read()

    def post_form(self, url: str, data: Dict[str, str], timeout: int):
        encoded = urllib.parse.urlencode(data).encode("utf-8")
        req = urllib.request.Request(url=url, data=encoded, method="POST")
        with self.opener.open(req, timeout=timeout) as resp:
            return resp.getcode(), dict(resp.headers.items()), resp.read()


def build_transport() -> Transport:
    if requests is not None:
        return RequestsTransport()
    return UrllibTransport()


class KeywordMatcher:
    def __init__(self, raw_keywords: str):
        self.tokens: List[Tuple[str, str, Optional[str]]] = []
        raw_keywords = raw_keywords.replace(",", " ")
        for token in raw_keywords.split():
            token = token.strip().lower()
            if not token:
                continue
            compact = token.replace(" ", "")
            if "&" in compact:
                left, right = compact.split("&", 1)
                if left and right:
                    self.tokens.append(("and", left, right))
            else:
                self.tokens.append(("single", compact, None))

    def match(self, title: str) -> str:
        if not self.tokens:
            return ""
        t = title.lower()
        for kind, a, b in self.tokens:
            if kind == "single":
                if a in t:
                    return a
            else:
                if a in t and b and b in t:
                    return f"{a}&{b}"
        return ""


class StateStore:
    def __init__(self):
        self.entries: "OrderedDict[str, Dict[str, object]]" = OrderedDict()

    @staticmethod
    def _sort_key(entry: Dict[str, object]) -> Tuple[int, int, str]:
        id_str = str(entry.get("id", ""))
        if id_str.isdigit():
            return (0, int(id_str), id_str)
        nums = re.findall(r"\d+", id_str)
        if nums:
            return (0, int(nums[-1]), id_str)
        return (1, 0, id_str)

    def load(self) -> None:
        self.entries = OrderedDict()
        if STATE_JSON.exists() and STATE_JSON.stat().st_size > 0:
            with STATE_JSON.open("r", encoding="utf-8") as fh:
                raw = json.load(fh)
            for item in raw.get("entries", []):
                entry = {
                    "id": str(item.get("id", "")),
                    "title": str(item.get("title", "")),
                    "url": str(item.get("url", "")),
                    "sent": bool(item.get("sent", False)),
                    "seen_at": str(item.get("seen_at", "")),
                }
                if entry["id"]:
                    self.entries[entry["id"]] = entry
            self._normalize()
            return

        if LAST_NODE_TXT.exists() and LAST_NODE_TXT.stat().st_size > 0:
            with LAST_NODE_TXT.open("r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    parts = line.split("|", 3)
                    if len(parts) < 3:
                        continue
                    id_, title, url = parts[0], parts[1], parts[2]
                    sent = len(parts) >= 4 and parts[3] == "1"
                    self.entries[id_] = {
                        "id": id_,
                        "title": title,
                        "url": url,
                        "sent": sent,
                        "seen_at": "",
                    }
            self._normalize()
            self.save()

    def _normalize(self) -> None:
        items = sorted(self.entries.values(), key=self._sort_key)
        if len(items) > MAX_STATE_ENTRIES:
            items = items[-MAX_STATE_ENTRIES:]
        self.entries = OrderedDict((str(item["id"]), item) for item in items)

    def save(self) -> None:
        self._normalize()
        payload = {"entries": list(self.entries.values())}
        tmp = STATE_JSON.with_suffix(".tmp")
        with tmp.open("w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
        tmp.replace(STATE_JSON)
        self.export_last_node_txt()

    def export_last_node_txt(self) -> None:
        tmp = LAST_NODE_TXT.with_suffix(".tmp")
        with tmp.open("w", encoding="utf-8") as fh:
            for entry in self.entries.values():
                sent = "1" if entry.get("sent") else "0"
                fh.write(f"{entry['id']}|{entry['title']}|{entry['url']}|{sent}\n")
        tmp.replace(LAST_NODE_TXT)

    def merge_posts(self, posts: List[Dict[str, str]]) -> int:
        changes = 0
        now_value = now_str()
        for post in posts:
            old = self.entries.get(post["id"])
            if old is None:
                self.entries[post["id"]] = {
                    "id": post["id"],
                    "title": post["title"],
                    "url": post["url"],
                    "sent": False,
                    "seen_at": now_value,
                }
                changes += 1
                continue
            if old.get("title") != post["title"] or old.get("url") != post["url"]:
                old["title"] = post["title"]
                old["url"] = post["url"]
                changes += 1
        self._normalize()
        return changes

    def latest_entries(self, limit: int) -> List[Dict[str, object]]:
        return list(self.entries.values())[-limit:]


class NodeMonitor:
    def __init__(self):
        ensure_workdir()
        self.transport = build_transport()
        self.cache = self._load_cache()
        self.logger = Logger(False)
        self.config = load_runtime_config()
        self.state = StateStore()
        self.state.load()

    def reload_config(self) -> None:
        self.config = load_runtime_config()
        self.logger.debug = self.config.get("DEBUG_LOG", "0") == "1"

    def _load_cache(self) -> Dict[str, str]:
        if CACHE_JSON.exists() and CACHE_JSON.stat().st_size > 0:
            try:
                with CACHE_JSON.open("r", encoding="utf-8") as fh:
                    raw = json.load(fh)
                return {"last_modified": str(raw.get("last_modified", "")), "etag": str(raw.get("etag", ""))}
            except Exception:
                return {"last_modified": "", "etag": ""}
        return {"last_modified": "", "etag": ""}

    def _save_cache(self) -> None:
        tmp = CACHE_JSON.with_suffix(".tmp")
        with tmp.open("w", encoding="utf-8") as fh:
            json.dump(self.cache, fh, ensure_ascii=False, indent=2)
        tmp.replace(CACHE_JSON)

    def _http_headers(self) -> Dict[str, str]:
        headers = {
            "User-Agent": USER_AGENT,
            "Accept": "application/rss+xml, application/xml;q=0.9, */*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Connection": "keep-alive",
        }
        if self.cache.get("last_modified"):
            headers["If-Modified-Since"] = self.cache["last_modified"]
        if self.cache.get("etag"):
            headers["If-None-Match"] = self.cache["etag"]
        return headers

    def fetch_rss(self) -> Tuple[str, Optional[bytes]]:
        url = self.config.get("NS_URL", DEFAULT_URL)
        try:
            code, headers, body = self.transport.get(url, self._http_headers(), HTTP_TIMEOUT)
        except Exception as exc:
            self.logger.error(f"[node] RSS请求异常: {exc}")
            return "error", None

        if code == 304:
            self.logger.info("[node] RSS未更新（304）")
            return "not_modified", None

        if code != 200:
            self.logger.error(f"[node] RSS请求失败 HTTP={code}")
            return "error", None

        lm = headers.get("Last-Modified") or headers.get("last-modified")
        etag = headers.get("ETag") or headers.get("etag")
        if lm:
            self.cache["last_modified"] = lm.strip()
        if etag:
            self.cache["etag"] = etag.strip()
        self._save_cache()
        return "ok", body

    @staticmethod
    def _local_name(tag: str) -> str:
        if "}" in tag:
            return tag.rsplit("}", 1)[1]
        return tag

    def parse_posts(self, payload: bytes) -> Tuple[str, List[Dict[str, str]]]:
        text_sample = payload[:5120].decode("utf-8", errors="ignore")
        if re.search(r"Just a moment|cf-turnstile|challenge-platform|captcha", text_sample, flags=re.I):
            return "blocked", []
        try:
            root = ET.fromstring(payload)
        except ET.ParseError as exc:
            self.logger.error(f"[node] RSS解析失败: {exc}")
            return "error", []

        posts: List[Dict[str, str]] = []
        for elem in root.iter():
            if self._local_name(elem.tag) != "item":
                continue
            title = ""
            link = ""
            guid = ""
            for child in list(elem):
                name = self._local_name(child.tag)
                text = (child.text or "").strip()
                if name == "title":
                    title = html.unescape(text)
                elif name == "link":
                    link = text
                elif name == "guid":
                    guid = text
            id_ = guid if guid.isdigit() else ""
            if not id_:
                m = re.search(r"post-(\d+)-1", link)
                if m:
                    id_ = m.group(1)
            if id_ and title and link:
                posts.append({"id": id_, "title": title, "url": link})
            if len(posts) >= 120:
                break
        if not posts:
            return "empty", []
        return "ok", posts

    def telegram_send(self, content: str) -> bool:
        token = self.config.get("TG_BOT_TOKEN", "")
        chat_id = self.config.get("TG_PUSH_CHAT_ID", "")
        if not token or not chat_id:
            self.logger.error("[node] Telegram配置缺失，发送失败")
            return False
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        data = {
            "chat_id": chat_id,
            "text": content,
            "disable_web_page_preview": "true",
        }
        try:
            code, _, body = self.transport.post_form(url, data, HTTP_TIMEOUT)
            if code != 200:
                self.logger.error(f"[node] Telegram发送失败 HTTP={code}")
                return False
            if body:
                try:
                    payload = json.loads(body.decode("utf-8", errors="ignore"))
                    if payload.get("ok") is False:
                        self.logger.error(f"[node] Telegram返回失败: {payload}")
                        return False
                except Exception:
                    pass
            return True
        except Exception as exc:
            self.logger.error(f"[node] Telegram发送异常: {exc}")
            return False

    def refresh_once(self) -> Tuple[str, int]:
        self.reload_config()
        ok, msg = validate_config(self.config)
        if not ok:
            self.logger.error(f"[node] {msg}")
            return "error", 0

        status, body = self.fetch_rss()
        if status == "not_modified":
            return status, 0
        if status != "ok" or body is None:
            return "error", 0

        parse_status, posts = self.parse_posts(body)
        if parse_status == "blocked":
            self.logger.error("[node] 可能被挑战页拦截")
            return "blocked", 0
        if parse_status == "empty":
            self.logger.error("[node] 未提取到帖子")
            return "empty", 0
        if parse_status != "ok":
            return "error", 0

        changes = self.state.merge_posts(posts)
        if changes > 0:
            self.state.save()
            self.logger.info(f"[node] 缓存更新 {changes} 条")
        return "ok", changes

    def _collect_matches(self, window: int, mark_sent: bool) -> Tuple[str, List[str], List[str]]:
        self.reload_config()
        matcher = KeywordMatcher(self.config.get("KEYWORDS", ""))
        if not matcher.tokens:
            return "", [], []
        now_time = fmt_time()
        lines: List[str] = []
        ids_to_mark: List[str] = []
        for entry in self.state.latest_entries(window):
            if mark_sent and entry.get("sent"):
                continue
            title = str(entry.get("title", ""))
            hit = matcher.match(title)
            if not hit:
                continue
            lines.extend([
                f"🎯node:【{hit}】",
                f"📆时间: {now_time}",
                f"🔖标题: {title}",
                f"🧬链接: {entry.get('url', '')}",
                "",
            ])
            ids_to_mark.append(str(entry.get("id", "")))
        return "\n".join(lines).rstrip(), ids_to_mark, [str(x.get("id", "")) for x in self.state.latest_entries(window)]

    def auto_push_once(self) -> int:
        text, ids_to_mark, _ = self._collect_matches(MATCH_WINDOW, mark_sent=True)
        if not text or not ids_to_mark:
            return 0
        if not self.telegram_send(text):
            return -1
        changed = False
        for id_ in ids_to_mark:
            entry = self.state.entries.get(id_)
            if entry and not entry.get("sent"):
                entry["sent"] = True
                changed = True
        if changed:
            self.state.save()
        self.logger.event(f"[node] 自动推送成功 {len(ids_to_mark)} 条")
        return len(ids_to_mark)

    def manual_push(self) -> int:
        text, ids_to_mark, _ = self._collect_matches(MANUAL_PUSH_WINDOW, mark_sent=False)
        if not text or not ids_to_mark:
            return 0
        return len(ids_to_mark) if self.telegram_send(text) else -1

    def print_latest(self, limit: int = 10) -> None:
        latest = self.state.latest_entries(limit)
        if not latest:
            print("暂无缓存，请先执行「手动刷新」")
            return
        print("最新10条（最新在下）：")
        for idx, entry in enumerate(latest, 1):
            tag = "已推送" if entry.get("sent") else "未推送"
            print(f"{idx}) [{entry['id']}] ({tag}) {entry['title']}")
            print(f"    {entry['url']}")

    def test_notification(self) -> bool:
        msg = "\n".join([
            "🎯node",
            f"📆时间: {fmt_time()}",
            "🔖标题: 这是来自 Python 脚本的测试推送",
            f"🧬链接: {self.config.get('NS_URL', DEFAULT_URL)}",
        ])
        return self.telegram_send(msg)

    def trim_logs_if_needed(self, every_n_loops: int, loop_count: int) -> None:
        if every_n_loops <= 0 or loop_count % every_n_loops != 0:
            return
        today = datetime.now().strftime("%Y-%m-%d")
        last_day = ""
        if LOG_RESET_FILE.exists():
            try:
                last_day = LOG_RESET_FILE.read_text(encoding="utf-8").strip()
            except Exception:
                last_day = ""
        if last_day != today:
            for path in (LOG_FILE, CRON_LOG):
                path.write_text("", encoding="utf-8")
            LOG_RESET_FILE.write_text(today, encoding="utf-8")
        for path, max_lines in ((LOG_FILE, 60), (CRON_LOG, 60), (LAST_NODE_TXT, 200)):
            if not path.exists():
                continue
            try:
                with path.open("r", encoding="utf-8") as fh:
                    lines = fh.readlines()
                if len(lines) > max_lines:
                    with path.open("w", encoding="utf-8") as fh:
                        fh.writelines(lines[-max_lines:])
            except Exception:
                continue

    def monitor_loop(self) -> int:
        self.reload_config()
        ok, msg = validate_config(self.config)
        if not ok:
            print(f"❌ {msg}")
            self.logger.error(f"[node] {msg}")
            return 1

        interval = max(15, safe_int(self.config.get("INTERVAL_SEC", "20"), 20))
        self.logger.event(f"[node] Python 监控已启动，每 {interval} 秒轮询")
        loop_count = 0
        while True:
            loop_count += 1
            started = time.monotonic()
            self.reload_config()
            status, changed = self.refresh_once()
            if self.logger.debug:
                self.logger.info(f"[node] 本轮刷新状态={status} 变化={changed}")
            push_count = self.auto_push_once()
            if self.logger.debug:
                self.logger.info(f"[node] 本轮推送结果={push_count}")
            self.trim_logs_if_needed(40, loop_count)
            elapsed = time.monotonic() - started
            sleep_time = max(1.0, interval - elapsed)
            time.sleep(sleep_time)


def acquire_lock() -> Optional[object]:
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd = LOCK_FILE.open("w")
    try:
        fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            fd.close()
            return None
        fd.close()
        raise
    fd.write(str(os.getpid()))
    fd.flush()
    PID_FILE.write_text(str(os.getpid()), encoding="utf-8")
    return fd


def remove_pid_file() -> None:
    try:
        PID_FILE.unlink(missing_ok=True)
    except Exception:
        pass


def is_running(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def read_pid() -> int:
    if not PID_FILE.exists():
        return 0
    try:
        return int(PID_FILE.read_text(encoding="utf-8").strip())
    except Exception:
        return 0


def cmd_run() -> int:
    lock_handle = acquire_lock()
    if lock_handle is None:
        print("node Python 监控已在运行，跳过重复启动")
        return 0

    def _cleanup(*_args):
        remove_pid_file()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT, _cleanup)
    try:
        monitor = NodeMonitor()
        return monitor.monitor_loop()
    finally:
        remove_pid_file()
        try:
            lock_handle.close()
        except Exception:
            pass


def cmd_refresh() -> int:
    monitor = NodeMonitor()
    status, changed = monitor.refresh_once()
    if status == "not_modified":
        print("ℹ️ RSS 未更新（304）")
        return 0
    if status == "ok":
        print(f"✅ 刷新完成，更新 {changed} 条")
        return 0
    if status == "blocked":
        print("⚠️ 可能被挑战页拦截")
        return 1
    print("❌ 刷新失败")
    return 1


def cmd_auto_push() -> int:
    monitor = NodeMonitor()
    count = monitor.auto_push_once()
    if count > 0:
        print(f"✅ 自动推送完成 {count} 条")
        return 0
    if count == 0:
        print("⚠️ 无匹配或均已推送")
        return 0
    print("❌ 自动推送失败")
    return 1


def cmd_manual_push() -> int:
    monitor = NodeMonitor()
    count = monitor.manual_push()
    if count > 0:
        print(f"✅ 推送完成（匹配 {count} 条）")
        return 0
    if count == 0:
        print("⚠️ 无匹配关键词帖子")
        return 0
    print("❌ 推送失败")
    return 1


def cmd_print_latest() -> int:
    monitor = NodeMonitor()
    monitor.print_latest()
    return 0


def cmd_test() -> int:
    monitor = NodeMonitor()
    if monitor.test_notification():
        print("✅ Telegram 测试推送已发送")
        return 0
    print("❌ Telegram 测试推送发送失败")
    return 1


def cmd_status() -> int:
    pid = read_pid()
    if pid and is_running(pid):
        print(f"RUNNING pid={pid}")
        return 0
    print("STOPPED")
    return 1


def main(argv: List[str]) -> int:
    ensure_workdir()
    if len(argv) < 2:
        print("usage: node_monitor.py [run|refresh|auto-push|manual-push|print-latest|test|status]")
        return 1
    cmd = argv[1]
    if cmd == "run":
        return cmd_run()
    if cmd == "refresh":
        return cmd_refresh()
    if cmd == "auto-push":
        return cmd_auto_push()
    if cmd == "manual-push":
        return cmd_manual_push()
    if cmd == "print-latest":
        return cmd_print_latest()
    if cmd == "test":
        return cmd_test()
    if cmd == "status":
        return cmd_status()
    print(f"unknown command: {cmd}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
