#!/bin/bash
# node Python monitor unified manager
# - Integrates deployment/update into node.sh
# - Menu 6 shows monitor status + cron status
# - Menu 7 becomes cron configuration submenu

set -u

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TZ='Asia/Shanghai'

WORK_DIR="/root/TrafficCop"
CONFIG_FILE="$WORK_DIR/node_config.txt"
SCRIPT_PATH="$WORK_DIR/node.sh"
PYTHON_SCRIPT="$WORK_DIR/node_monitor.py"
CRON_LOG="$WORK_DIR/node_cron.log"
PID_FILE="$WORK_DIR/.node_python.pid"

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; PURPLE="\033[35m"; WHITE="\033[37m"; PLAIN="\033[0m"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_PATH="$SELF_DIR/$(basename "$0")"

read_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        return 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    [[ -z "${NS_URL:-}" ]] && NS_URL="https://rss.nodeseek.com/?sortBy=postTime"
    [[ -z "${INTERVAL_SEC:-}" ]] && INTERVAL_SEC="20"
    [[ -z "${DEBUG_LOG:-}" ]] && DEBUG_LOG="0"
    return 0
}

escape_config_value() {
    local value="${1:-}"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

write_config() {
    mkdir -p "$WORK_DIR"
    cat > "$CONFIG_FILE" <<CFGEOF
TG_BOT_TOKEN="$(escape_config_value "${TG_BOT_TOKEN:-}")"
TG_PUSH_CHAT_ID="$(escape_config_value "${TG_PUSH_CHAT_ID:-}")"
NS_URL="$(escape_config_value "${NS_URL:-}")"
KEYWORDS="$(escape_config_value "${KEYWORDS:-}")"
INTERVAL_SEC="$(escape_config_value "${INTERVAL_SEC:-}")"
DEBUG_LOG="$(escape_config_value "${DEBUG_LOG:-}")"
CFGEOF
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
        echo -e "${RED}❌ 未找到 $PYTHON_SCRIPT，请先准备 node_monitor.py。${PLAIN}"
        return 1
    fi
    return 0
}

backup_if_exists() {
    local file="$1"
    if [ -f "$file" ]; then
        cp "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
    fi
}

find_source_python_script() {
    local candidates=(
        "$SELF_DIR/node_monitor.py"
        "/mnt/data/node_monitor.py"
        "$PYTHON_SCRIPT"
    )
    local f
    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

sync_program_files() {
    mkdir -p "$WORK_DIR"

    if [ "$SELF_PATH" != "$SCRIPT_PATH" ] && [ -f "$SELF_PATH" ]; then
        cp "$SELF_PATH" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo -e "${GREEN}✅ 已同步 node.sh -> $SCRIPT_PATH${PLAIN}"
    fi

    local src_py=""
    if src_py=$(find_source_python_script); then
        if [ "$src_py" != "$PYTHON_SCRIPT" ]; then
            backup_if_exists "$PYTHON_SCRIPT"
            cp "$src_py" "$PYTHON_SCRIPT"
            chmod +x "$PYTHON_SCRIPT"
            echo -e "${GREEN}✅ 已同步 node_monitor.py -> $PYTHON_SCRIPT${PLAIN}"
        fi
    else
        if [ ! -f "$PYTHON_SCRIPT" ]; then
            echo -e "${RED}❌ 未找到 node_monitor.py，已尝试以下位置：${PLAIN}"
            echo "   - $SELF_DIR/node_monitor.py"
            echo "   - /mnt/data/node_monitor.py"
            echo "   - $PYTHON_SCRIPT"
            return 1
        fi
    fi
    return 0
}

detect_cron_service_name() {
    local svc
    for svc in cron crond; do
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
                printf '%s\n' "$svc"
                return 0
            fi
        fi
        if pgrep -x "$svc" >/dev/null 2>&1; then
            printf '%s\n' "$svc"
            return 0
        fi
    done
    return 1
}

restart_cron_service() {
    systemctl restart cron 2>/dev/null || \
    systemctl restart crond 2>/dev/null || \
    service cron restart 2>/dev/null || \
    service crond restart 2>/dev/null || true
}

cron_entry() {
    echo "* * * * * $SCRIPT_PATH -cron >/dev/null 2>&1"
}

has_cron_entry() {
    crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH -cron"
}

setup_cron() {
    local entry
    entry="$(cron_entry)"
    echo "🛠 正在写入 node 定时任务..."
    crontab -l 2>/dev/null | grep -Fv "$SCRIPT_PATH -cron" > /tmp/cron.node.tmp 2>/dev/null || true
    {
        cat /tmp/cron.node.tmp 2>/dev/null
        echo "$entry"
    } | crontab -
    rm -f /tmp/cron.node.tmp
    restart_cron_service
    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ node cron 已更新为：$entry" >> "$CRON_LOG"
    echo -e "${GREEN}✅ cron 任务已创建/更新${PLAIN}"
}

remove_cron() {
    crontab -l 2>/dev/null | grep -Fv "$SCRIPT_PATH -cron" | crontab - 2>/dev/null || true
    restart_cron_service
    echo "$(date '+%Y-%m-%d %H:%M:%S') 🗑 已删除 node cron 任务" >> "$CRON_LOG"
    echo -e "${GREEN}✅ cron 任务已删除${PLAIN}"
}

cron_service_status() {
    local svc=""
    if svc=$(detect_cron_service_name 2>/dev/null); then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl is-active "$svc" 2>/dev/null && return 0
        fi
        pgrep -x "$svc" >/dev/null 2>&1 && return 0
    fi
    return 1
}

show_cron_status() {
    echo -e "${BLUE}========== cron 状态 ==========${PLAIN}"
    if has_cron_entry; then
        echo -e "cron任务: ${GREEN}已配置${PLAIN}"
        echo "任务内容: $(cron_entry)"
    else
        echo -e "cron任务: ${RED}未配置${PLAIN}"
    fi

    local svc=""
    if svc=$(detect_cron_service_name 2>/dev/null); then
        if cron_service_status; then
            echo -e "cron服务: ${GREEN}运行中${PLAIN} (${svc})"
        else
            echo -e "cron服务: ${YELLOW}未确认运行${PLAIN} (${svc})"
        fi
    else
        echo -e "cron服务: ${YELLOW}未识别服务名${PLAIN}（可能系统未安装 cron/crond）"
    fi

    echo
    echo "当前 crontab 中相关项："
    crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH -cron" || echo "（无）"
    echo -e "${BLUE}================================${PLAIN}"
}

stop_monitor() {
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
    echo -e "${GREEN}✔ node Python 监控已停止${PLAIN}"
}

stop_all() {
    stop_monitor
    remove_cron >/dev/null 2>&1 || true
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

self_install_or_update() {
    echo -e "${BLUE}正在执行程序部署/更新检查...${PLAIN}"
    sync_program_files || return 1
    return 0
}

initial_config() {
    self_install_or_update || return 1

    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} node Python 版新帖监控 配置向导${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    echo
    echo "提示：按 Enter 保留当前配置，输入新值将覆盖原配置。"
    echo

    read_config || true

    if [ -n "${TG_BOT_TOKEN:-}" ]; then
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

    if [ -n "${TG_PUSH_CHAT_ID:-}" ]; then
        read -rp "请输入个人推送 Chat ID [当前: $TG_PUSH_CHAT_ID]: " new_chat_id
        [[ -z "$new_chat_id" ]] && new_chat_id="$TG_PUSH_CHAT_ID"
    else
        read -rp "请输入个人推送 Chat ID（不知道可先填0，稍后再改）: " new_chat_id
        [[ -z "$new_chat_id" ]] && new_chat_id="0"
    fi

    local default_url="https://rss.nodeseek.com/?sortBy=postTime"
    if [ -n "${NS_URL:-}" ]; then
        read -rp "请输入要监控的 RSS URL [当前: $NS_URL] (回车默认最新帖): " new_url
        [[ -z "$new_url" ]] && new_url="$NS_URL"
    else
        read -rp "请输入要监控的 RSS URL [默认: $default_url]: " new_url
        [[ -z "$new_url" ]] && new_url="$default_url"
    fi

    echo
    if [ -n "${INTERVAL_SEC:-}" ]; then
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

    if has_cron_entry; then
        echo "当前已存在 cron 任务，将保留。"
    else
        echo
        read -rp "是否现在创建 cron 保活任务？(Y/N): " install_cron_now
        if [[ "$install_cron_now" =~ ^[Yy]$ ]]; then
            setup_cron
        else
            echo -e "${YELLOW}ℹ️ 已跳过创建 cron 任务，可稍后在菜单 7 中配置。${PLAIN}"
        fi
    fi

    stop_monitor >/dev/null 2>&1 || true
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
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} node 运行状态 ${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"

    if ensure_python_script >/dev/null 2>&1; then
        local py_status
        py_status="$(python3 "$PYTHON_SCRIPT" status 2>/dev/null || true)"
        if [[ "$py_status" == RUNNING* ]]; then
            echo -e "Python监控: ${GREEN}$py_status${PLAIN}"
        else
            echo -e "Python监控: ${RED}STOPPED${PLAIN}"
        fi
    else
        echo -e "Python监控: ${RED}未找到 node_monitor.py${PLAIN}"
    fi

    if [ -s "$PID_FILE" ]; then
        echo "PID文件: $(cat "$PID_FILE" 2>/dev/null)"
    else
        echo "PID文件: 无"
    fi

    echo
    show_cron_status

    echo
    echo "最近 cron 日志（最后 5 行）："
    if [ -f "$CRON_LOG" ]; then
        tail -n 5 "$CRON_LOG" 2>/dev/null || true
    else
        echo "（无日志）"
    fi
    echo -e "${BLUE}======================================${PLAIN}"
}

cron_menu() {
    while true; do
        clear
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${PURPLE} cron 配置 ${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 创建/更新 cron 任务"
        echo -e "${GREEN}2.${PLAIN} 删除 cron 任务"
        echo -e "${GREEN}3.${PLAIN} 查看 cron 状态"
        echo -e "${WHITE}0.${PLAIN} 返回上级菜单"
        echo -e "${BLUE}======================================${PLAIN}"
        read -rp "请选择操作 [0-3]: " cron_choice
        echo
        case $cron_choice in
            1) setup_cron ;;
            2) remove_cron ;;
            3) show_cron_status ;;
            0) return 0 ;;
            *) echo "无效选项" ;;
        esac
        echo
        read -rp "按 Enter 返回..."
    done
}

