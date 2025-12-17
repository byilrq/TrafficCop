#!/bin/bash
# ============================================
# Telegram 流量监控通知脚本（完美复刻 pushplus 风格 + 最新消息格式）
# 文件名：/root/TrafficCop/tg_notifier.sh
# 版本：best-2025-12-17
# ============================================

export TZ='Asia/Shanghai'

WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"

CONFIG_FILE="$WORK_DIR/telegram_config.txt"
CRON_LOG="$WORK_DIR/telegram_cron.log"
SCRIPT_PATH="$WORK_DIR/tg_notifier.sh"

TRAFFIC_CONFIG="$WORK_DIR/traffic_config.txt"
OFFSET_FILE="$WORK_DIR/traffic_offset.dat"

# cron 锁（防止重复实例）
LOCK_FILE="/tmp/tg_notifier.lock"

# 颜色
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"
PURPLE="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"; PLAIN="\033[0m"

cd "$WORK_DIR" || exit 1

# ==================== 日志裁剪：只保留最近100行 ====================
trim_cron_log() {
    local file="$CRON_LOG"
    local max_lines=100
    [[ -f "$file" ]] || return 0

    local cnt
    cnt=$(wc -l < "$file" 2>/dev/null || echo 0)

    if (( cnt > max_lines )); then
        tail -n "$max_lines" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

log_cron() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $*" | tee -a "$CRON_LOG" >/dev/null
    trim_cron_log
}

# ==================== 防并发（cron/手动都适用） ====================
acquire_lock_or_exit() {
    # 需要系统有 /usr/bin/flock
    if command -v flock >/dev/null 2>&1; then
        exec 200>"$LOCK_FILE"
        flock -n 200 || {
            log_cron "已有实例运行（flock锁占用），退出。"
            exit 0
        }
    else
        # 兼容：没有 flock 则退化为 pidof 检查
        if pidof -x "$(basename "$0")" -o $$ >/dev/null 2>&1; then
            log_cron "已有实例运行（pidof检测），退出。"
            exit 0
        fi
    fi
}

read_config() {
    [ ! -s "$CONFIG_FILE" ] && return 1
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" || -z "$MACHINE_NAME" || -z "$DAILY_REPORT_TIME" || -z "$EXPIRE_DATE" ]] && return 1
    return 0
}

write_config() {
    cat >"$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
MACHINE_NAME="$MACHINE_NAME"
DAILY_REPORT_TIME="$DAILY_REPORT_TIME"
EXPIRE_DATE="$EXPIRE_DATE"
EOF
    log_cron "配置已保存到 $CONFIG_FILE"
}

read_traffic_config() {
    [ ! -s "$TRAFFIC_CONFIG" ] && return 1
    # shellcheck disable=SC1090
    source "$TRAFFIC_CONFIG" 2>/dev/null
    [[ -z "$MAIN_INTERFACE" || -z "$TRAFFIC_MODE" || -z "$TRAFFIC_LIMIT" || -z "$TRAFFIC_TOLERANCE" ]] && return 1
    return 0
}

get_period_start_date() {
    local y m d
    y=$(date +%Y); m=$(date +%m); d=$(date +%d)
    case $TRAFFIC_PERIOD in
        monthly)
            [ "$d" -lt "$PERIOD_START_DAY" ] && date -d "$y-$m-$PERIOD_START_DAY -1 month" +%Y-%m-%d 2>/dev/null || date -d "$y-$m-$PERIOD_START_DAY" +%Y-%m-%d
            ;;
        quarterly)
            local qm
            qm=$(( ((10#$m-1)/3*3 +1) ))
            qm=$(printf "%02d" "$qm")
            [ "$d" -lt "$PERIOD_START_DAY" ] && date -d "$y-$qm-$PERIOD_START_DAY -3 months" +%Y-%m-%d 2>/dev/null || date -d "$y-$qm-$PERIOD_START_DAY" +%Y-%m-%d
            ;;
        yearly)
            [ "$d" -lt "$PERIOD_START_DAY" ] && date -d "$((y-1))-01-$PERIOD_START_DAY" +%Y-%m-%d 2>/dev/null || date -d "$y-01-$PERIOD_START_DAY" +%Y-%m-%d
            ;;
        *)
            date -d "$y-$m-${PERIOD_START_DAY:-1}" +%Y-%m-%d 2>/dev/null
            ;;
    esac
}

get_period_end_date() {
    local start="$1"
    case "$TRAFFIC_PERIOD" in
        monthly)   date -d "$start +1 month -1 day" +%Y-%m-%d 2>/dev/null ;;
        quarterly) date -d "$start +3 month -1 day" +%Y-%m-%d 2>/dev/null ;;
        yearly)    date -d "$start +1 year -1 day" +%Y-%m-%d 2>/dev/null ;;
        *)         date -d "$start +1 month -1 day" +%Y-%m-%d 2>/dev/null ;;
    esac
}

