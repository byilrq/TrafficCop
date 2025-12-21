#!/bin/bash
# ============================================
# NodeSeek 最新帖子 → Telegram 监控脚本 v2.0
# (Telegram个人推送版 / 真换行推送 / 内置锁防重启 / 20秒稳定循环)
# 基于你的 TG 频道脚本改造：监控 https://www.nodeseek.com/?sortBy=postTime
# 更新时间：2025-12-21
# ============================================

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TZ='Asia/Shanghai'

# 配置路径
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"
CONFIG_FILE="$WORK_DIR/nodeseek_config.txt"
LOG_FILE="$WORK_DIR/nodeseek.log"
CRON_LOG="$WORK_DIR/nodeseek_cron.log"
SCRIPT_PATH="$WORK_DIR/nodeseek.sh"

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

    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_PUSH_CHAT_ID" ] || [ -z "$NS_URL" ]; then
        echo -e "${RED}❌ 配置不完整（需 TG_BOT_TOKEN / TG_PUSH_CHAT_ID / NS_URL），请重新配置。${PLAIN}"
        return 1
    fi
    return 0
}

write_config() {
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_PUSH_CHAT_ID="$TG_PUSH_CHAT_ID"
NS_URL="$NS_URL"
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
# 初始化配置（支持保留旧值）
# ============================================
initial_config() {
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} NodeSeek 最新帖子监控 配置向导${PLAIN}"
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

    # --- NodeSeek URL ---
    local default_url="https://www.nodeseek.com/?sortBy=postTime"
    if [ -n "$NS_URL" ]; then
        read -rp "请输入要监控的 NodeSeek 页面URL [当前: $NS_URL] (回车默认最新帖): " new_url
        [[ -z "$new_url" ]] && new_url="$NS_URL"
    else
        read -rp "请输入要监控的 NodeSeek 页面URL [默认: $default_url]: " new_url
        [[ -z "$new_url" ]] && new_url="$default_url"
    fi

    # 写入 cron（直跑，无 flock 包装）
    setup_cron

    # --- 关键词过滤设置 ---
    echo ""
    echo "当前关键词：${KEYWORDS:-未设置}"
    read -rp "是否需要重置关键词？(Y/N): " reset_kw

    if [[ "$reset_kw" =~ ^[Yy]$ ]]; then
        while true; do
            echo "请输入关键词（多个关键词用 , 分隔），示例：上架,库存,补货"
            read -rp "输入关键词(留空=清空关键词): " new_keywords

            if [[ -z "$new_keywords" ]]; then
                KEYWORDS=""
                echo "关键词已清空。"
                break
            fi

            new_keywords=$(echo "$new_keywords" | sed 's/,/ /g' | awk '{$1=$1; print}')
            kw_count=$(echo "$new_keywords" | wc -w)

            if (( kw_count > 10 )); then
                echo "❌ 关键词数量不能超过 10 个（当前：$kw_count 个）。请重新输入。"
            else
                KEYWORDS="$new_keywords"
                echo "关键词已更新为：$KEYWORDS"
                break
            fi
        done
    else
        echo "保持原有关键词：${KEYWORDS:-未设置}"
    fi

    TG_BOT_TOKEN="$new_bot_token"
    TG_PUSH_CHAT_ID="$new_chat_id"
    NS_URL="$new_url"
    write_config

    echo ""
    echo -e "${GREEN}✅ 配置已更新并保存成功！${PLAIN}"
    echo ""
    read_config
}

# ============================================
# HTML 解码（尽量覆盖常见实体）
# ============================================
html_decode() {
    sed -e 's/&nbsp;/ /g' \
        -e 's/&amp;/\&/g' \
        -e 's/&lt;/</g' \
        -e 's/&gt;/>/g' \
        -e 's/&quot;/"/g' \
        -e "s/&#39;/'/g" \
        -e 's/&#036;/$/g' \
        -e 's/&#64;/@/g'
}

# ============================================
# 抓取 NodeSeek 页面 HTML（带 UA / gzip / 跟随跳转）
# ============================================
fetch_nodeseek_html() {
    local url="$1"
    curl -s --compressed -L \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: zh-CN,zh;q=0.9,en;q=0.8" \
        -H "Cache-Control: no-cache" \
        "$url"
}