if [[ "${1:-}" == "-cron" ]]; then
    ensure_python_script || exit 1
    start_monitor
    exit $?
fi

if [[ "${1:-}" == "-stop" ]]; then
    stop_all
    exit $?
fi

if [[ "${1:-}" == "-stop-monitor" ]]; then
    stop_monitor
    exit $?
fi

if [[ "${1:-}" == "-status" ]]; then
    show_status
    exit $?
fi

if [[ "${1:-}" == "-refresh" ]]; then
    manual_refresh
    exit $?
fi

if [[ "${1:-}" == "-manual-push" ]]; then
    manual_push
    exit $?
fi

if [[ "${1:-}" == "-test" ]]; then
    test_notification
    exit $?
fi

if [[ "${1:-}" == "-print" ]]; then
    print_latest
    exit $?
fi

if [[ "${1:-}" == "-deploy" ]]; then
    self_install_or_update
    exit $?
fi

if [[ "${1:-}" == "-cron-install" ]]; then
    setup_cron
    exit $?
fi

if [[ "${1:-}" == "-cron-remove" ]]; then
    remove_cron
    exit $?
fi

if [[ "${1:-}" == "-cron-status" ]]; then
    show_cron_status
    exit $?
fi

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${PURPLE} node Python 监控管理菜单 ${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 安装/修改配置（含部署更新）"
        echo -e "${GREEN}2.${PLAIN} 打印最新帖子"
        echo -e "${GREEN}3.${PLAIN} 推送最新帖子"
        echo -e "${GREEN}4.${PLAIN} 推送测试消息"
        echo -e "${GREEN}5.${PLAIN} 手动刷新"
        echo -e "${GREEN}6.${PLAIN} 查看任务运行情况"
        echo -e "${GREEN}7.${PLAIN} cron 配置"
        echo -e "${RED}8.${PLAIN} 停止监控并删除 cron 任务"
        echo -e "${WHITE}0.${PLAIN} 退出"
        echo -e "${BLUE}======================================${PLAIN}"
        read -rp "请选择操作 [0-8]: " choice
        echo
        case $choice in
            1) initial_config; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            2) print_latest; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            3) manual_push; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            4) test_notification; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            5) manual_refresh; echo -e "${GREEN}手动更新完成。${PLAIN}" ;;
            6) show_status; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            7) cron_menu ;;
            8) stop_all; echo -e "${GREEN}停止监控并清理 cron 完成。${PLAIN}" ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
        read -rp "按 Enter 返回菜单..."
    done
}

main_menu
