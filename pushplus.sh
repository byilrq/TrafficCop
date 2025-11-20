#!/bin/bash
# ============================================
# PushPlus 通知脚本 for TrafficCop
# 适配：trafficcop.sh v1.0.85
# 文件路径建议：/root/TrafficCop/pushplus.sh
# ============================================

export TZ='Asia/Shanghai'

# ----------------- 基本路径 -------------------
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"

# PushPlus 自身配置
CONFIG_FILE="$WORK_DIR/pushplus_config.txt"
CRON_LOG="$WORK_DIR/pushplus_cron.log"
SCRIPT_PATH="$WORK_DIR/pushplus.sh"

# TrafficCop 相关文件（与 trafficcop.sh 保持一致）
TRAFFIC_CONFIG="$WORK_DIR/traffic_config.txt"
OFFSET_FILE="$WORK_DIR/traffic_offset.dat"

# ----------------- 彩色输出 -------------------
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PURPLE="\033[35m"
CYAN="\033[36m"
WHITE="\033[37m"
PLAIN="\033[0m"

echo "----------------------------------------------" | tee -a "$CRON_LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S') : 启动 PushPlus 通知脚本 (TrafficCop 版)" | tee -a "$CRON_LOG"

cd "$WORK_DIR" || exit 1

# ============================================
# 防止重复运行
# ============================================
check_running() {
    if pidof -x "$(basename "$0")" -o $$ >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 已有实例运行，退出。" | tee -a "$CRON_LOG"
        exit 1
    fi
}

# ============================================
# PushPlus 配置管理
# ============================================
read_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "PushPlus 配置文件不存在或为空。" | tee -a "$CRON_LOG"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    if [ -z "$PUSHPLUS_TOKEN" ] || [ -z "$MACHINE_NAME" ] || [ -z "$DAILY_REPORT_TIME" ] || [ -z "$EXPIRE_DATE" ]; then
        echo "PushPlus 配置不完整。" | tee -a "$CRON_LOG"
        return 1
    fi
    return 0
}

write_config() {
    cat >"$CONFIG_FILE" <<EOF
PUSHPLUS_TOKEN="$PUSHPLUS_TOKEN"
DAILY_REPORT_TIME="$DAILY_REPORT_TIME"
MACHINE_NAME="$MACHINE_NAME"
EXPIRE_DATE="$EXPIRE_DATE"
EOF
    echo "配置已保存到 $CONFIG_FILE" | tee -a "$CRON_LOG"
}

