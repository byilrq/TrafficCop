#!/bin/bash
# ============================================
# PushPlus 通知脚本 v1.0（适配 Telegram 逻辑）
# 作者：by  / 更新时间：20251108
# ============================================

# 工作目录
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"

CONFIG_FILE="$WORK_DIR/pushplus_notifier_config.txt"
LOG_FILE="$WORK_DIR/traffic_monitor.log"
SCRIPT_PATH="$WORK_DIR/pushplus_notifier.sh"
CRON_LOG="$WORK_DIR/pushplus_notifier_cron.log"
LAST_NOTIFICATION_FILE="$WORK_DIR/last_notification_status.txt"

# ============================================
# 文件迁移
# ============================================
migrate_files() {
    if [ -f "/root/pushplus_notifier_config.txt" ]; then mv "/root/pushplus_notifier_config.txt" "$CONFIG_FILE"; fi
    if [ -f "/root/traffic_monitor.log" ]; then mv "/root/traffic_monitor.log" "$LOG_FILE"; fi
    if [ -f "/root/pushplus_notifier.sh" ]; then mv "/root/pushplus_notifier.sh" "$SCRIPT_PATH"; fi
    if [ -f "/root/pushplus_notifier_cron.log" ]; then mv "/root/pushplus_notifier_cron.log" "$CRON_LOG"; fi

    if crontab -l | grep -q "/root/pushplus_notifier.sh"; then
        crontab -l | sed "s|/root/pushplus_notifier.sh|$SCRIPT_PATH|g" | crontab -
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') 文件已迁移至 $WORK_DIR" | tee -a "$CRON_LOG"
}
migrate_files
cd "$WORK_DIR" || exit 1

export TZ='Asia/Shanghai'

echo "----------------------------------------------" | tee -a "$CRON_LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S') : 启动 PushPlus 通知脚本 v9.7" | tee -a "$CRON_LOG"

# ============================================
# 防止重复运行
# ============================================
check_running() {
    if pidof -x "$(basename "$0")" -o $$ > /dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 已有实例运行，退出。" | tee -a "$CRON_LOG"
        exit 1
    fi
}

# ============================================
# 配置管理
# ============================================
read_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "配置文件不存在或为空。"
        return 1
    fi
    source "$CONFIG_FILE"
    if [ -z "$PUSHPLUS_TOKEN" ] || [ -z "$MACHINE_NAME" ] || [ -z "$DAILY_REPORT_TIME" ]; then
        echo "配置不完整。"
        return 1
    fi
    return 0
}

write_config() {
    cat > "$CONFIG_FILE" <<EOF
PUSHPLUS_TOKEN="$PUSHPLUS_TOKEN"
DAILY_REPORT_TIME="$DAILY_REPORT_TIME"
MACHINE_NAME="$MACHINE_NAME"
EXPIRE_DATE="$EXPIRE_DATE"
EOF
    echo "配置已保存到 $CONFIG_FILE"
}

initial_config() {
    echo "==== PushPlus 初始化配置 ===="
    read -p "请输入 PushPlus Token: " PUSHPLUS_TOKEN
    read -p "请输入机器名称: " MACHINE_NAME
    read -p "请输入每日报告时间 (HH:MM): " DAILY_REPORT_TIME
    read -p "请输入 VPS 到期日期 (YYYY.MM.DD): " EXPIRE_DATE
    write_config
}

# ============================================
# PushPlus 通知函数
# ============================================
pushplus_send() {
    local title="$1"
    local content="$2"
    local url="http://www.pushplus.plus/send"

    local payload=$(cat <<EOF
{
    "token": "$PUSHPLUS_TOKEN",
    "title": "$title",
    "content": "$content",
    "template": "html"
}
EOF
)
    local response
    response=$(curl -s -X POST "$url" -H "Content-Type: application/json" -d "$payload")
    if echo "$response" | grep -q '"code":200'; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ 推送成功 ($title)" | tee -a "$CRON_LOG"
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ❌ 推送失败 ($title) 响应: $response" | tee -a "$CRON_LOG"
        return 1
    fi
}

test_pushplus_notification() {
    pushplus_send "🔔 [${MACHINE_NAME}] 测试消息" \
        "这是一条测试消息，如果您收到此推送，说明 PushPlus 配置正常。"
}

