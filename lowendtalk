#!/bin/bash
# ============================================
# LowEndTalk 楼层ID监控 → Telegram 推送 v1.0
# (楼层 CommentID 匹配 / 最新页自动识别 / 真换行推送 / 内置锁 / 20秒循环)
# 更新时间：2025-12-17
# ============================================

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TZ='Asia/Shanghai'

# 配置路径
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"
CONFIG_FILE="$WORK_DIR/lowendtalk_config.txt"
LOG_FILE="$WORK_DIR/lowendtalk.log"
CRON_LOG="$WORK_DIR/lowendtalk_cron.log"
SCRIPT_PATH="$WORK_DIR/lowendtalk.sh"

# ================== 彩色定义 ==================
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; PURPLE="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"; PLAIN="\033[0m"

# ============================================
# 配置管理（自动加载 & 持久化保存）
# ============================================
read_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${RED}❌ 配置文件不存在或为空，请先执行配置向导。${PLAIN}"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_PUSH_CHAT_ID" ] || [ -z "$THREAD_URLS" ]; then
        echo -e "${RED}❌ 配置不完整（需 TG_BOT_TOKEN / TG_PUSH_CHAT_ID / THREAD_URLS），请重新配置。${PLAIN}"
        return 1
    fi
    return 0
}

write_config() {
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_PUSH_CHAT_ID="$TG_PUSH_CHAT_ID"
THREAD_URLS="$THREAD_URLS"
KEYWORDS="$KEYWORDS"
EOF
    echo -e "${GREEN}✅ 配置已保存到 $CONFIG_FILE${PLAIN}"
}

# ============================================
# 时间格式：2025.12.08.10:40
# ============================================
fmt_time() { date '+%Y.%m.%d.%H:%M'; }

# ============================================
# Telegram 推送（content 必须是“真实换行”文本）
# ============================================
tg_send() {
    local content="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_PUSH_CHAT_ID}" \
        --data-urlencode "text=${content}" \
        -d "disable_web_page_preview=true" \
        >/dev/null
}

# ============================================
# 统一 UA + 压缩 + 跟随跳转
# ============================================
fetch_html() {
    local url="$1"
    curl -s --compressed -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" "$url"
}

# ============================================
# 把 discussion URL 规范化：去掉 #xxx 片段
# ============================================
normalize_thread_url() {
    local url="$1"
    echo "$url" | sed 's/#.*$//'
}

# ============================================
# 解析帖子最后页页码：从第一页分页链接里找最大 /pN
# 找不到则认为 1
# ============================================
get_last_page_num() {
    local thread_url="$1"
    local html
    html=$(fetch_html "$thread_url") || true
    if [[ -z "$html" ]]; then
        echo "1"
        return
    fi

    # 找所有 /p数字，取最大
    local maxp
    maxp=$(echo "$html" | grep -Eo '/p[0-9]+' | sed 's#/p##' | sort -n | tail -n1)

    if [[ -z "$maxp" ]]; then
        echo "1"
    else
        echo "$maxp"
    fi
}

# ============================================
# 构造最后页 URL
# page=1 => 原URL
# page>1 => 原URL/pN
# ============================================
build_page_url() {
    local thread_url="$1"
    local page="$2"
    if [[ "$page" == "1" ]]; then
        echo "$thread_url"
    else
        echo "${thread_url}/p${page}"
    fi
}

# ============================================
# 从“最后页HTML”提取 Comment IDs（最新在下）
# Vanilla 通常是 id="Comment_123456" 或 data-commentid="123456"
# 这里两种都兼容
# ============================================
extract_comment_ids() {
    local html="$1"

    # 1) 尝试 id="Comment_123"
    local ids1
    ids1=$(echo "$html" | grep -Eo 'id="Comment_[0-9]+"' | grep -Eo '[0-9]+' || true)

    # 2) 尝试 data-commentid="123"
    local ids2
    ids2=$(echo "$html" | grep -Eo 'data-commentid="[0-9]+"' | grep -Eo '[0-9]+' || true)

    # 合并去重，保持出现顺序（用 awk 去重）
    printf "%s\n%s\n" "$ids1" "$ids2" | awk 'NF && !seen[$0]++'
}