# ============================================
# 读取 TrafficCop 配置
# ============================================
read_traffic_config() {
    if [ ! -s "$TRAFFIC_CONFIG" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ❌ 找不到 TrafficCop 配置文件: $TRAFFIC_CONFIG" | tee -a "$CRON_LOG"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$TRAFFIC_CONFIG"
    # 关键变量简单校验
    if [ -z "$MAIN_INTERFACE" ] || [ -z "$TRAFFIC_MODE" ] || [ -z "$TRAFFIC_LIMIT" ] || [ -z "$TRAFFIC_TOLERANCE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ❌ TrafficCop 配置不完整。" | tee -a "$CRON_LOG"
        return 1
    fi
    return 0
}

# ============================================
# 与 trafficcop.sh 保持一致的时间与流量计算
# ============================================
get_period_start_date() {
    local y m d
    y=$(date +%Y)
    m=$(date +%m)
    d=$(date +%d)

    case $TRAFFIC_PERIOD in
        monthly)
            if [ "$d" -lt "$PERIOD_START_DAY" ]; then
                date -d "$y-$m-$PERIOD_START_DAY -1 month" +%Y-%m-%d 2>/dev/null || \
                date -d "$y-$(expr "$m" - 1)-$PERIOD_START_DAY" +%Y-%m-%d
            else
                date -d "$y-$m-$PERIOD_START_DAY" +%Y-%m-%d
            fi
            ;;
        quarterly)
            local qm=$(( ((10#$m - 1)/3*3 + 1) ))
            qm=$(printf "%02d" "$qm")
            if [ "$d" -lt "$PERIOD_START_DAY" ]; then
                date -d "$y-$qm-$PERIOD_START_DAY -3 months" +%Y-%m-%d
            else
                date -d "$y-$qm-$PERIOD_START_DAY" +%Y-%m-%d
            fi
            ;;
        yearly)
            # 这里沿用你原来的逻辑（按起始日所在的年份/上一年计算）
            if [ "$d" -lt "$PERIOD_START_DAY" ]; then
                date -d "$((y-1))-01-$PERIOD_START_DAY" +%Y-%m-%d
            else
                date -d "$y-01-$PERIOD_START_DAY" +%Y-%m-%d
            fi
            ;;
        *)
            # 默认按月
            date -d "$y-$m-${PERIOD_START_DAY:-1}" +%Y-%m-%d
            ;;
    esac
}

get_traffic_usage() {
    local offset raw_bytes real_bytes line

    offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>/dev/null || echo "")

    raw_bytes=0
    case $TRAFFIC_MODE in
        out)
            raw_bytes=$(echo "$line" | cut -d';' -f10)
            ;;
        in)
            raw_bytes=$(echo "$line" | cut -d';' -f9)
            ;;
        total)
            raw_bytes=$(echo "$line" | cut -d';' -f11)
            ;;
        max)
            local rx tx
            rx=$(echo "$line" | cut -d';' -f9)
            tx=$(echo "$line" | cut -d';' -f10)
            rx=${rx:-0}
            tx=${tx:-0}
            if [ "$rx" -gt "$tx" ] 2>/dev/null; then
                raw_bytes="$rx"
            else
                raw_bytes="$tx"
            fi
            ;;
        *)
            raw_bytes=0
            ;;
    esac

    raw_bytes=${raw_bytes:-0}
    real_bytes=$((raw_bytes - offset))
    [ "$real_bytes" -lt 0 ] && real_bytes=0

    # 输出 GB，保留 3 位小数
    printf "%.3f" "$(echo "scale=6; $real_bytes/1024/1024/1024" | bc 2>/dev/null || echo 0)"
}