# ============================================
# 每日报告
# ============================================
daily_report() {
    local raw_output
    raw_output=$(get_current_traffic)

    local datetime=$(echo "$raw_output" | grep -m1 "当前周期" | cut -d' ' -f1)
    local period=$(echo "$raw_output" | grep "当前周期" | sed 's/.*当前周期: //')
    local usage=$(echo "$raw_output" | grep "当前流量使用" | sed 's/.*当前流量使用: //;s/ GB//')

    [ -z "$datetime" ] && datetime=$(date '+%Y-%m-%d %H:%M:%S')
    [ -z "$period" ] && period="未知"
    [ -z "$usage" ] && usage="未知"

    local TLIMIT TTOL limit
    source "$WORK_DIR/trafficcop.sh" >/dev/null 2>&1
    read_config >/dev/null 2>&1
    TLIMIT="$TRAFFIC_LIMIT"; TTOL="$TRAFFIC_TOLERANCE"

    if [[ -n "$TLIMIT" && -n "$TTOL" ]]; then
        limit=$(echo "$TLIMIT - $TTOL" | bc 2>/dev/null || echo "未知")
        limit="${limit} GB"
    else
        limit="未知"
    fi

    # === 计算剩余天数 ===
    local today=$(date '+%Y-%m-%d')
    local expire_formatted=$(echo "$EXPIRE_DATE" | tr '.' '-')
    local expire_ts=$(date -d "$expire_formatted" +%s 2>/dev/null)
    local today_ts=$(date -d "$today" +%s)
    local diff_days=$(( (expire_ts - today_ts) / 86400 ))

    if (( diff_days < 0 )); then
        diff_days="已过期"
        diff_emoji="🔴"
    elif (( diff_days <= 30 )); then
        diff_emoji="🟡"
        diff_days="${diff_days}天 (即将到期)"
    else
        diff_emoji="🟢"
        diff_days="${diff_days}天"
    fi

    # === 拼接消息 ===
    local title="🌐 [${MACHINE_NAME}] 每日流量报告"
    local content="🖥️ VPS流量信息：<br>"
    content+="🕒推送日期：$(date '+%Y-%m-%d')<br>"
    content+="${diff_emoji}剩余天数：${diff_days}<br>"
    content+="📅当前周期: ${period}<br>"
    content+="⌛已用流量: ${usage} GB<br>"
    content+="📦流量套餐：${limit}"

    pushplus_send "$title" "$content"
}

# ============================================
# 获取当前流量信息
# ============================================
get_current_traffic() {
    if [ -f "$WORK_DIR/trafficcop.sh" ]; then
        source "$WORK_DIR/trafficcop.sh" >/dev/null 2>&1
    else
        echo "trafficcop.sh 不存在"
        return 1
    fi
    local current_usage=$(get_traffic_usage)
    local start_date=$(get_period_start_date)
    local end_date=$(get_period_end_date)
    local mode=$TRAFFIC_MODE

    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前周期: $start_date 到 $end_date"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 统计模式: $mode"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前流量使用: $current_usage GB"
}

# ============================================
# cron 定时任务
# ============================================
setup_cron() {
    local entry="* * * * * $SCRIPT_PATH -cron"
    crontab -l 2>/dev/null | grep -v "pushplus_notifier.sh" | { cat; echo "$entry"; } | crontab -
    echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ Crontab 已更新。" | tee -a "$CRON_LOG"
}

# ============================================
# 主入口
# ============================================
main() {
    check_running
    if [[ "$*" == *"-cron"* ]]; then
        if read_config; then
            current_time=$(date +%H:%M)
            if [ "$current_time" == "$DAILY_REPORT_TIME" ]; then
                daily_report
            fi
        fi
    else
        if ! read_config; then initial_config; fi
        setup_cron

        while true; do
            clear
            echo "===== PushPlus 菜单 ====="
            echo "1. 发送每日报告"
            echo "2. 发送测试消息"
            echo "3. 实时流量"
            echo "4. 修改配置"
            echo "0. 退出"
            read -p "请选择: " choice
            case $choice in
                1) daily_report ;;
                2) test_pushplus_notification ;;
                3) get_current_traffic ;;
                4) initial_config ;;
                0) exit 0 ;;
            esac
            read -p "按 Enter 返回菜单..."
        done
    fi
}

main "$@"
echo "----------------------------------------------" | tee -a "$CRON_LOG"