get_traffic_usage() {
    local offset raw=0 line rx tx
    offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>/dev/null || echo "")

    case $TRAFFIC_MODE in
        out)   raw=$(echo "$line" | cut -d';' -f10) ;;
        in)    raw=$(echo "$line" | cut -d';' -f9) ;;
        total) raw=$(echo "$line" | cut -d';' -f11) ;;
        max)
            rx=$(echo "$line" | cut -d';' -f9)
            tx=$(echo "$line" | cut -d';' -f10)
            [[ $rx -gt $tx ]] 2>/dev/null && raw=$rx || raw=$tx
            ;;
        *) raw=0 ;;
    esac

    raw=${raw:-0}
    local real=$((raw - offset))
    (( real < 0 )) && real=0

    printf "%.3f" "$(echo "scale=6; $real/1024/1024/1024" | bc 2>/dev/null || echo 0)"
}

# ==================== Telegram 发送 ====================
tg_send() {
    local text="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${text}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true" > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_cron "Telegram 推送成功"
    else
        log_cron "Telegram 推送失败"
    fi
}

test_telegram() {
    tg_send "🖥️ <b>[${MACHINE_NAME}]</b> 测试消息\n\n这是一条测试消息，如果您收到此推送，说明 Telegram 配置正常！"
}

# ==================== 每日报告（你要求的格式） ====================
daily_report() {
    if ! read_traffic_config; then
        log_cron "未找到 TrafficCop 配置（$TRAFFIC_CONFIG）"
        return 1
    fi

    local usage start end limit today expire_ts today_ts diff_days remain_emoji
    usage=$(get_traffic_usage)
    start=$(get_period_start_date)
    end=$(get_period_end_date "$start")
    limit="${TRAFFIC_LIMIT} GB"

    today=$(date +%Y-%m-%d)
    expire_ts=$(date -d "${EXPIRE_DATE//./-}" +%s 2>/dev/null)
    today_ts=$(date -d "$today" +%s 2>/dev/null)
    diff_days=$(( (expire_ts - today_ts) / 86400 ))

    remain_emoji="🟢"
    if (( diff_days <= 0 )); then
        remain_emoji="⚫"; diff_days="已到期"
    elif (( diff_days <= 30 )); then
        remain_emoji="🔴"
    elif (( diff_days <= 60 )); then
        remain_emoji="🟡"
    fi

    tg_send "🎯 <b>[${MACHINE_NAME}]</b> 每日报告

🕒日期：${today}
${remain_emoji}剩余：${diff_days}天
🔄周期：${start} 到 ${end}
⌛已用：${usage} GB
🌐套餐：${limit}"
}

get_current_traffic() {
    read_traffic_config || { echo "请先运行 trafficcop.sh 初始化"; return; }
    local usage start
    usage=$(get_traffic_usage)
    start=$(get_period_start_date)

    echo "========================================"
    echo "       实时流量信息"
    echo "========================================"
    echo "机器名   : $MACHINE_NAME"
    echo "接口     : $MAIN_INTERFACE"
    echo "模式     : $TRAFFIC_MODE"
    echo "周期起   : $start"
    echo "已用     : $usage GB"
    echo "套餐     : $TRAFFIC_LIMIT GB（容错 $TRAFFIC_TOLERANCE GB）"
    echo "========================================"
}

flow_setting() {
    echo "请输入本周期实际已用流量（GB）:"
    read -r real_gb
    [[ ! $real_gb =~ ^[0-9]+(\.[0-9]+)?$ ]] && { echo "输入无效"; return; }
    read_traffic_config || return

    local line raw rx tx
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>/dev/null)

    case $TRAFFIC_MODE in
        out)   raw=$(echo "$line" | cut -d';' -f10) ;;
        in)    raw=$(echo "$line" | cut -d';' -f9) ;;
        total) raw=$(echo "$line" | cut -d';' -f11) ;;
        max)
            rx=$(echo "$line" | cut -d';' -f9)
            tx=$(echo "$line" | cut -d';' -f10)
            [[ $rx -gt $tx ]] 2>/dev/null && raw=$rx || raw=$tx
            ;;
        *) raw=0 ;;
    esac

    raw=${raw:-0}
    local target_bytes
    target_bytes=$(echo "$real_gb * 1024*1024*1024" | bc 2>/dev/null | cut -d. -f1)
    target_bytes=${target_bytes:-0}

    local new_offset=$((raw - target_bytes))
    echo "$new_offset" > "$OFFSET_FILE"
    echo "已修正 offset → $new_offset（当前显示 ≈${real_gb} GB）"
}

