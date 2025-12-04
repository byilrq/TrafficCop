#!/bin/bash
# ============================================
# Telegram 通知脚本 for TrafficCop（完整版）
# 文件名建议：/root/TrafficCop/tg_notifier.sh
# ============================================
export TZ='Asia/Shanghai'

WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"

CONFIG_FILE="$WORK_DIR/telegram_config.txt"
CRON_LOG="$WORK_DIR/telegram_cron.log"
SCRIPT_PATH="$WORK_DIR/tg_notifier.sh"

TRAFFIC_CONFIG="$WORK_DIR/traffic_config.txt"
OFFSET_FILE="$WORK_DIR/traffic_offset.dat"

# 颜色
RED="\033[31m" GREEN="\033[32m" YELLOW="\033[33m" BLUE="\033[34m"
PURPLE="\033[35m" CYAN="\033[36m" WHITE="\033[37m" PLAIN="\033[0m"

echo "----------------------------------------------" | tee -a "$CRON_LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S') : 启动 Telegram 通知脚本" | tee -a "$CRON_LOG"
cd "$WORK_DIR" || exit 1

# ==================== 防重 ====================
check_running() {
    if pidof -x "$(basename "$0")" -o $$ >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 脚本已在运行，退出。" | tee -a "$CRON_LOG"
        exit 1
    fi
}

# ==================== 配置读写 ====================
read_config() {
    [ ! -s "$CONFIG_FILE" ] && return 1
    source "$CONFIG_FILE"
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
}

# ==================== 读取流量配置 ====================
read_traffic_config() {
    [ ! -s "$TRAFFIC_CONFIG" ] && return 1
    source "$TRAFFIC_CONFIG"
    [[ -z "$MAIN_INTERFACE" || -z "$TRAFFIC_MODE" || -z "$TRAFFIC_LIMIT" || -z "$TRAFFIC_TOLERANCE" ]] && return 1
    return 0
}

# ==================== 周期计算（与原版完全一致） ====================
get_period_start_date() {
    local y m d
    y=$(date +%Y); m=$(date +%m); d=$(date +%d)
    case $TRAFFIC_PERIOD in
        monthly)
            [ "$d" -lt "$PERIOD_START_DAY" ] && date -d "$y-$m-$PERIOD_START_DAY -1 month" +%Y-%m-%d || date -d "$y-$m-$PERIOD_START_DAY" +%Y-%m-%d
            ;;
        quarterly)
            local qm=$(( ((10#$m-1)/3*3 +1) )); qm=$(printf "%02d" $qm)
            [ "$d" -lt "$PERIOD_START_DAY" ] && date -d "$y-$qm-$PERIOD_START_DAY -3 months" +%Y-%m-%d || date -d "$y-$qm-$PERIOD_START_DAY" +%Y-%m-%d
            ;;
        yearly)
            [ "$d" -lt "$PERIOD_START_DAY" ] && date -d "$((y-1))-01-$PERIOD_START_DAY" +%Y-%m-%d || date -d "$y-01-$PERIOD_START_DAY" +%Y-%m-%d
            ;;
        *) date -d "$y-$m-${PERIOD_START_DAY:-1}" +%Y-%m-%d ;;
    esac
}

get_period_end_date() {
    local start="$1"
    case "$TRAFFIC_PERIOD" in
        monthly)   date -d "$start +1 month -1 day" +%Y-%m-%d ;;
        quarterly) date -d "$start +3 month -1 day" +%Y-%m-%d ;;
        yearly)    date -d "$start +1 year -1 day" +%Y-%m-%d ;;
        *)         date -d "$start +1 month -1 day" +%Y-%m-%d ;;
    esac
}

get_traffic_usage() {
    local offset raw_bytes=0 line rx tx
    offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>/dev/null || echo "")
    case $TRAFFIC_MODE in
        out)   raw_bytes=$(echo "$line"|cut -d';' -f10) ;;
        in)    raw_bytes=$(echo "$line"|cut -d';' -f9) ;;
        total)  raw_bytes=$(echo "$line"|cut -d';' -f11) ;;
        max)
            rx=$(echo "$line"|cut -d';' -f9); tx=$(echo "$line"|cut -d';' -f10)
            [[ $rx -gt $tx ]] 2>/dev/null && raw_bytes=$rx || raw_bytes=$tx
            ;;
    esac
    raw_bytes=${raw_bytes:-0}
    local real=$((raw_bytes - offset))
    [ "$real" -lt 0 ] && real=0
    printf "%.3f" "$(echo "scale=6; $real/1024/1024/1024" | bc 2>/dev/null || echo 0)"
}

