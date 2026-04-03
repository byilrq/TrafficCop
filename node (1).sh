#!/bin/bash
# Python replacement wrapper for node monitor

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TZ='Asia/Shanghai'

WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"
CONFIG_FILE="$WORK_DIR/node_config.txt"
SCRIPT_PATH="$WORK_DIR/node.sh"
PYTHON_SCRIPT="$WORK_DIR/node_monitor.py"
CRON_LOG="$WORK_DIR/node_cron.log"
PID_FILE="$WORK_DIR/.node_python.pid"

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; PURPLE="\033[35m"; WHITE="\033[37m"; PLAIN="\033[0m"

read_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        return 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    [[ -z "$NS_URL" ]] && NS_URL="https://rss.nodeseek.com/?sortBy=postTime"
    [[ -z "$INTERVAL_SEC" ]] && INTERVAL_SEC="20"
    [[ -z "$DEBUG_LOG" ]] && DEBUG_LOG="0"
    return 0
}

escape_config_value() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

write_config() {
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$(escape_config_value "$TG_BOT_TOKEN")"
TG_PUSH_CHAT_ID="$(escape_config_value "$TG_PUSH_CHAT_ID")"
NS_URL="$(escape_config_value "$NS_URL")"
KEYWORDS="$(escape_config_value "$KEYWORDS")"
INTERVAL_SEC="$(escape_config_value "$INTERVAL_SEC")"
DEBUG_LOG="$(escape_config_value "$DEBUG_LOG")"
EOF
    echo -e "${GREEN}✅ 配置已保存到 $CONFIG_FILE${PLAIN}"
}

python_ready() {
    command -v python3 >/dev/null 2>&1
}

run_py() {
    if ! python_ready; then
        echo -e "${RED}❌ 未检测到 python3，请先安装 Python 3。${PLAIN}"
        return 1
    fi
    python3 "$PYTHON_SCRIPT" "$@"
}