# ============================================
# 从 NodeSeek 列表页提取最新帖子（id|title|url）
# 说明：
# - 尽量用“href=/post-xxxx-1”抽取
# - 对 HTML 结构不做强依赖：只要页面里有 <a ... href="/post-123-1">标题</a> 就能工作
# ============================================
extract_posts() {
    local html="$1"

    # 基础反爬/异常判断
    if echo "$html" | grep -qiE "Just a moment|Attention Required|Cloudflare|captcha"; then
        echo "__BLOCKED__"
        return 0
    fi

    # 提取 a 标签中指向 /post-xxxxx-1 的标题
    # 输出：id|title|https://www.nodeseek.com/post-xxxxx-1
    echo "$html" \
      | tr '\n' ' ' \
      | sed 's/<a /\n<a /g' \
      | awk '
        BEGIN{IGNORECASE=1}
        /href="\/post-[0-9]+-1"/ {
            a=$0
            # href
            if (match(a, /href="\/post-[0-9]+-1"/)) {
                href=substr(a, RSTART+6, RLENGTH-7)
                # id
                id=href
                gsub(/^\/post-/, "", id)
                gsub(/-1$/, "", id)

                # title：取 a 标签内的纯文本（尽量）
                # 先截取 > ... </a
                t=a
                sub(/.*>/, "", t)
                sub(/<\/a.*/, "", t)
                # 去掉内部标签
                gsub(/<[^>]+>/, "", t)
                # trim
                gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", t)

                if (length(id) > 0 && length(t) > 0) {
                    print id "|" t "|https://www.nodeseek.com" href
                }
            }
        }
      ' \
      | head -n 30 \
      | html_decode \
      | awk -F'|' '
        # 去掉明显无效/过短标题
        length($2) >= 4 { print $0 }
      '
}

# ============================================
# 手动打印最新帖子标题
# ============================================
print_latest() {
    read_config || return
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} NodeSeek 最新帖子（缓存）${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"

    local STATE_FILE="$WORK_DIR/last_nodeseek.txt"
    if [ ! -s "$STATE_FILE" ]; then
        echo "暂无缓存，请先执行「手动更新（刷新缓存）」"
        return
    fi

    echo -e "最新10条（最新在下）："
    local i=1
    tail -n 10 "$STATE_FILE" | while IFS= read -r line; do
        local id title url
        id=$(echo "$line" | awk -F'|' '{print $1}')
        title=$(echo "$line" | awk -F'|' '{print $2}')
        url=$(echo "$line" | awk -F'|' '{print $3}')
        echo "${i}) [$id] $title"
        echo "    $url"
        ((i++))
    done
}

