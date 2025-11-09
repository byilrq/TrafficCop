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
# ============================================
# PushPlus 初始化
# ============================================

initial_config() {
    echo "======================================"
    echo " 修改 PushPlus 通知配置"
    echo "======================================"
    echo ""
    echo "提示：按 Enter 保留当前配置，输入新值则更新配置"
    echo ""

    local new_token new_machine_name new_daily_report_time new_expire_date
    # PushPlus Token
    if [ -n "$PUSHPLUS_TOKEN" ]; then
        # 隐藏部分Token显示
        local token_display="${PUSHPLUS_TOKEN:0:10}...${PUSHPLUS_TOKEN: -4}"
        echo "请输入 PushPlus Token [当前: $token_display]: "
    else
        echo "请输入 PushPlus Token: "
    fi
    read -r new_token
    # 如果输入为空且有原配置，保留原配置
    if [[ -z "$new_token" ]] && [[ -n "$PUSHPLUS_TOKEN" ]]; then
        new_token="$PUSHPLUS_TOKEN"
        echo " → 保留原配置"
    fi
    # 如果还是空（首次配置），要求必须输入
    while [[ -z "$new_token" ]]; do
        echo "PushPlus Token 不能为空。请重新输入: "
        read -r new_token
    done
    # 机器名称
    if [ -n "$MACHINE_NAME" ]; then
        echo "请输入机器名称 [当前: $MACHINE_NAME]: "
    else
        echo "请输入机器名称: "
    fi
    read -r new_machine_name
    if [[ -z "$new_machine_name" ]] && [[ -n "$MACHINE_NAME" ]]; then
        new_machine_name="$MACHINE_NAME"
        echo " → 保留原配置"
    fi
    while [[ -z "$new_machine_name" ]]; do
        echo "机器名称不能为空。请重新输入: "
        read -r new_machine_name
    done
    # 每日报告时间
    if [ -n "$DAILY_REPORT_TIME" ]; then
        echo "请输入每日报告时间 [当前: $DAILY_REPORT_TIME，格式 HH:MM]: "
    else
        echo "请输入每日报告时间 (时区固定为东八区，输入格式为 HH:MM，例如 01:00): "
    fi
    read -r new_daily_report_time
    if [[ -z "$new_daily_report_time" ]] && [[ -n "$DAILY_REPORT_TIME" ]]; then
        new_daily_report_time="$DAILY_REPORT_TIME"
        echo " → 保留原配置"
    fi
    while [[ ! $new_daily_report_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; do
        echo "时间格式不正确。请重新输入 (HH:MM): "
        read -r new_daily_report_time
    done
    # VPS 到期时间
    if [ -n "$EXPIRE_DATE" ]; then
        echo "请输入 VPS 到期日期 [当前: $EXPIRE_DATE，格式 YYYY.MM.DD]: "
    else
        echo "请输入 VPS 到期日期 (格式: YYYY.MM.DD，例如 2026.10.20): "
    fi
    read -r new_expire_date
    if [[ -z "$new_expire_date" ]] && [[ -n "$EXPIRE_DATE" ]]; then
        new_expire_date="$EXPIRE_DATE"
        echo " → 保留原配置"
    fi
    while [[ ! $new_expire_date =~ ^[0-9]{4}\.[0-1][0-9]\.[0-3][0-9]$ ]]; do
        echo "日期格式不正确，请重新输入 (YYYY.MM.DD): "
        read -r new_expire_date
    done

    # 更新配置文件
    PUSHPLUS_TOKEN="$new_token"
    MACHINE_NAME="$new_machine_name"
    DAILY_REPORT_TIME="$new_daily_report_time"
    EXPIRE_DATE="$new_expire_date"
    write_config

    echo ""
    echo "======================================"
    echo "配置已更新成功！"
    echo "======================================"
    echo ""
    read_config
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

# === 计算到期剩余天数（增强版） ===
local today=$(date '+%Y-%m-%d')
local expire_formatted=$(echo "$EXPIRE_DATE" | tr '.' '-')
local expire_ts=$(date -d "${expire_formatted} 00:00:00" +%s 2>/dev/null)
local today_ts=$(date -d "${today} 00:00:00" +%s 2>/dev/null)
local diff_days diff_emoji

if [[ -z "$expire_ts" || -z "$today_ts" ]]; then
    diff_days="未知"
    diff_emoji="⚫"
else
    diff_days=$(( (expire_ts - today_ts) / 86400 ))
    if (( diff_days < 0 )); then
        diff_emoji="⚫"
        diff_days="$((-diff_days))天前（已过期）"
    elif (( diff_days <= 30 )); then
        diff_emoji="🔴"
        diff_days="${diff_days}天（即将到期，请尽快续费）"
    elif (( diff_days <= 60 )); then
        diff_emoji="🟡"
        diff_days="${diff_days}天（注意续费）"
    else
        diff_emoji="🟢"
        diff_days="${diff_days}天"
    fi
fi



    # === 拼接消息 ===
    local title="🖥️ [${MACHINE_NAME}] 每日报告"
    content+="🕒日期：$(date '+%Y-%m-%d')<br>"
    content+="${diff_emoji}剩余：${diff_days}<br>"
    content+="📅周期: ${period}<br>"
    content+="⌛已用: ${usage} GB<br>"
    content+="🌐套餐：${limit}"

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

pushplus_stop() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 开始停止 PushPlus 推送功能。" | tee -a "$CRON_LOG"
    
    # 移除 Crontab 定时任务
    if crontab -l | grep -q "$SCRIPT_PATH"; then
        crontab -l | grep -v "$SCRIPT_PATH" | crontab -
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ Crontab 定时任务已移除。" | tee -a "$CRON_LOG"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ℹ️ 无需移除 Crontab 任务（未找到相关条目）。" | tee -a "$CRON_LOG"
    fi
    
    # 可选：删除配置文件以防止进一步运行（如果需要完全禁用）
    # if [ -f "$CONFIG_FILE" ]; then
    #     rm -f "$CONFIG_FILE"
    #     echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ 配置文件已删除。" | tee -a "$CRON_LOG"
    # fi
    
    # 可选：删除日志文件（如果需要清理）
    # if [ -f "$CRON_LOG" ]; then
    #     rm -f "$CRON_LOG"
    #     echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ 日志文件已删除。" | tee -a "$CRON_LOG"
    # fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ PushPlus 推送功能已停止。" | tee -a "$CRON_LOG"
    exit 0
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
            echo "3. 打印实时流量"
            echo "4. 修改配置"
            echo "5. 停止运行"
            echo "0. 退出"
            read -p "请选择: " choice
            case $choice in
                1) daily_report ;;
                2) test_pushplus_notification ;;
                3) get_current_traffic ;;
                4) initial_config ;;
                5) pushplus_stop ;;
                0) exit 0 ;;
            esac
            read -p "按 Enter 返回菜单..."
        done
    fi
}

main "$@"
echo "----------------------------------------------" | tee -a "$CRON_LOG"