is_running() {
    if [ ! -s "$PID_FILE" ]; then
        return 1
    fi
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

ensure_python_script() {
    if [ ! -f "$PYTHON_SCRIPT" ]; then
        echo -e "${RED}❌ 未找到 $PYTHON_SCRIPT，请先复制 Python 脚本。${PLAIN}"
        return 1
    fi
    return 0
}

setup_cron() {
    local entry="* * * * * /root/TrafficCop/node.sh -cron >/dev/null 2>&1"
    echo "🛠 正在检查并更新 node 定时任务（cron 负责保活，Python 常驻监控）..."
    crontab -l 2>/dev/null | grep -v "node.sh -cron" > /tmp/cron.node.tmp || true
    {
        cat /tmp/cron.node.tmp
        echo "$entry"
    } | crontab -
    rm -f /tmp/cron.node.tmp
    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ node cron 已更新为：$entry" >> "$CRON_LOG"
}

stop_cron() {
    echo -e "${YELLOW}⏳ 正在停止 node Python 监控...${PLAIN}"
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
    fi
    pkill -f "node_monitor.py run" 2>/dev/null || true
    rm -f "$PID_FILE"

    crontab -l 2>/dev/null | grep -v "node.sh -cron" | crontab - 2>/dev/null
    systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true
    echo -e "${GREEN}✔ node 定时监控已完全停止${PLAIN}"
}

start_monitor() {
    ensure_python_script || return 1
    read_config || {
        echo -e "${RED}❌ 配置文件不存在或为空，请先执行配置向导。${PLAIN}"
        return 1
    }
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        echo -e "${GREEN}✔ node Python 监控已在运行，PID=$pid${PLAIN}"
        return 0
    fi
    nohup python3 "$PYTHON_SCRIPT" run >/dev/null 2>&1 &
    sleep 1
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        echo "$(date '+%Y-%m-%d %H:%M:%S') 🚀 node Python 监控已启动 PID=$pid" >> "$CRON_LOG"
        echo -e "${GREEN}✔ node Python 监控已启动，PID=$pid${PLAIN}"
        return 0
    fi
    echo -e "${RED}❌ node Python 监控启动失败，请查看 $WORK_DIR/node.log${PLAIN}"
    return 1
}

initial_config() {
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} node Python 版新帖监控 配置向导${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    echo
    echo "提示：按 Enter 保留当前配置，输入新值将覆盖原配置。"
    echo

    read_config || true

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

    if [ -n "$TG_PUSH_CHAT_ID" ]; then
        read -rp "请输入个人推送 Chat ID [当前: $TG_PUSH_CHAT_ID]: " new_chat_id
        [[ -z "$new_chat_id" ]] && new_chat_id="$TG_PUSH_CHAT_ID"
    else
        read -rp "请输入个人推送 Chat ID（不知道可先填0，稍后再改）: " new_chat_id
        [[ -z "$new_chat_id" ]] && new_chat_id="0"
    fi

    local default_url="https://rss.nodeseek.com/?sortBy=postTime"
    if [ -n "$NS_URL" ]; then
        read -rp "请输入要监控的 RSS URL [当前: $NS_URL] (回车默认最新帖): " new_url
        [[ -z "$new_url" ]] && new_url="$NS_URL"
    else
        read -rp "请输入要监控的 RSS URL [默认: $default_url]: " new_url
        [[ -z "$new_url" ]] && new_url="$default_url"
    fi

    echo
    if [ -n "$INTERVAL_SEC" ]; then
        read -rp "请输入监控间隔秒数 [当前: $INTERVAL_SEC]（建议>=20，最低15）: " new_interval
        [[ -z "$new_interval" ]] && new_interval="$INTERVAL_SEC"
    else
        read -rp "请输入监控间隔秒数 [默认: 20]（建议>=20，最低15）: " new_interval
        [[ -z "$new_interval" ]] && new_interval="20"
    fi
    if ! [[ "$new_interval" =~ ^[0-9]+$ ]]; then
        new_interval="20"
    fi
    if (( new_interval < 15 )); then
        new_interval="15"
    fi

    echo
    local current_debug="${DEBUG_LOG:-0}"
    read -rp "是否开启 Debug 日志？[当前: $current_debug] (0/1): " new_debug
    [[ -z "$new_debug" ]] && new_debug="$current_debug"
    [[ "$new_debug" != "1" ]] && new_debug="0"

    echo
    echo "当前关键词：${KEYWORDS:-未设置}"
    echo "支持写法："
    echo "  - 单关键词：抽奖"
    echo "  - 双关键词AND：车&box   （标题里必须同时包含“车”和“box”）"
    echo
    read -rp "是否需要重置关键词？(Y/N): " reset_kw
    if [[ "$reset_kw" =~ ^[Yy]$ ]]; then
        while true; do
            echo "请输入关键词（多个用 , 分隔），示例：抽奖,cloudsilk,车&box"
            read -rp "输入关键词(留空=清空关键词): " new_keywords
            if [[ -z "$new_keywords" ]]; then
                KEYWORDS=""
                echo "关键词已清空。"
                break
            fi
            new_keywords=${new_keywords//,/ }
            new_keywords=$(echo "$new_keywords" | xargs)
            local kw_count
            kw_count=$(wc -w <<< "$new_keywords")
            if (( kw_count > 20 )); then
                echo "❌ 关键词数量建议不超过 20 个（当前：$kw_count 个）。请重新输入。"
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
    INTERVAL_SEC="$new_interval"
    DEBUG_LOG="$new_debug"
    write_config
    setup_cron
    stop_cron >/dev/null 2>&1 || true
    start_monitor
}

print_latest() {
    ensure_python_script || return 1
    run_py print-latest
}

manual_push() {
    ensure_python_script || return 1
    run_py manual-push
}

test_notification() {
    ensure_python_script || return 1
    run_py test
}

manual_refresh() {
    ensure_python_script || return 1
    run_py refresh
}

show_status() {
    ensure_python_script || return 1
    run_py status
}


if [[ "$1" == "-cron" ]]; then
    ensure_python_script || exit 1
    start_monitor
    exit $?
fi

if [[ "$1" == "-stop" ]]; then
    stop_cron
    exit $?
fi

if [[ "$1" == "-status" ]]; then
    show_status
    exit $?
fi

if [[ "$1" == "-refresh" ]]; then
    manual_refresh
    exit $?
fi

if [[ "$1" == "-manual-push" ]]; then
    manual_push
    exit $?
fi

if [[ "$1" == "-test" ]]; then
    test_notification
    exit $?
fi

if [[ "$1" == "-print" ]]; then
    print_latest
    exit $?
fi

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${PURPLE} node Python 监控管理菜单 ${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 安装/修改配置"
        echo -e "${GREEN}2.${PLAIN} 打印最新帖子"
        echo -e "${GREEN}3.${PLAIN} 推送最新帖子"
        echo -e "${GREEN}4.${PLAIN} 推送测试消息"
        echo -e "${GREEN}5.${PLAIN} 手动刷新"
        echo -e "${GREEN}6.${PLAIN} 查看运行状态"
        echo -e "${RED}7.${PLAIN} 清除cron任务"
        echo -e "${WHITE}0.${PLAIN} 退出"
        echo -e "${BLUE}======================================${PLAIN}"
        read -rp "请选择操作 [0-7]: " choice
        echo
        case $choice in
            1) initial_config; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            2) print_latest; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            3) manual_push; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            4) test_notification; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            5) manual_refresh; echo -e "${GREEN}手动更新完成。${PLAIN}" ;;
            6) show_status; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            7) stop_cron; echo -e "${GREEN}停止cron任务完成。${PLAIN}" ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
        read -rp "按 Enter 返回菜单..."
    done
}

main_menu
