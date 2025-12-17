#!/bin/bash
# ============================================
# Telegram Channel → nodeseek 监控脚本 v1.3（稳定版：严格每30秒一次 + 防并发）
# 作者：by / 更新时间：2025-12-17
# ============================================

# 强制 UTF-8 locale
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

# 锁
LOCK_FILE="/tmp/nodeseek.lock"

# ================== 彩色定义 ==================
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; PURPLE="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"; PLAIN="\033[0m"

# ================== 小工具：裁剪文件行数 ==================
trim_file() {
    local file="$1"
    local max_lines="${2:-200}"
    [[ -f "$file" ]] || return 0
    local cnt
    cnt=$(wc -l < "$file" 2>/dev/null || echo 0)
    if (( cnt > max_lines )); then
        tail -n "$max_lines" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

log_cron() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$CRON_LOG"
    trim_file "$CRON_LOG" 200
}

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
# Telegram 推送
# ============================================
tg_send() {
    local content="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_PUSH_CHAT_ID}" \
        --data-urlencode "text=${content}" \
        -d "disable_web_page_preview=true" >/dev/null 2>&1
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
        read -rp "请输入个人推送 Chat ID（不知道可先填0）: " new_chat_id
        [[ -z "$new_chat_id" ]] && new_chat_id="0"
    fi

    # --- Telegram Channel(s) ---
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

    # --- 关键词 ---
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
# 打印最新缓存
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
# 手动/定时：刷新并更新缓存（每频道取最新10条）
# ============================================
manual_fresh() {
    read_config || return
    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"

        local html
        html=$(curl -s --compressed -L -A "Mozilla/5.0" "https://t.me/s/${ch}")
        if [[ -z "$html" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ❌ 获取HTML失败" >> "$LOG_FILE"
            continue
        fi

        local raw_messages=()
        while IFS= read -r line; do raw_messages+=("$line"); done < <(
            echo "$html" | awk '
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
            ' | tail -n 10
        )

        local titles=()
        for raw in "${raw_messages[@]}"; do
            local title
            title=$(extract_title "$raw")
            [[ -n "$title" ]] && titles+=("$title")
        done

        if [[ ${#titles[@]} -eq 0 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ❌ 未解析到有效标题" >> "$LOG_FILE"
            continue
        fi

        printf "%s\n" "${titles[@]}" > "$STATE_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 最新消息已更新" >> "$LOG_FILE"
    done

    trim_file "$LOG_FILE" 400
}

# ============================================
# 手动推送（按关键词匹配）
# ============================================
manual_push() {
    read_config || return

    if [[ -z "$KEYWORDS" ]]; then
        echo "❌ 未设置关键词"
        return
    fi

    local KEYWORDS_LOWER
    KEYWORDS_LOWER=$(echo "$KEYWORDS" | tr 'A-Z' 'a-z')

    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"
        [[ -s "$STATE_FILE" ]] || { echo "❌ [$ch] 无缓存文件"; continue; }

        local messages=()
        while IFS= read -r line; do messages+=("$line"); done < "$STATE_FILE"

        local matched_msgs=()
        for msg in "${messages[@]}"; do
            local msg_lower
            msg_lower=$(echo "$msg" | tr 'A-Z' 'a-z')
            for kw in $KEYWORDS_LOWER; do
                if [[ "$msg_lower" == *"$kw"* ]]; then
                    matched_msgs+=("$msg")
                    break
                fi
            done
        done

        [[ ${#matched_msgs[@]} -gt 0 ]] || { echo "⚠️ [$ch] 无匹配"; continue; }

        local now_t
        now_t=$(fmt_time)

        local push_text=""
        for msg in "${matched_msgs[@]}"; do
            local one_line
            one_line=$(echo "$msg" | tr '\r\n' ' ' | awk '{$1=$1;print}')
            push_text+=$'🎯Node\n'
            push_text+=$'🕒时间: '"${now_t}"$'\n'
            push_text+=$'🌐标题: '"${one_line}"$'\n\n'
        done

        tg_send "$push_text"
        echo "✅ [$ch] 推送完成（匹配 ${#matched_msgs[@]} 条）"
    done
}

# ============================================
# 自动推送（cron用：只推送未推过的匹配项）
# ============================================
auto_push() {
    read_config || return

    if [[ -z "$KEYWORDS" ]]; then
        return
    fi

    local KEYWORDS_LOWER
    KEYWORDS_LOWER=$(echo "$KEYWORDS" | tr 'A-Z' 'a-z')

    local SENT_FILE="$WORK_DIR/sent_nodeseekc.txt"
    [[ -f "$SENT_FILE" ]] || touch "$SENT_FILE"

    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"
        [[ -s "$STATE_FILE" ]] || continue

        local messages=()
        while IFS= read -r line; do messages+=("$line"); done < "$STATE_FILE"

        local new_matched_msgs=()
        for msg in "${messages[@]}"; do
            local msg_lower
            msg_lower=$(echo "$msg" | tr 'A-Z' 'a-z')

            local hit=0
            for kw in $KEYWORDS_LOWER; do
                [[ "$msg_lower" == *"$kw"* ]] && { hit=1; break; }
            done

            if (( hit == 1 )); then
                if ! grep -Fxq "$msg" "$SENT_FILE"; then
                    new_matched_msgs+=("$msg")
                fi
            fi
        done

        [[ ${#new_matched_msgs[@]} -gt 0 ]] || continue

        local now_t
        now_t=$(fmt_time)

        local push_text=""
        for msg in "${new_matched_msgs[@]}"; do
            local one_line
            one_line=$(echo "$msg" | tr '\r\n' ' ' | awk '{$1=$1;print}')
            push_text+=$'🎯Node\n'
            push_text+=$'🕒时间: '"${now_t}"$'\n'
            push_text+=$'🌐标题: '"${one_line}"$'\n\n'
        done

        tg_send "$push_text"
        printf "%s\n" "${new_matched_msgs[@]}" >> "$SENT_FILE"
    done

    trim_file "$SENT_FILE" 800
}

# ============================================
# 测试推送（修复：只传一个参数）
# ============================================
test_notification() {
    read_config || return
    local now_t
    now_t=$(fmt_time)
    local test_content="🎯Node\n🕒时间: ${now_t}\n🌐标题: 这是来自脚本的测试推送（看到说明配置正常 ✅）\n"
    tg_send "$test_content"
    echo "✅ Telegram 测试推送已发送"
}

# ============================================
# ✅ 关键：cron 单次执行模式（每次运行只跑一轮就退出）
# ============================================
run_once() {
    trim_file "$CRON_LOG" 200
    trim_file "$LOG_FILE" 400
    trim_file "$WORK_DIR/sent_nodeseekc.txt" 800

    log_cron "▶️ 执行 manual_fresh()"
    manual_fresh >/dev/null 2>&1
    log_cron "✅ manual_fresh() 执行完成"

    log_cron "▶️ 执行 auto_push()"
    auto_push >/dev/null 2>&1
    log_cron "✅ auto_push() 执行完成"
}

# ============================================
# 设置定时任务：每 30 秒触发一次（两条cron）+ flock 防并发
# ============================================
setup_cron() {
    local e1="* * * * * /usr/bin/flock -n ${LOCK_FILE} ${SCRIPT_PATH} -once"
    local e2="* * * * * sleep 30; /usr/bin/flock -n ${LOCK_FILE} ${SCRIPT_PATH} -once"

    echo "🛠 正在更新 nodeseek 定时任务（每30秒一次 + flock 防并发）..."

    crontab -l 2>/dev/null \
        | grep -v "${SCRIPT_PATH} -once" \
        | grep -v "${SCRIPT_PATH} -cron" \
        | grep -v "${LOCK_FILE}" \
        > /tmp/cron.nodeseek.tmp || true

    {
        cat /tmp/cron.nodeseek.tmp
        echo "$e1"
        echo "$e2"
    } | crontab -

    rm -f /tmp/cron.nodeseek.tmp

    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ nodeseek cron 已更新（每30秒一次）" | tee -a "$CRON_LOG" >/dev/null
    trim_file "$CRON_LOG" 200
}

# ============================================
# 停止定时任务
# ============================================
stop_cron() {
    echo -e "${YELLOW}⏳ 正在停止 nodeseek 定时任务...${PLAIN}"

    pkill -f "nodeseek.sh -cron" 2>/dev/null
    pkill -f "nodeseek.sh -once" 2>/dev/null

    crontab -l 2>/dev/null \
        | grep -v "${SCRIPT_PATH} -once" \
        | grep -v "${SCRIPT_PATH} -cron" \
        | grep -v "${LOCK_FILE}" \
        | crontab - 2>/dev/null

    echo -e "${GREEN}✔ 已移除 nodeseek cron 任务${PLAIN}"
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
            1) initial_config ;;
            2) print_latest ;;
            3) manual_push ;;
            4) test_notification ;;
            5) manual_fresh; echo -e "${GREEN}手动更新完成。${PLAIN}" ;;
            6) stop_cron ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
        read -p "按 Enter 返回菜单..."
    done
}

# ============================================
# 参数入口
# ============================================
if [[ "$1" == "-once" ]]; then
    run_once
    exit 0
fi

# 兼容旧的 -cron（防止你 crontab 里还有旧条目）
# 如果有人还在调用 -cron，这里直接执行一次并退出，避免 while true 常驻。
if [[ "$1" == "-cron" ]]; then
    run_once
    exit 0
fi

main_menu
