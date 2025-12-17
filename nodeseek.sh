#!/bin/bash
# ============================================
# Telegram Channel → nodeseek 监控脚本 v1.3 (Telegram个人推送版 / 美化推送格式)
# 作者：by / 更新时间：2025-12-17
# ============================================
# 强制 UTF-8 locale
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# 配置路径
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"
CONFIG_FILE="$WORK_DIR/nodeseek_config.txt"
LOG_FILE="$WORK_DIR/nodeseek.log"
CRON_LOG="$WORK_DIR/nodeseek_cron.log"
SCRIPT_PATH="$WORK_DIR/nodeseek.sh"
LOCK_FILE="/tmp/nodeseek.lock"
# ================== 彩色定义 ==================
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; PURPLE="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"; PLAIN="\033[0m"
export TZ='Asia/Shanghai'
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
    # 基础校验
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_PUSH_CHAT_ID" ] || [ -z "$TG_CHANNELS" ]; then
        echo -e "${RED}❌ 配置不完整（需 TG_BOT_TOKEN / TG_PUSH_CHAT_ID / TG_CHANNELS），请重新配置。${PLAIN}"
        return 1
    fi
    return 0
}
write_config() {
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_PUSH_CHAT_ID="$TG_PUSH_CHAT_ID"
TG_CHANNELS="$TG_CHANNELS"
KEYWORDS="$KEYWORDS"
EOF
    echo -e "${GREEN}✅ 配置已保存到 $CONFIG_FILE${PLAIN}"
}
# ============================================
# 时间格式：2025.12.08.10:40
# ============================================
fmt_time() {
    date '+%Y.%m.%d.%H:%M'
}
# ============================================
# Telegram 推送（个人私聊 chat_id）
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
    echo -e "${PURPLE} nodeseek 配置向导（Telegram个人推送）${PLAIN}"
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
        read -rp "请输入个人推送 Chat ID（不知道可先填0，稍后用菜单7获取再改）: " new_chat_id
        [[ -z "$new_chat_id" ]] && new_chat_id="0"
    fi
    # --- Telegram Channel(s) for monitoring ---
    if [ -n "$TG_CHANNELS" ]; then
        read -rp "请输入要监控的 Telegram 频道 [当前: $TG_CHANNELS] (可输入多个或URL): " new_channels
        [[ -z "$new_channels" ]] && new_channels="$TG_CHANNELS"
    else
        read -rp "请输入要监控的 Telegram 频道（多个用空格分隔）: " new_channels
        while [[ -z "$new_channels" ]]; do
            echo "❌ 频道不能为空，请重新输入。"
            read -rp "请输入频道名或URL: " new_channels
        done
    fi
    # --- 关键词过滤设置 ---
    echo ""
    echo "当前关键词：${KEYWORDS:-未设置}"
    read -rp "是否需要重置关键词？(Y/N): " reset_kw
    if [[ "$reset_kw" =~ ^[Yy]$ ]]; then
        while true; do
            echo "请输入关键词（多个关键词用 , 分隔），示例：上架,库存,补货"
            read -rp "输入关键词: " new_keywords
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
    TG_CHANNELS="$new_channels"
    write_config
    echo ""
    echo -e "${GREEN}✅ 配置已更新并保存成功！${PLAIN}"
    echo ""
    setup_cron
    read_config
}
# ============================================
# 提取标题函数
# ============================================
extract_title() {
    local message="$1"
    local pattern='^( *[0-9]+ ?(views?|次)? *$)|^[0-9]{1,2}:[0-9]{2}$|^[0-9]{4}/[0-9]{2}/[0-9]{2}'
    if [[ -z "$message" || "$message" =~ $pattern ]]; then
        echo ""
        return
    fi
    local title=""
    if [[ "$message" =~ 【([^】]+)】 ]]; then
        title="${BASH_REMATCH[1]}"
    else
        title=$(echo "$message" | head -n1)
    fi
    if [[ -z "$title" || ${#title} -lt 5 || "$title" =~ $pattern ]]; then
        title=""
    fi
    echo "$title"
}
# ============================================
# 手动打印
# ============================================
print_latest() {
    read_config || return
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} 最新频道消息标题${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"
        echo -e "${CYAN}频道：$ch${PLAIN}"
        if [ ! -s "$STATE_FILE" ]; then
            echo "最新标题：（暂无消息或提取失败）"
        else
            echo -e "最新10条标题（最新在下）："
            local i=1
            while read -r title; do
                echo "${i}) ${title}"
                ((i++))
            done < "$STATE_FILE"
        fi
        echo "--------------------------------------"
    done
}
# ============================================
# 手动刷新10条新的信息
# ============================================
manual_fresh() {
    read_config || return
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} 手动更新并打印所有频道${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"
        echo -e "${CYAN}频道：$ch${PLAIN}"
        local html
        html=$(curl -s --compressed -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" "https://t.me/s/${ch}")
        if [[ -z "$html" ]]; then
            echo "❌ 获取频道内容失败。"
            echo "--------------------------------------"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ❌ 手动更新失败（无法获取HTML）" >> "$LOG_FILE"
            continue
        fi
        local raw_messages=()
        while IFS= read -r line; do
            raw_messages+=("$line")
        done < <(echo "$html" | awk '
            BEGIN { RS="</div>" }
            /tgme_widget_message_text/ && !/tgme_widget_message_views/ && !/tgme_widget_message_date/ {
                gsub(/.*tgme_widget_message_text[^>]*>/, "")
                gsub(/<br>/, "\n")
                gsub(/<[^>]+>/, "")
                gsub(/&nbsp;/, " ")
                gsub(/&amp;/, "&")
                gsub(/&lt;/, "<")
                gsub(/&gt;/, ">")
                gsub(/&quot;/, "\"")
                gsub(/&#036;/, "$")
                gsub(/&#64;/, "@")
                gsub(/^[ \t\n\r]+|[ \t\n\r]+$/, "")
                if (length($0) > 0) print $0
            }
        ' | tail -n 10)
        local messages=()
        for raw in "${raw_messages[@]}"; do
            local title
            title=$(extract_title "$raw")
            [[ -n "$title" ]] && messages+=("$title")
        done
        if [[ ${#messages[@]} -eq 0 ]]; then
            echo "❌ 未提取到有效消息。"
            echo "--------------------------------------"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ❌ 最新消息更新失败（未解析到消息）" >> "$LOG_FILE"
            continue
        fi
        printf "%s\n" "${messages[@]}" > "$STATE_FILE"
        echo -e "${GREEN}最新10条消息标题（最新在下）：${PLAIN}"
        local i=1
        for msg in "${messages[@]}"; do
            echo "${i}) ${msg}"
            ((i++))
        done
        echo "--------------------------------------"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 最新消息已更新" >> "$LOG_FILE"
    done
    echo -e "${GREEN}✅ 所有频道已手动更新并打印完成。${PLAIN}"
}
# ============================================
# 手动推送10条新的信息（按关键词匹配）—— 美化格式
# ============================================
manual_push() {
    read_config || return
    local KEYWORDS_LOWER
    KEYWORDS_LOWER=$(echo "$KEYWORDS" | tr 'A-Z' 'a-z')
    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"
        echo -e "${CYAN}频道：$ch${PLAIN}"
        if [[ -z "$KEYWORDS" ]]; then
            echo "❌ 未设置关键词，跳过 [$ch]"
            continue
        fi
        if [[ ! -s "$STATE_FILE" ]]; then
            echo "❌ 无缓存文件，跳过 [$ch]"
            continue
        fi
        # 读取缓存
        local messages=()
        while IFS= read -r line; do messages+=("$line"); done < "$STATE_FILE"
        local total=${#messages[@]}
        local start=$(( total > 10 ? total - 10 : 0 ))
        local matched_msgs=()
        echo "当前关键词：$KEYWORDS"
        echo "最新10条消息标题匹配情况如下："
        for ((idx=start; idx<total; idx++)); do
            local msg="${messages[$idx]}"
            local msg_lower
            msg_lower=$(echo "$msg" | tr 'A-Z' 'a-z')
            local matched=0
            local matched_kw=""
            for kw in $KEYWORDS_LOWER; do
                if [[ "$msg_lower" == *"$kw"* ]]; then
                    matched=1
                    matched_kw="$kw"
                    break
                fi
            done
            if [[ $matched -eq 1 ]]; then
                matched_msgs+=("$msg")
                echo "${idx}) ${msg} --匹配：${matched_kw}"
            else
                echo "${idx}) ${msg} --不匹配"
            fi
        done
        echo ""
        if [[ ${#matched_msgs[@]} -eq 0 ]]; then
            echo "⚠️ 无匹配关键词消息"
            continue
        fi
        local now_t
        now_t=$(fmt_time)
        # 拼接为“测试推送”同款格式（多条匹配会连续输出多段）
        local push_text=""
        for msg in "${matched_msgs[@]}"; do
            local one_line
            one_line=$(echo "$msg" | tr '\r\n' ' ' | awk '{$1=$1;print}')
            push_text+=$'🎯Node\n'
            push_text+=$'🕒时间: '"${now_t}"$'\n'
            push_text+=$'🌐标题: '"${one_line}"$'\n\n'
        done
        tg_send "$push_text"
        echo "✅ 推送完成（匹配 ${#matched_msgs[@]} 条）"
    done
}
# ============================================
# 自动推送（用于 cron）—— 匹配关键词且只推送一次（美化格式）
# ============================================
auto_push() {
    read_config || return
    local KEYWORDS_LOWER
    KEYWORDS_LOWER=$(echo "$KEYWORDS" | tr 'A-Z' 'a-z')
    local SENT_FILE="$WORK_DIR/sent_nodeseekc.txt"
    [[ -f "$SENT_FILE" ]] || touch "$SENT_FILE"
    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"
        echo -e "${CYAN}自动推送频道：${ch}${PLAIN}"
        if [[ -z "$KEYWORDS" ]]; then
            echo "❌ 未设置关键词，跳过 [$ch]"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ⚠️无关键词，跳过自动推送" >> "$LOG_FILE"
            continue
        fi
        if [[ ! -s "$STATE_FILE" ]]; then
            echo "❌ 无缓存文件，跳过 [$ch]"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ⚠️无缓存文件" >> "$LOG_FILE"
            continue
        fi
        # 读取最近10条消息
        local messages=()
        while IFS= read -r line; do messages+=("$line"); done < "$STATE_FILE"
        local total=${#messages[@]}
        local start=$(( total > 10 ? total - 10 : 0 ))
        local new_matched_msgs=()
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 当前关键词：$KEYWORDS" >> "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 最新10条消息匹配情况如下：" >> "$LOG_FILE"
        for ((idx = start; idx < total; idx++)); do
            local msg="${messages[$idx]}"
            local msg_lower
            msg_lower=$(echo "$msg" | tr 'A-Z' 'a-z')
            local matched=0
            local matched_kw=""
            for kw in $KEYWORDS_LOWER; do
                if [[ "$msg_lower" == *"$kw"* ]]; then
                    matched=1
                    matched_kw="$kw"
                    break
                fi
            done
            if [[ $matched -eq 1 ]]; then
                if grep -Fxq "$msg" "$SENT_FILE"; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 已推送过（跳过）：${msg}" >> "$LOG_FILE"
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 匹配 ✔：${msg}（关键词：$matched_kw）" >> "$LOG_FILE"
                    new_matched_msgs+=("$msg")
                fi
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 未匹配 ✖：${msg}" >> "$LOG_FILE"
            fi
        done
        if [[ ${#new_matched_msgs[@]} -eq 0 ]]; then
            echo "⚠️ [$ch] 本次无关键词匹配或均已推送过"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ⚠️无匹配或均已推送过" >> "$LOG_FILE"
            continue
        fi
        local now_t
        now_t=$(fmt_time)
        # 拼接为“测试推送”同款格式
        local push_text=""
        for msg in "${new_matched_msgs[@]}"; do
            local one_line
            one_line=$(echo "$msg" | tr '\r\n' ' ' | awk '{$1=$1;print}')
            push_text+=$'🎯Node\n'
            push_text+=$'🕒时间: '"${now_t}"$'\n'
            push_text+=$'🌐标题: '"${one_line}"$'\n\n'
        done
        tg_send "$push_text"
        # 写入已推送记录
        for msg in "${new_matched_msgs[@]}"; do
            echo "$msg" >> "$SENT_FILE"
        done
        echo "📨 [$ch] 自动推送成功（${#new_matched_msgs[@]} 条）"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 📩 自动推送成功（${#new_matched_msgs[@]} 条）" >> "$LOG_FILE"
    done
}
# ============================================
# 测试 Telegram 推送（美化格式）
# ============================================
test_notification() {
    read_config || return
    echo -e "${CYAN}正在发送 Telegram 测试推送...${PLAIN}"
    local now_t
    now_t=$(fmt_time)
    local test_content="🎯Node\n🕒时间: ${now_t}\n🌐标题: 这是来自脚本的测试推送（看到说明配置正常 ✅）\n"
    tg_send "$test_content"
    echo -e "${GREEN}✅ Telegram 测试推送已发送（请到私聊查看）${PLAIN}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ Telegram 测试推送已发送" >> "$LOG_FILE"
}
# ============================================
# 日志轮转（保留最近 7 天归档）
# ============================================
log_rotate() {
    local log_dir="$WORK_DIR"
    local log_file="$CRON_LOG"
    local flag_file="$log_dir/log_clean.flag"
    local today
    today=$(date +%Y-%m-%d)
    if [[ -f "$flag_file" && "$(cat "$flag_file")" == "$today" ]]; then
        return
    fi
    echo "🔥 开始日志轮转：删除 7 天前的日志文件..." >> "$CRON_LOG"
    find "$log_dir" -name "*.log.*" -mtime +7 -delete
    if [[ -f "$log_file" ]]; then
        mv "$log_file" "${log_file}.${today}"
        touch "$log_file"
    fi
    echo "$today" > "$flag_file"
    echo "✔ 日志轮转完成" >> "$CRON_LOG"
}
# ============================================
# cron 模式：每30秒执行一次 manual_fresh + auto_push（使用flock防止多实例）
# ============================================
if [[ "$1" == "-cron" ]]; then
    exec /usr/bin/flock -n "$LOCK_FILE" -c "$0 -cron-locked"
    exit 0
fi
if [[ "$1" == "-cron-locked" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') 🚀 定时任务已启动（每30秒执行 manual_fresh + auto_push）" >> "$CRON_LOG"
    while true; do
        trim_file() {
            local file="$1"
            local max_lines=100
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
        trim_file "$WORK_DIR/sent_nodeseekc.txt"
        log_rotate
        echo "$(date '+%Y-%m-%d %H:%M:%S') ▶️ 执行 manual_fresh()" >> "$CRON_LOG"
        manual_fresh >> "$CRON_LOG" 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ manual_fresh() 执行完成" >> "$CRON_LOG"
        echo "$(date '+%Y-%m-%d %H:%M:%S') ▶️ 执行 auto_push()" >> "$CRON_LOG"
        auto_push >> "$CRON_LOG" 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ auto_push() 执行完成" >> "$CRON_LOG"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 🕒 等待30秒进入下次周期..." >> "$CRON_LOG"
        echo "" >> "$CRON_LOG"
        sleep 30
    done
    exit 0
fi
# ============================================
# 设置定时任务（cron每分钟触发一次，脚本内部每30秒循环，使用flock锁）
# ============================================
setup_cron() {
    local entry="* * * * * /bin/bash $SCRIPT_PATH -cron >> $CRON_LOG 2>&1"
    echo "🛠 正在检查并更新 nodeseek 定时任务（使用 flock 防止多实例）..."
    # 读取现有 crontab，删除旧的 nodeseek 形式（防止重复）
    crontab -l 2>/dev/null \
        | grep -v "nodeseek.sh -cron" \
        > /tmp/cron.nodeseek.tmp || true
    # 追加新的形式
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
    # 杀掉后台循环进程
    pkill -f "nodeseek.sh -cron" 2>/dev/null
    # 从 crontab 中移除 nodeseek 相关任务
    crontab -l 2>/dev/null \
        | grep -v "nodeseek.sh -cron" \
        | crontab - 2>/dev/null
    echo -e "${GREEN}✔ 已从 crontab 中移除 nodeseek 定时任务${PLAIN}"
    rm -f "$LOCK_FILE"
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
        echo -e "${PURPLE} VPS 监控管理菜单（Telegram个人推送）${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 安装/修改配置"
        echo -e "${GREEN}2.${PLAIN} 打印最新消息"
        echo -e "${GREEN}3.${PLAIN} 推送最新消息（关键词匹配）"
        echo -e "${GREEN}4.${PLAIN} 推送测试消息（Telegram）"
        echo -e "${GREEN}5.${PLAIN} 手动更新&打印"
        echo -e "${GREEN}6.${PLAIN} 清除cron任务"
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