# ============================================
# 从 HTML 中提取指定 CommentID 的内容，转纯文本，取前 200 字节
# 说明：
# - 先抓包含 Comment 的整段 li
# - 再去标签/解实体/压空白
# ============================================
extract_comment_text_200b() {
    local html="$1"
    local cid="$2"

    # perl 用环境变量传参更安全
    CID="$cid" perl -0777 -ne '
        my $cid=$ENV{CID};
        my $re1 = qr{<li\b[^>]*\bid="Comment_\Q$cid\E"[^>]*>.*?</li>}si;
        my $re2 = qr{<li\b[^>]*\bdata-commentid="\Q$cid\E"[^>]*>.*?</li>}si;
        my $block = "";
        if (m/($re1)/) { $block=$1; }
        elsif (m/($re2)/) { $block=$1; }
        else { exit 0; }

        $block =~ s/<br\s*\/?>/\n/gi;
        $block =~ s/<[^>]+>/ /g;

        # HTML entities（常见的足够用）
        $block =~ s/&nbsp;/ /g;
        $block =~ s/&amp;/&/g;
        $block =~ s/&lt;/</g;
        $block =~ s/&gt;/>/g;
        $block =~ s/&quot;/"/g;
        $block =~ s/&#39;/'"'"'/g;

        $block =~ s/\s+/ /g;
        $block =~ s/^\s+|\s+$//g;

        # 截取前200字节（按字节）
        use Encode;
        my $bytes = encode("UTF-8", $block);
        $bytes = substr($bytes, 0, 200);
        my $out = decode("UTF-8", $bytes);
        print $out;
    ' <<<"$html"
}

# ============================================
# 初始化配置（支持保留旧值）
# ============================================
initial_config() {
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} LowEndTalk 配置向导（楼层ID监控 → TG个人推送）${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    echo ""
    echo "提示：按 Enter 保留当前配置，输入新值将覆盖原配置。"
    echo ""

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    # --- Telegram Bot Token ---
    if [ -n "$TG_BOT_TOKEN" ]; then
        local token_display="${TG_BOT_TOKEN:0:10}...${TG_BOT_TOKEN: -4}"
        read -rp "请输入 Telegram Bot Token [当前: $token_display]: " new_bot_token
        [[ -z "$new_bot_token" ]] && new_bot_token="$TG_BOT_TOKEN"
    else
        read -rp "请输入 Telegram Bot Token: " new_bot_token
        while [[ -z "$new_bot_token" ]]; do
            echo "❌ Bot Token 不能为空，请重新输入。"
            read -rp "请输入 Telegram Bot Token: " new_bot_token
        done
    fi

    # --- 个人私聊 Chat ID ---
    if [ -n "$TG_PUSH_CHAT_ID" ]; then
        read -rp "请输入个人推送 Chat ID [当前: $TG_PUSH_CHAT_ID]: " new_chat_id
        [[ -z "$new_chat_id" ]] && new_chat_id="$TG_PUSH_CHAT_ID"
    else
        read -rp "请输入个人推送 Chat ID（不知道可先填0，稍后再改）: " new_chat_id
        [[ -z "$new_chat_id" ]] && new_chat_id="0"
    fi

    # --- 监控帖子 URL(s) ---
    if [ -n "$THREAD_URLS" ]; then
        read -rp "请输入要监控的帖子链接 [当前: $THREAD_URLS]（多个用空格分隔）: " new_threads
        [[ -z "$new_threads" ]] && new_threads="$THREAD_URLS"
    else
        read -rp "请输入要监控的帖子链接（多个用空格分隔）: " new_threads
        while [[ -z "$new_threads" ]]; do
            echo "❌ 帖子链接不能为空，请重新输入。"
            read -rp "请输入帖子链接: " new_threads
        done
    fi

    # 写入 cron（直跑，无 flock 包装）
    setup_cron

    # --- 楼层ID关键词设置 ---
    echo ""
    echo "当前楼层ID关键词：${KEYWORDS:-未设置}"
    read -rp "是否需要重置楼层ID关键词？(Y/N): " reset_kw
    if [[ "$reset_kw" =~ ^[Yy]$ ]]; then
        while true; do
            echo "请输入楼层 CommentID（多个用空格分隔），示例：123456 888999 777000"
            read -rp "输入楼层ID: " new_keywords
            new_keywords=$(echo "$new_keywords" | awk '{$1=$1;print}')
            KEYWORDS="$new_keywords"
            echo "楼层ID关键词已更新为：${KEYWORDS:-空}"
            break
        done
    else
        echo "保持原有楼层ID关键词：${KEYWORDS:-未设置}"
    fi

    TG_BOT_TOKEN="$new_bot_token"
    TG_PUSH_CHAT_ID="$new_chat_id"
    THREAD_URLS="$new_threads"
    write_config

    echo ""
    echo -e "${GREEN}✅ 配置已更新并保存成功！${PLAIN}"
    echo ""
    read_config
}