# ============================================
# PushPlus 发送函数
# ============================================
pushplus_send() {
    local title="$1"
    local content="$2"
    local url="http://www.pushplus.plus/send"

    local payload
    payload=$(cat <<EOF
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
# 初始化 PushPlus 配置（交互）
# ============================================
initial_config() {
    echo "======================================"
    echo "      修改 PushPlus 通知配置"
    echo "======================================"
    echo

    local new_token new_machine_name new_daily_report_time new_expire_date

    # Token
    if [ -n "$PUSHPLUS_TOKEN" ]; then
        local token_display="${PUSHPLUS_TOKEN:0:10}...${PUSHPLUS_TOKEN: -4}"
        echo "请输入 PushPlus Token [当前: $token_display]: "
    else
        echo "请输入 PushPlus Token: "
    fi
    read -r new_token
    if [[ -z "$new_token" && -n "$PUSHPLUS_TOKEN" ]]; then
        new_token="$PUSHPLUS_TOKEN"
        echo " → 保留原配置"
    fi
    while [[ -z "$new_token" ]]; do
        echo "PushPlus Token 不能为空，请重新输入:"
        read -r new_token
    done

    # 机器名
    if [ -n "$MACHINE_NAME" ]; then
        echo "请输入机器名称 [当前: $MACHINE_NAME]: "
    else
        echo "请输入机器名称: "
    fi
    read -r new_machine_name
    if [[ -z "$new_machine_name" && -n "$MACHINE_NAME" ]]; then
        new_machine_name="$MACHINE_NAME"
        echo " → 保留原配置"
    fi
    while [[ -z "$new_machine_name" ]]; do
        echo "机器名称不能为空，请重新输入:"
        read -r new_machine_name
    done

    # 每日报告时间
    if [ -n "$DAILY_REPORT_TIME" ]; then
        echo "请输入每日报告时间 [当前: $DAILY_REPORT_TIME，格式 HH:MM]: "
    else
        echo "请输入每日报告时间 (时区东八区，格式 HH:MM，例如 01:00): "
    fi
    read -r new_daily_report_time
    if [[ -z "$new_daily_report_time" && -n "$DAILY_REPORT_TIME" ]]; then
        new_daily_report_time="$DAILY_REPORT_TIME"
        echo " → 保留原配置"
    fi
    while [[ ! $new_daily_report_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; do
        echo "时间格式不正确，请重新输入 (HH:MM): "
        read -r new_daily_report_time
    done

    # VPS 到期时间
    if [ -n "$EXPIRE_DATE" ]; then
        echo "请输入 VPS 到期日期 [当前: $EXPIRE_DATE，格式 YYYY.MM.DD]: "
    else
        echo "请输入 VPS 到期日期 (例如 2026.10.20): "
    fi
    read -r new_expire_date
    if [[ -z "$new_expire_date" && -n "$EXPIRE_DATE" ]]; then
        new_expire_date="$EXPIRE_DATE"
        echo " → 保留原配置"
    fi
    while [[ ! $new_expire_date =~ ^[0-9]{4}\.[0-1][0-9]\.[0-3][0-9]$ ]]; do
        echo "日期格式不正确，请重新输入 (YYYY.MM.DD): "
        read -r new_expire_date
    done

    PUSHPLUS_TOKEN="$new_token"
    MACHINE_NAME="$new_machine_name"
    DAILY_REPORT_TIME="$new_daily_report_time"
    EXPIRE_DATE="$new_expire_date"
    write_config

    echo
    echo "======================================"
    echo "      PushPlus 配置已更新成功"
    echo "======================================"
    echo
}

# ============================================
# 每日报告
# ============================================
daily_report() {
    if ! read_traffic_config; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ❌ 无法读取 TrafficCop 配置，放弃发送每日报告。" | tee -a "$CRON_LOG"
        return 1
    fi

    local current_usage period_start traffic_mode_zh threshold

    current_usage=$(get_traffic_usage 2>/dev/null || echo "0.000")
    period_start=$(get_period_start_date 2>/dev/null || echo "未知")

    case "$TRAFFIC_MODE" in
        out)   traffic_mode_zh="仅出站" ;;
        in)    traffic_mode_zh="仅进站" ;;
        total) traffic_mode_zh="出+进总和" ;;
        max)   traffic_mode_zh="出/进较大者" ;;
        *)     traffic_mode_zh="未知" ;;
    esac

    threshold="未知"
    if [[ -n "$TRAFFIC_LIMIT" && -n "$TRAFFIC_TOLERANCE" ]]; then
        threshold=$(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc 2>/dev/null || echo "未知")
        threshold="${threshold} GB"
    fi

    # 计算 VPS 剩余天数
    local today expire_formatted expire_ts today_ts diff_days diff_emoji
    today=$(date '+%Y-%m-%d')
    expire_formatted=$(echo "$EXPIRE_DATE" | tr '.' '-')
    expire_ts=$(date -d "${expire_formatted} 00:00:00" +%s 2>/dev/null)
    today_ts=$(date -d "${today} 00:00:00" +%s 2>/dev/null)

    diff_emoji="🟢"
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

    local title content
    title="🖥️ [${MACHINE_NAME}] 每日流量报告"
    content=""
    content+="<font color='#4169E1'>🕒 日期：</font> $(date '+%Y-%m-%d %H:%M')<br>"
    content+="<font color='#DC143C'>${diff_emoji} VPS剩余：</font> ${diff_days}<br><br>"
    content+="<font color='#32CD32'>📅 本期起始：</font> ${period_start}<br>"
    content+="<font color='#32CD32'>🔄 统计模式：</font> ${traffic_mode_zh}<br>"
    content+="<font color='#FF8C00'>📊 本期已用：</font> <font size='5'><b>${current_usage} GB</b></font><br>"
    content+="<font color='#9932CC'>🌐 流量套餐：</font> ${threshold}<br>"
    content+="<font color='#696969'>🖧 接口：</font> ${MAIN_INTERFACE}<br>"
    content+="<font color='#696969'>⚙️ 限制方式：</font> ${LIMIT_MODE:-未知}"

    if pushplus_send "$title" "$content"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ 每日报告推送成功（已用 ${current_usage} GB）" | tee -a "$CRON_LOG"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ❌ 每日报告推送失败" | tee -a "$CRON_LOG"
    fi
}