# ============================================
# 手动刷新：抓取最新帖子并更新缓存
# ============================================
manual_fresh() {
    read_config || return

    local STATE_FILE="$WORK_DIR/last_nodeseek.txt"

    local html
    html=$(fetch_nodeseek_html "$NS_URL")
    if [[ -z "$html" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [NodeSeek] ❌ 获取HTML失败" >> "$LOG_FILE"
        return
    fi

    local posts
    posts=$(extract_posts "$html")

    if [[ "$posts" == "__BLOCKED__" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [NodeSeek] ⚠️ 可能被风控/Cloudflare 拦截（Just a moment / captcha）" >> "$LOG_FILE"
        return
    fi

    if [[ -z "$posts" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [NodeSeek] ❌ 未提取到帖子（页面结构变化或被拦截）" >> "$LOG_FILE"
        return
    fi

    # 写缓存（只保留最近 50 条，避免越来越大）
    echo "$posts" | tac | awk '!seen[$1]++' | tac > "$STATE_FILE"  # 去重（按 id）
    if (( $(wc -l < "$STATE_FILE") > 50 )); then
        tail -n 50 "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') [NodeSeek] ✅ 最新帖子缓存已更新" >> "$LOG_FILE"
}

# ============================================
# 手动推送（关键词匹配）—— 真换行格式
# ============================================
manual_push() {
    read_config || return

    local STATE_FILE="$WORK_DIR/last_nodeseek.txt"
    if [[ ! -s "$STATE_FILE" ]]; then
        echo "❌ 无缓存文件，请先手动更新（刷新缓存）"
        return
    fi

    if [[ -z "$KEYWORDS" ]]; then
        echo "❌ 未设置关键词，跳过推送"
        return
    fi

    local KEYWORDS_LOWER
    KEYWORDS_LOWER=$(echo "$KEYWORDS" | tr 'A-Z' 'a-z')

    local lines=()
    while IFS= read -r line; do lines+=("$line"); done < "$STATE_FILE"

    local total=${#lines[@]}
    local start=$(( total > 10 ? total - 10 : 0 ))
    local matched=()

    for ((i=start; i<total; i++)); do
        local id title url
        id=$(echo "${lines[$i]}" | awk -F'|' '{print $1}')
        title=$(echo "${lines[$i]}" | awk -F'|' '{print $2}')
        url=$(echo "${lines[$i]}" | awk -F'|' '{print $3}')

        local t_lower
        t_lower=$(echo "$title" | tr 'A-Z' 'a-z')

        for kw in $KEYWORDS_LOWER; do
            if [[ "$t_lower" == *"$kw"* ]]; then
                matched+=("${id}|${title}|${url}")
                break
            fi
        done
    done

    if [[ ${#matched[@]} -eq 0 ]]; then
        echo "⚠️ 无匹配关键词帖子"
        return
    fi

    local now_t
    now_t=$(fmt_time)

    local push_text=""
    for x in "${matched[@]}"; do
        local id title url
        id=$(echo "$x" | awk -F'|' '{print $1}')
        title=$(echo "$x" | awk -F'|' '{print $2}')
        url=$(echo "$x" | awk -F'|' '{print $3}')

        push_text+=$'🎯NodeSeek 新帖\n'
        push_text+=$'🕒时间: '"${now_t}"$'\n'
        push_text+=$'🆔ID: '"${id}"$'\n'
        push_text+=$'🌐标题: '"${title}"$'\n'
        push_text+=$'🔗链接: '"${url}"$'\n\n'
    done

    tg_send "$push_text"
    echo "✅ 推送完成（匹配 ${#matched[@]} 条）"
}

# ============================================
# 自动推送（cron）—— 匹配关键词且只推送一次（真换行格式）
# ============================================
auto_push() {
    read_config || return

    local STATE_FILE="$WORK_DIR/last_nodeseek.txt"
    if [[ ! -s "$STATE_FILE" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [NodeSeek] ⚠️无缓存文件，跳过自动推送" >> "$LOG_FILE"
        return
    fi

    if [[ -z "$KEYWORDS" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [NodeSeek] ⚠️无关键词，跳过自动推送" >> "$LOG_FILE"
        return
    fi

    local KEYWORDS_LOWER
    KEYWORDS_LOWER=$(echo "$KEYWORDS" | tr 'A-Z' 'a-z')

    local SENT_FILE="$WORK_DIR/sent_nodeseek_ids.txt"
    [[ -f "$SENT_FILE" ]] || touch "$SENT_FILE"

    local lines=()
    while IFS= read -r line; do lines+=("$line"); done < "$STATE_FILE"

    local total=${#lines[@]}
    local start=$(( total > 10 ? total - 10 : 0 ))
    local new_matched=()

    local nowlog
    nowlog=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$nowlog [NodeSeek] 当前关键词：$KEYWORDS" >> "$LOG_FILE"
    echo "$nowlog [NodeSeek] 最新10条帖子匹配情况如下：" >> "$LOG_FILE"

    for ((i=start; i<total; i++)); do
        local id title url
        id=$(echo "${lines[$i]}" | awk -F'|' '{print $1}')
        title=$(echo "${lines[$i]}" | awk -F'|' '{print $2}')
        url=$(echo "${lines[$i]}" | awk -F'|' '{print $3}')

        local t_lower matched_kw=""
        t_lower=$(echo "$title" | tr 'A-Z' 'a-z')

        for kw in $KEYWORDS_LOWER; do
            if [[ "$t_lower" == *"$kw"* ]]; then
                matched_kw="$kw"
                break
            fi
        done

        if [[ -n "$matched_kw" ]]; then
            if grep -Fxq "$id" "$SENT_FILE"; then
                echo "$nowlog [NodeSeek] 已推送过（跳过）：[$id] $title" >> "$LOG_FILE"
            else
                echo "$nowlog [NodeSeek] 匹配 ✔：[$id] $title（关键词：$matched_kw）" >> "$LOG_FILE"
                new_matched+=("${id}|${title}|${url}")
            fi
        else
            echo "$nowlog [NodeSeek] 未匹配 ✖：[$id] $title" >> "$LOG_FILE"
        fi
    done

    if [[ ${#new_matched[@]} -eq 0 ]]; then
        echo "$nowlog [NodeSeek] ⚠️无匹配或均已推送过" >> "$LOG_FILE"
        return
    fi

    local now_t
    now_t=$(fmt_time)

    local push_text=""
    for x in "${new_matched[@]}"; do
        local id title url
        id=$(echo "$x" | awk -F'|' '{print $1}')
        title=$(echo "$x" | awk -F'|' '{print $2}')
        url=$(echo "$x" | awk -F'|' '{print $3}')

        push_text+=$'🎯NodeSeek 新帖\n'
        push_text+=$'🕒时间: '"${now_t}"$'\n'
        push_text+=$'🆔ID: '"${id}"$'\n'
        push_text+=$'🌐标题: '"${title}"$'\n'
        push_text+=$'🔗链接: '"${url}"$'\n\n'
    done

    tg_send "$push_text"

    for x in "${new_matched[@]}"; do
        echo "$x" | awk -F'|' '{print $1}' >> "$SENT_FILE"   # 只存 ID，稳定不变
    done

    echo "$nowlog [NodeSeek] 📩 自动推送成功（${#new_matched[@]} 条）" >> "$LOG_FILE"
}

# ============================================
# 测试 Telegram 推送（真换行）
# ============================================
test_notification() {
    read_config || return

    local now_t
    now_t=$(fmt_time)

    local msg=""
    msg+=$'🎯NodeSeek\n'
    msg+=$'🕒时间: '"${now_t}"$'\n'
    msg+=$'🌐标题: 这是来自脚本的测试推送（看到说明配置正常 ✅）\n'
    msg+=$'🔗链接: https://www.nodeseek.com/?sortBy=postTime'

    tg_send "$msg"
    echo -e "${GREEN}✅ Telegram 测试推送已发送（请到私聊查看）${PLAIN}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ Telegram 测试推送已发送" >> "$LOG_FILE"
}

# ============================================
# 日志轮转（按天：只保留“当天”日志，跨天自动归档并清空）
# ============================================
log_rotate() {
    local KEEP_DAYS=7
    local files=("$LOG_FILE" "$CRON_LOG")

    local today
    today=$(date +%Y-%m-%d)

    for f in "${files[@]}"; do
        [[ -f "$f" ]] || touch "$f"
        local last_day
        last_day=$(date -r "$f" +%Y-%m-%d 2>/dev/null || echo "$today")

        if [[ "$last_day" != "$today" ]]; then
            local archive="${f}.${last_day}"
            if [[ -f "$archive" ]]; then
                archive="${archive}.$(date +%H%M%S)"
            fi
            mv "$f" "$archive" 2>/dev/null || { cp -f "$f" "$archive" 2>/dev/null; }
            : > "$f"
        fi
    done

    find "$WORK_DIR" -maxdepth 1 -type f \( -name "nodeseek.log.*" -o -name "nodeseek_cron.log.*" \) -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
}

# ============================================
# cron 模式：每20秒执行一次 manual_fresh + auto_push
# 内置 flock 锁，避免重复启动
# ============================================
if [[ "$1" == "-cron" ]]; then
    LOCK_FILE="$WORK_DIR/nodeseek.lock"
    exec 200>"$LOCK_FILE"
    flock -n 200 || exit 0

    INTERVAL=20
    echo "$(date '+%Y-%m-%d %H:%M:%S') 🚀 定时任务已启动（每${INTERVAL}秒执行 manual_fresh + auto_push）" >> "$CRON_LOG"

    while true; do
        start_ts=$(date +%s)

        log_rotate

        trim_file() {
            local file="$1"
            local max_lines=120
            [[ -f "$file" ]] || return
            local cnt
            cnt=$(wc -l < "$file")
            if (( cnt > max_lines )); then
                tail -n "$max_lines" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
            fi
        }

        trim_file "$CRON_LOG"
        trim_file "$LOG_FILE"
        trim_file "$WORK_DIR/sent_nodeseek_ids.txt"

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
    exit 0
fi

# ============================================
# 设置定时任务（cron 每分钟触发一次，脚本内部自循环）
# ============================================
setup_cron() {
    local entry="* * * * * /root/TrafficCop/nodeseek.sh -cron"
    echo "🛠 正在检查并更新 nodeseek 定时任务（cron直跑，无 flock 包装）..."

    crontab -l 2>/dev/null \
        | grep -v "nodeseek.sh -cron" \
        | grep -v "/usr/bin/flock -n /tmp/nodeseek.lock" \
        > /tmp/cron.nodeseek.tmp || true

    {
        cat /tmp/cron.nodeseek.tmp
        echo "$entry"
    } | crontab -

    rm -f /tmp/cron.nodeseek.tmp
    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ nodeseek cron 已更新为：$entry" | tee -a "$CRON_LOG"
}

# ============================================
# 关闭定时任务
# ============================================
stop_cron() {
    echo -e "${YELLOW}⏳ 正在停止 nodeseek 定时任务...${PLAIN}"

    pkill -f "nodeseek.sh -cron" 2>/dev/null

    crontab -l 2>/dev/null \
        | grep -v "nodeseek.sh -cron" \
        | grep -v "/usr/bin/flock -n /tmp/nodeseek.lock" \
        | crontab - 2>/dev/null

    echo -e "${GREEN}✔ 已从 crontab 中移除 nodeseek 定时任务${PLAIN}"
    systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null
    echo -e "${GREEN}✔ nodeseek 定时监控已完全停止${PLAIN}"
}

# ============================================
# 主菜单
# ============================================
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${PURPLE} NodeSeek 监控管理菜单（Telegram个人推送）${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 安装/修改配置"
        echo -e "${GREEN}2.${PLAIN} 打印最新帖子（缓存）"
        echo -e "${GREEN}3.${PLAIN} 推送最新帖子（关键词匹配）"
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