# ==================== Telegram 发送 ====================
tg_send() {
    local text="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${text}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true" >/dev/null
    if [ $? -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : Telegram 发送成功" | tee -a "$CRON_LOG"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') : Telegram 发送失败" | tee -a "$CRON_LOG"
    fi
}

test_telegram() {
    tg_send "<b>${MACHINE_NAME}</b> 测试消息\n\nTelegram 配置正常！"
}

# ==================== 每日报告（5 行格式） ====================
daily_report() {
    read_traffic_config || return 1
    local usage start end limit today diff_days emoji
    usage=$(get_traffic_usage)
    start=$(get_period_start_date)
    end=$(get_period_end_date "$start")
    limit=$(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc 2>/dev/null || echo "未知")" GB"

    today=$(date +%Y-%m-%d)
    expire_ts=$(date -d "${EXPIRE_DATE//./-}" +%s 2>/dev/null)
    today_ts=$(date -d "$today" +%s)
    diff_days=$(( (expire_ts - today_ts)/86400 ))
    if [ "$diff_days" -lt 0 ];  then emoji="Overdue"; diff_days="$((-diff_days))天前"
    elif [ "$diff_days" -le 30 ]; then emoji="Warning"
    elif [ "$diff_days" -le 60 ]; then emoji="Warning"
    else emoji="OK"; fi

    tg_send "<b>${MACHINE_NAME}</b> 每日报告

日期：${today}
${emoji}剩余：${diff_days}天
周期：${start} 到 ${end}
已用：${usage} GB
套餐：${limit}"
}

# ==================== 实时流量打印 ====================
get_current_traffic() {
    read_traffic_config || { echo "请先运行 trafficcop.sh 初始化"; return; }
    local usage=$(get_traffic_usage)
    local start=$(get_period_start_date)
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

# ==================== 手动修正流量 ====================
flow_setting() {
    echo "请输入本周期实际已用流量（GB）:"
    read real_gb
    [[ ! $real_gb =~ ^[0-9]+(\.[0-9]+)?$ ]] && { echo "格式错误"; return; }
    read_traffic_config || return
    local line raw rx tx
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b)
    case $TRAFFIC_MODE in out) raw=$(echo $line|cut -d';' -f10) ;; in) raw=$(echo $line|cut -d';' -f9) ;; total) raw=$(echo $line|cut -d';' -f11) ;; max)
        rx=$(echo $line|cut -d';' -f9); tx=$(echo $line|cut -d';' -f10); [ $rx -gt $tx ] && raw=$rx || raw=$tx ;; esac
    raw=${raw:-0}
    local target_bytes=$(echo "$real_gb * 1024*1024*1024 / 1" | bc)
    local new_offset=$((raw - target_bytes))
    echo "$new_offset" > "$OFFSET_FILE"
    echo "已将 offset 设为 $new_offset（当前周期显示 ≈${real_gb} GB）"
}

# ==================== 配置初始化 ====================
initial_config() {
    echo "========== Telegram Bot Token =========="
    read -p "Bot Token: " TG_BOT_TOKEN
    echo "========== Chat ID =========="
    read -p "Chat ID  : " TG_CHAT_ID
    read -p "机器名称 [默认 $(hostname)]: " MACHINE_NAME; MACHINE_NAME=${MACHINE_NAME:-$(hostname)}
    read -p "每日报告时间 (HH:MM) [默认 01:00]: " DAILY_REPORT_TIME; DAILY_REPORT_TIME=${DAILY_REPORT_TIME:-01:00}
    read -p "VPS 到期日 (YYYY.MM.DD): " EXPIRE_DATE
    write_config
    echo "配置已保存！"
}

setup_cron() {
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH -cron"; echo "* * * * * $SCRIPT_PATH -cron") | crontab -
    echo "Cron 已添加（每分钟检查）"
}

# ==================== 主菜单 ====================
main() {
    check_running
    [[ "$*" == *"-cron"* ]] && {
        read_config || exit 0
        [[ $(date +%H:%M) == "$DAILY_REPORT_TIME" ]] && daily_report
        exit 0
    }

    if ! read_config; then
        echo "首次运行，进入配置向导..."
        initial_config
    fi
    setup_cron

    while :; do
        clear
        echo -e "${BLUE}========== Telegram 流量通知管理 ==========${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 发送每日报告"
        echo -e "${GREEN}2.${PLAIN} 发送测试消息"
        echo -e "${GREEN}3.${PLAIN} 查看实时流量"
        echo -e "${GREEN}4.${PLAIN} 修改配置"
        echo -e "${GREEN}5.${PLAIN} 手动修正已用流量"
        echo -e "${RED}6.${PLAIN} 停止服务（删除定时任务）"
        echo -e "${WHITE}0.${PLAIN} 退出"
        echo -e "${BLUE}======================================${PLAIN}"
        read -p "请选择 [0-6]: " choice
        case $choice in
            1) daily_report ;;
            2) test_telegram ;;
            3) get_current_traffic ;;
            4) initial_config ;;
            5) flow_setting ;;
            6) (crontab -l | grep -v "$SCRIPT_PATH -cron" | crontab -; echo "已停止") ; exit ;;
            0) exit ;;
        esac
        read -p "按回车继续..."
    done
}

main "$@"