# ============================================
# 打印实时流量信息（终端）
# ============================================
get_current_traffic() {
    if ! read_traffic_config; then
        echo "错误：无法读取 TrafficCop 配置，请先运行一次 trafficcop.sh 完成初始化。"
        return 1
    fi

    local current_usage start_date mode_upper
    current_usage=$(get_traffic_usage 2>/dev/null || echo "0.000")
    start_date=$(get_period_start_date 2>/dev/null || echo "未知")
    mode_upper=$(echo "$TRAFFIC_MODE" | tr '[:lower:]' '[:upper:]')

    echo "======================================="
    echo "          实时流量信息"
    echo "======================================="
    echo "机器名称     : $MACHINE_NAME"
    echo "统计接口     : $MAIN_INTERFACE"
    echo "统计模式     : $mode_upper"
    echo "当前周期     : $start_date 起"
    echo "本周期已用   : $current_usage GB"
    echo "流量限制     : $TRAFFIC_LIMIT GB"
    echo "容错范围     : $TRAFFIC_TOLERANCE GB"
    echo "阈值         : $(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc 2>/dev/null || echo "未知") GB"
    echo "限制方式     : $LIMIT_MODE"
    echo "======================================="
}

# ============================================
# 停止 PushPlus 功能
# ============================================
pushplus_stop() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 开始停止 PushPlus 推送功能。" | tee -a "$CRON_LOG"

    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH -cron"; then
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH -cron" | crontab -
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ Crontab 定时任务已移除。" | tee -a "$CRON_LOG"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') : ℹ️ 未发现相关 Crontab 条目。" | tee -a "$CRON_LOG"
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ PushPlus 推送功能已停止（如需重新启用请再次运行脚本）。" | tee -a "$CRON_LOG"
    exit 0
}

# ============================================
# cron 定时任务
# ============================================
setup_cron() {
    local entry="* * * * * $SCRIPT_PATH -cron"
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH -cron" | grep -v "pushplus_notifier.sh" ; echo "$entry") | crontab -
    echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ Crontab 已更新：每分钟检查一次，按设定时间发送每日报告。" | tee -a "$CRON_LOG"
}

# ============================================
# 主入口
# ============================================
main() {
    check_running

    if [[ "$*" == *"-cron"* ]]; then
        # Cron 模式：每分钟跑一次，只在指定时间发日报
        if ! read_config; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') : PushPlus 配置不完整，跳过 cron 执行。" | tee -a "$CRON_LOG"
            exit 1
        fi
        local current_time
        current_time=$(date +%H:%M)
        echo "$(date '+%Y-%m-%d %H:%M:%S') : cron 模式，当前时间: $current_time，设定报告时间: $DAILY_REPORT_TIME" | tee -a "$CRON_LOG"

        if [ "$current_time" = "$DAILY_REPORT_TIME" ]; then
            # 每天第一次命中时可以考虑清空日志
            echo "$(date '+%Y-%m-%d %H:%M:%S') : 时间匹配，开始发送每日报告。" >"$CRON_LOG"
            daily_report
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') : 时间未到每日报告点，不发送。" | tee -a "$CRON_LOG"
        fi
    else
        # 交互菜单模式
        if ! read_config; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') : 未检测到完整配置，将进行初始化。" | tee -a "$CRON_LOG"
            initial_config
        fi
        setup_cron

        while true; do
            clear
            echo -e "${BLUE}======================================${PLAIN}"
            echo -e "${PURPLE}           PushPlus 管理菜单${PLAIN}"
            echo -e "${BLUE}======================================${PLAIN}"
            echo -e "${GREEN}1.${PLAIN} 发送${YELLOW}每日报告${PLAIN}"
            echo -e "${GREEN}2.${PLAIN} 发送${CYAN}测试消息${PLAIN}"
            echo -e "${GREEN}3.${PLAIN} 打印${YELLOW}实时流量${PLAIN}"
            echo -e "${GREEN}4.${PLAIN} 修改${PURPLE}配置${PLAIN}"
            echo -e "${RED}5.${PLAIN} 停止运行（移除定时任务）${PLAIN}"
            echo -e "${WHITE}0.${PLAIN} 退出${PLAIN}"
            echo -e "${BLUE}======================================${PLAIN}"
            read -rp "请选择操作 [0-5]: " choice
            echo
            case "$choice" in
                1) daily_report ;;
                2) test_pushplus_notification ;;
                3) get_current_traffic ;;
                4) initial_config ;;
                5) pushplus_stop ;;
                0) exit 0 ;;
            esac
            read -rp "按 Enter 返回菜单..."
        done
    fi
}

main "$@"