initial_config() {
    echo "======================================"
    echo "      修改 Telegram 配置"
    echo "======================================"
    echo

    if [ -n "$TG_BOT_TOKEN" ]; then
        local tshow="${TG_BOT_TOKEN:0:8}...${TG_BOT_TOKEN: -4}"
        echo "请输入 Bot Token [当前: $tshow]: "
    else
        echo "请输入 Bot Token: "
    fi
    read -r new_token
    [[ -z "$new_token" && -n "$TG_BOT_TOKEN" ]] && new_token="$TG_BOT_TOKEN"
    while [ -z "$new_token" ]; do echo "不能为空！"; read -r new_token; done

    if [ -n "$TG_CHAT_ID" ]; then
        echo "请输入 Chat ID [当前: $TG_CHAT_ID]: "
    else
        echo "请输入 Chat ID: "
    fi
    read -r new_chat
    [[ -z "$new_chat" && -n "$TG_CHAT_ID" ]] && new_chat="$TG_CHAT_ID"
    while [ -z "$new_chat" ]; do echo "不能为空！"; read -r new_chat; done

    echo "请输入机器名称 [当前: ${MACHINE_NAME:-未设置}]: "
    read -r new_name
    [[ -z "$new_name" ]] && new_name="${MACHINE_NAME:-$(hostname)}"
    while [ -z "$new_name" ]; do read -r new_name; done

    echo "请输入每日报告时间 (HH:MM) [当前: ${DAILY_REPORT_TIME:-01:00}]: "
    read -r new_time
    [[ -z "$new_time" ]] && new_time="${DAILY_REPORT_TIME:-01:00}"
    while ! [[ $new_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; do
        echo "格式错误！请重新输入 (HH:MM): "
        read -r new_time
    done

    echo "请输入 VPS 到期日期 (YYYY.MM.DD) [当前: ${EXPIRE_DATE:-未设置}]: "
    read -r new_expire
    [[ -z "$new_expire" ]] && new_expire="$EXPIRE_DATE"
    while ! [[ $new_expire =~ ^[0-9]{4}\.[0-1][0-9]\.[0-3][0-9]$ ]]; do
        echo "格式错误！请重新输入 (YYYY.MM.DD): "
        read -r new_expire
    done

    TG_BOT_TOKEN="$new_token"
    TG_CHAT_ID="$new_chat"
    MACHINE_NAME="$new_name"
    DAILY_REPORT_TIME="$new_time"
    EXPIRE_DATE="$new_expire"

    write_config
    echo "Telegram 配置已更新成功！"
}

# ==================== cron：每分钟触发一次（脚本内部判断时间点） ====================
setup_cron() {
    # 用 flock 防并发：避免重复实例造成日志狂刷
    local cron_entry="* * * * * /usr/bin/flock -n ${LOCK_FILE} ${SCRIPT_PATH} -cron"

    (crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH} -cron" ; echo "$cron_entry") | crontab -
    log_cron "已写入 cron：$cron_entry"
}

stop_service() {
    crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH} -cron" | crontab -
    log_cron "Telegram 定时任务已移除"
    exit 0
}

main() {
    acquire_lock_or_exit

    # 启动日志（并自动裁剪）
    echo "----------------------------------------------" | tee -a "$CRON_LOG" >/dev/null
    log_cron "启动 Telegram 通知脚本"

    if [[ "$*" == *"-cron"* ]]; then
        read_config || exit 0
        [[ $(date +%H:%M) == "$DAILY_REPORT_TIME" ]] && daily_report
        exit 0
    fi

    read_config || echo "首次运行请先选择 4 配置 Telegram"
    setup_cron

    while true; do
        clear
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${PURPLE}     Telegram 流量通知管理菜单${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 发送${YELLOW}每日报告${PLAIN}"
        echo -e "${GREEN}2.${PLAIN} 发送${CYAN}测试消息${PLAIN}"
        echo -e "${GREEN}3.${PLAIN} 打印${YELLOW}实时流量${PLAIN}"
        echo -e "${GREEN}4.${PLAIN} 修改${PURPLE}配置${PLAIN}"
        echo -e "${RED}5.${PLAIN} 停止运行（移除定时任务）${PLAIN}"
        echo -e "${WHITE}0.${PLAIN} 退出${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        read -rp "请选择操作 [0-6]: " choice
        echo
        case "$choice" in
            1) daily_report ;;
            2) test_telegram ;;
            3) get_current_traffic ;;
            4) initial_config ;;
            5) stop_service ;;
            0) exit 0 ;;
            *) echo "无效选项，请重新输入" ;;
        esac
        read -rp "按 Enter 返回菜单..."
    done
}

main "$@"