# ============================================
# 手动打印缓存
# ============================================
print_latest() {
    read_config || return
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} 最新监控状态（缓存）${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"

    for u in $THREAD_URLS; do
        local thread
        thread=$(normalize_thread_url "$u")
        local key
        key=$(echo -n "$thread" | md5sum | awk '{print $1}')
        local STATE_FILE="$WORK_DIR/state_${key}.txt"

        echo -e "${CYAN}帖子：$thread${PLAIN}"
        if [ ! -s "$STATE_FILE" ]; then
            echo "（暂无缓存）"
        else
            cat "$STATE_FILE"
        fi
        echo "--------------------------------------"
    done
}

# ============================================
# 刷新：识别最后页、抓最后页、缓存“页码 + 最新10个ID”
# ============================================
manual_fresh() {
    read_config || return

    for u in $THREAD_URLS; do
        local thread
        thread=$(normalize_thread_url "$u")

        local last_page
        last_page=$(get_last_page_num "$thread")

        local page_url
        page_url=$(build_page_url "$thread" "$last_page")

        local html
        html=$(fetch_html "$page_url")
        if [[ -z "$html" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$thread] ❌ 获取页面失败：$page_url" >> "$LOG_FILE"
            continue
        fi

        local ids
        ids=$(extract_comment_ids "$html")
        if [[ -z "$ids" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$thread] ❌ 未提取到 CommentID（可能结构变化/被WAF）" >> "$LOG_FILE"
            continue
        fi

        local last10
        last10=$(echo "$ids" | tail -n 10)

        local key
        key=$(echo -n "$thread" | md5sum | awk '{print $1}')
        local STATE_FILE="$WORK_DIR/state_${key}.txt"

        {
            echo "page=$last_page"
            echo "page_url=$page_url"
            echo "last10_ids:"
            echo "$last10"
        } > "$STATE_FILE"

        echo "$(date '+%Y-%m-%d %H:%M:%S') [$thread] ✅ 已更新缓存：第${last_page}页（最新10个ID）" >> "$LOG_FILE"
    done
}

# ============================================
# 手动推送（匹配楼层ID）—— 真换行格式
# ============================================
manual_push() {
    read_config || return
    if [[ -z "$KEYWORDS" ]]; then
        echo "❌ 未设置楼层ID关键词（KEYWORDS），跳过。"
        return
    fi

    for u in $THREAD_URLS; do
        local thread
        thread=$(normalize_thread_url "$u")
        local key
        key=$(echo -n "$thread" | md5sum | awk '{print $1}')
        local STATE_FILE="$WORK_DIR/state_${key}.txt"

        if [[ ! -s "$STATE_FILE" ]]; then
            echo "❌ 无缓存文件，先执行【手动更新】。($thread)"
            continue
        fi

        local page page_url
        page=$(grep -E '^page=' "$STATE_FILE" | head -n1 | cut -d= -f2)
        page_url=$(grep -E '^page_url=' "$STATE_FILE" | head -n1 | cut -d= -f2)

        local ids
        ids=$(awk 'f{print} /^last10_ids:/{f=1}' "$STATE_FILE" | sed '/^$/d')

        local html
        html=$(fetch_html "$page_url")
        if [[ -z "$html" ]]; then
            echo "❌ 获取页面失败，跳过：$page_url"
            continue
        fi

        local now_t
        now_t=$(fmt_time)

        local push_text=""
        local hit=0

        for cid in $ids; do
            for kw in $KEYWORDS; do
                if [[ "$cid" == "$kw" ]]; then
                    local snippet
                    snippet=$(extract_comment_text_200b "$html" "$cid")
                    [[ -z "$snippet" ]] && snippet="（内容提取失败，可能结构变化）"

                    push_text+=$'🎯LET 楼层命中\n'
                    push_text+=$'🕒时间: '"$now_t"$'\n'
                    push_text+=$'📄页码: p'"$page"$'\n'
                    push_text+=$'🆔楼层ID: '"$cid"$'\n'
                    push_text+=$'🔗链接: '"${thread}#Comment_${cid}"$'\n'
                    push_text+=$'📝内容(200B): '"$snippet"$'\n\n'
                    hit=$((hit+1))
                    break
                fi
            done
        done

        if (( hit == 0 )); then
            echo "⚠️ [$thread] 最新10层无匹配楼层ID"
            continue
        fi

        tg_send "$push_text"
        echo "✅ [$thread] 已手动推送（命中 $hit 条）"
    done
}

# ============================================
# 自动推送（cron）—— 匹配楼层ID 且只推送一次（sent 去重）
# 另外写日志：当前第几页、最新页最新10个ID、是否匹配
# ============================================
auto_push() {
    read_config || return
    if [[ -z "$KEYWORDS" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ⚠️ 未设置楼层ID关键词，跳过自动推送" >> "$LOG_FILE"
        return
    fi

    local SENT_FILE="$WORK_DIR/sent_lowendtalk.txt"
    [[ -f "$SENT_FILE" ]] || touch "$SENT_FILE"

    for u in $THREAD_URLS; do
        local thread
        thread=$(normalize_thread_url "$u")
        local key
        key=$(echo -n "$thread" | md5sum | awk '{print $1}')
        local STATE_FILE="$WORK_DIR/state_${key}.txt"

        if [[ ! -s "$STATE_FILE" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$thread] ⚠️ 无缓存，跳过（先 manual_fresh）" >> "$LOG_FILE"
            continue
        fi

        local page page_url
        page=$(grep -E '^page=' "$STATE_FILE" | head -n1 | cut -d= -f2)
        page_url=$(grep -E '^page_url=' "$STATE_FILE" | head -n1 | cut -d= -f2)

        local ids
        ids=$(awk 'f{print} /^last10_ids:/{f=1}' "$STATE_FILE" | sed '/^$/d')

        local nowlog
        nowlog=$(date '+%Y-%m-%d %H:%M:%S')

        echo "$nowlog [$thread] 当前监测：第${page}页 | URL=$page_url" >> "$LOG_FILE"
        echo "$nowlog [$thread] 最新10个楼层ID：" >> "$LOG_FILE"
        echo "$ids" | sed "s/^/$nowlog [$thread]   - /" >> "$LOG_FILE"

        local html
        html=$(fetch_html "$page_url")
        if [[ -z "$html" ]]; then
            echo "$nowlog [$thread] ❌ 获取页面失败，跳过：$page_url" >> "$LOG_FILE"
            continue
        fi

        local now_t
        now_t=$(fmt_time)

        local push_text=""
        local new_hits=0

        for cid in $ids; do
            local matched=0
            for kw in $KEYWORDS; do
                if [[ "$cid" == "$kw" ]]; then
                    matched=1
                    break
                fi
            done

            if (( matched == 1 )); then
                if grep -Fxq "${thread}|${cid}" "$SENT_FILE"; then
                    echo "$nowlog [$thread] 已推送过（跳过）：$cid" >> "$LOG_FILE"
                    continue
                fi

                local snippet
                snippet=$(extract_comment_text_200b "$html" "$cid")
                [[ -z "$snippet" ]] && snippet="（内容提取失败，可能结构变化）"

                echo "$nowlog [$thread] 匹配 ✔：$cid（将推送）" >> "$LOG_FILE"

                push_text+=$'🎯LET 楼层命中\n'
                push_text+=$'🕒时间: '"$now_t"$'\n'
                push_text+=$'📄页码: p'"$page"$'\n'
                push_text+=$'🆔楼层ID: '"$cid"$'\n'
                push_text+=$'🔗链接: '"${thread}#Comment_${cid}"$'\n'
                push_text+=$'📝内容(200B): '"$snippet"$'\n\n'

                echo "${thread}|${cid}" >> "$SENT_FILE"
                new_hits=$((new_hits+1))
            else
                echo "$nowlog [$thread] 未匹配 ✖：$cid" >> "$LOG_FILE"
            fi
        done

        if (( new_hits == 0 )); then
            echo "$nowlog [$thread] ⚠️ 无匹配或均已推送过" >> "$LOG_FILE"
            continue
        fi

        tg_send "$push_text"
        echo "$nowlog [$thread] 📩 自动推送成功（${new_hits} 条）" >> "$LOG_FILE"
    done
}

# ============================================
# 测试 Telegram 推送
# ============================================
test_notification() {
    read_config || return
    local now_t
    now_t=$(fmt_time)

    local msg=""
    msg+=$'🎯LET 监控测试\n'
    msg+=$'🕒时间: '"${now_t}"$'\n'
    msg+=$'✅ 看到此消息说明 Telegram 配置正常'

    tg_send "$msg"
    echo -e "${GREEN}✅ Telegram 测试推送已发送（请到私聊查看）${PLAIN}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ Telegram 测试推送已发送" >> "$LOG_FILE"
}

# ============================================
# 日志轮转（保留最近 7 天归档）
# ============================================
log_rotate() {
    local log_file="$CRON_LOG"
    local flag_file="$WORK_DIR/log_clean.flag"
    local today
    today=$(date +%Y-%m-%d)

    if [[ -f "$flag_file" && "$(cat "$flag_file")" == "$today" ]]; then
        return
    fi

    echo "🔥 开始日志轮转：删除 7 天前的日志文件..." >> "$CRON_LOG"
    find "$WORK_DIR" -name "*.log.*" -mtime +7 -delete

    if [[ -f "$log_file" ]]; then
        mv "$log_file" "${log_file}.${today}"
        touch "$log_file"
    fi

    echo "$today" > "$flag_file"
    echo "✔ 日志轮转完成" >> "$CRON_LOG"
}

# ============================================
# cron 模式：每20秒执行一次 manual_fresh + auto_push
# 内置 flock 锁，避免多实例
# ============================================
if [[ "$1" == "-cron" ]]; then
    LOCK_FILE="$WORK_DIR/lowendtalk.lock"
    exec 200>"$LOCK_FILE"
    flock -n 200 || exit 0

    INTERVAL=20
    echo "$(date '+%Y-%m-%d %H:%M:%S') 🚀 定时任务已启动（每${INTERVAL}秒执行 manual_fresh + auto_push）" >> "$CRON_LOG"

    while true; do
        start_ts=$(date +%s)

        trim_file() {
            local file="$1"
            local max_lines=200
            [[ -f "$file" ]] || return
            local cnt
            cnt=$(wc -l < "$file")
            if (( cnt > max_lines )); then
                tail -n "$max_lines" "$file" > "${file}.tmp"
                mv "${file}.tmp" "$file"
            fi
        }

        trim_file "$CRON_LOG"
        trim_file "$LOG_FILE"
        trim_file "$WORK_DIR/sent_lowendtalk.txt"

        echo "$(date '+%Y-%m-%d %H:%M:%S') ▶️ 执行 manual_fresh()" >> "$CRON_LOG"
        manual_fresh >/dev/null 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ manual_fresh() 执行完成" >> "$CRON_LOG"

        echo "$(date '+%Y-%m-%d %H:%M:%S') ▶️ 执行 auto_push()" >> "$CRON_LOG"
        auto_push >/dev/null 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ auto_push() 执行完成" >> "$CRON_LOG"

        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))
        sleep_time=$((INTERVAL - elapsed))
        (( sleep_time < 1 )) && sleep_time=1

        echo "$(date '+%Y-%m-%d %H:%M:%S') 🕒 等待${sleep_time}秒进入下次周期..." >> "$CRON_LOG"
        echo "" >> "$CRON_LOG"

        sleep "$sleep_time"
    done
fi

# ============================================
# 设置定时任务（cron 每分钟触发一次，脚本内部自循环）
# ============================================
setup_cron() {
    local entry="* * * * * /root/TrafficCop/lowendtalk.sh -cron"
    echo "🛠 正在检查并更新 lowendtalk 定时任务..."

    crontab -l 2>/dev/null \
        | grep -v "lowendtalk.sh -cron" \
        > /tmp/cron.lowendtalk.tmp || true

    {
        cat /tmp/cron.lowendtalk.tmp
        echo "$entry"
    } | crontab -

    rm -f /tmp/cron.lowendtalk.tmp
    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ lowendtalk cron 已更新为：$entry" | tee -a "$CRON_LOG"
}

# ============================================
# 关闭定时任务
# ============================================
stop_cron() {
    echo -e "${YELLOW}⏳ 正在停止 lowendtalk 定时任务...${PLAIN}"

    pkill -f "lowendtalk.sh -cron" 2>/dev/null

    crontab -l 2>/dev/null \
        | grep -v "lowendtalk.sh -cron" \
        | crontab - 2>/dev/null

    echo -e "${GREEN}✔ 已从 crontab 中移除 lowendtalk 定时任务${PLAIN}"
    systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null
    echo -e "${GREEN}✔ lowendtalk 定时监控已完全停止${PLAIN}"
}

# ============================================
# 主菜单
# ============================================
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${PURPLE} LowEndTalk 楼层ID监控（Telegram个人推送）${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 安装/修改配置"
        echo -e "${GREEN}2.${PLAIN} 打印最新缓存"
        echo -e "${GREEN}3.${PLAIN} 推送最新命中（楼层ID匹配）"
        echo -e "${GREEN}4.${PLAIN} 推送测试消息（Telegram）"
        echo -e "${GREEN}5.${PLAIN} 手动更新（刷新缓存）"
        echo -e "${RED}6.${PLAIN} 清除cron任务"
        echo -e "${WHITE}0.${PLAIN} 退出"
        echo -e "${BLUE}======================================${PLAIN}"
        read -rp "请选择操作 [0-6]: " choice
        echo
        case $choice in
            1) initial_config; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            2) print_latest; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            3) manual_push; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            4) test_notification; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            5) manual_fresh; echo -e "${GREEN}手动更新完成。${PLAIN}" ;;
            6) stop_cron; echo -e "${GREEN}停止cron任务完成。${PLAIN}" ;;
            0) exit 0 ;;
            *) echo "无效选项"; echo -e "${GREEN}操作完成。${PLAIN}" ;;
        esac
        read -p "按 Enter 返回菜单..."
    done
}

main_menu
