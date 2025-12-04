#!/bin/bash
# ============================================
# Telegram 通知脚本 for TrafficCop
# 适配：trafficcop.sh v1.0.85+
# 文件路径建议：/root/TrafficCop/telegram.sh
# ============================================
export TZ='Asia/Shanghai'

# ----------------- 基本路径 -------------------
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"

# Telegram 配置
CONFIG_FILE="$WORK_DIR/telegram_config.txt"
CRON_LOG="$WORK_DIR/telegram_cron.log"
SCRIPT_PATH="$WORK_DIR/telegram.sh"

# TrafficCop 相关文件（保持与 trafficcop.sh 一致）
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
echo "$(date '+%Y-%m-%d %H:%M:%S') : 启动 Telegram 通知脚本 (TrafficCop 版)" | tee -a "$CRON_LOG"
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
# Telegram 配置管理
# ============================================
read_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "Telegram 配置文件不存在或为空。" | tee -a "$CRON_LOG"
        return 1
    fi
    source "$CONFIG_FILE"
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ] || [ -z "$MACHINE_NAME" ] || [ -z "$DAILY_REPORT_TIME" ] || [ -z "$EXPIRE_DATE" ]; then
        echo "Telegram 配置不完整。" | tee -a "$CRON_LOG"
        return 1
    fi
    return 0
}

write_config() {
    cat >"$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
DAILY_REPORT_TIME="$DAILY_REPORT_TIME"
MACHINE_NAME="$MACHINE_NAME"
EXPIRE_DATE="$EXPIRE_DATE"
EOF
    echo "配置已保存到 $CONFIG_FILE" | tee -a "$CRON_LOG"
}

# ============================================
# 读取 TrafficCop 配置（完全复用原逻辑）
# ============================================
read_traffic_config() {
    if [ ! -s "$TRAFFIC_CONFIG" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 找不到 TrafficCop 配置文件: $TRAFFIC_CONFIG" | tee -a "$CRON_LOG"
        return 1
    fi
    source "$TRAFFIC_CONFIG"
    if [ -z "$MAIN_INTERFACE" ] || [ -z "$TRAFFIC_MODE" ] || [ -z "$TRAFFIC_LIMIT" ] || [ -z "$TRAFFIC_TOLERANCE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : TrafficCop 配置不完整。" | tee -a "$CRON_LOG"
        return 1
    fi
    return 0
}

# ============================================
# 流量计算函数（完全保持原样）
# ============================================
get_period_start_date() { ……（原脚本中完全相同，这里省略以节省篇幅）…… }
get_traffic_usage()      { ……（原脚本中完全相同）…… }
get_period_end_date()    { ……（原脚本中完全相同）…… }

# ============================================
# Telegram 发送函数
# ============================================
tg_send() {
    local text="$1"
    local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    local payload
    payload=$(cat <<EOF
{
    "chat_id": "$TG_CHAT_ID",
    "text": "$text",
    "parse_mode": "HTML",
    "disable_web_page_preview": true
}
EOF
)
    local resp
    resp=$(curl -s -X POST "$url" -d "$payload")
    if echo "$resp" | grep -q '"ok":true'; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : Telegram 推送成功" | tee -a "$CRON_LOG"
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') : Telegram 推送失败: $resp" | tee -a "$CRON_LOG"
        return 1
    fi
}

test_telegram_notification() {
    tg_send "<b>${MACHINE_NAME}</b> 测试消息\n\n这是一条测试消息，如果您收到此消息，说明 Telegram Bot 配置正常。"
}

# ============================================
# 初始化 Telegram 配置（交互式）
# ============================================
initial_config() {
    echo "======================================"
    echo " 修改 Telegram Bot 配置"
    echo "======================================"
    echo
    # Bot Token
    if [ -n "$TG_BOT_TOKEN" ]; then
        local token_show="${TG_BOT_TOKEN:0:8}...${TG_BOT_TOKEN: -4}"
        echo "请输入 Bot Token [当前: $token_show]: "
    else
        echo "请输入 Bot Token（找 @BotFather 获取）: "
    fi
    read -r new_token
    [ -z "$new_token" ] && new_token="$TG_BOT_TOKEN"
    while [ -z "$new_token" ]; do
        echo "Token 不能为空，请重新输入:"
        read -r new_token
    done

    # Chat ID
    if [ -n "$TG_CHAT_ID" ]; then
        echo "请输入 Chat ID [当前: $TG_CHAT_ID]: "
    else
        echo "请输入 Chat ID（给 @userinfobot 发消息即可得到）: "
    fi
    read -r new_chat_id
    [ -z "$new_chat_id" ] && new_chat_id="$TG_CHAT_ID"
    while [ -z "$new_chat_id" ]; do
        echo "Chat ID 不能为空，请重新输入:"
        read -r new_chat_id
    done

    # 其余配置保持不变（机器名、每日报告时间、到期时间）
    echo "请输入机器名称 [当前: ${MACHINE_NAME:-未设置}]: "
    read -r new_machine_name
    [ -z "$new_machine_name" ] && new_machine_name="$MACHINE_NAME"
    while [ -z "$new_machine_name" ]; do read -r new_machine_name; done

    echo "请输入每日报告时间 [当前: ${DAILY_REPORT_TIME:-01:00}，格式 HH:MM]: "
    read -r new_time
    [ -z "$new_time" ] && new_time="$DAILY_REPORT_TIME"
    while ! [[ $new_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; do
        echo "格式错误，请重新输入 (HH:MM):"
        read -r new_time
    done

    echo "请输入 VPS 到期日期 [当前: ${EXPIRE_DATE:-未设置}，格式 YYYY.MM.DD]: "
    read -r new_expire
    [ -z "$new_expire" ] && new_expire="$EXPIRE_DATE"
    while ! [[ $new_expire =~ ^[0-9]{4}\.[0-1][0-9]\.[0-3][0-9]$ ]]; do
        echo "格式错误，请重新输入 (YYYY.MM.DD):"
        read -r new_expire
    done

    TG_BOT_TOKEN="$new_token"
    TG_CHAT_ID="$new_chat_id"
    MACHINE_NAME="$new_machine_name"
    DAILY_REPORT_TIME="$new_time"
    EXPIRE_DATE="$new_expire"
    write_config
    echo "Telegram 配置已更新成功！"
}

# ============================================
# 每日报告（5 行格式完全一致）
# ============================================
daily_report() {
    if ! read_traffic_config; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 无法读取 TrafficCop 配置，放弃发送每日报告。" | tee -a "$CRON_LOG"
        return 1
    fi

    local current_usage period_start period_end limit
    local today expire_formatted expire_ts today_ts diff_days diff_emoji

    current_usage=$(get_traffic_usage || echo "0.000")
    period_start=$(get_period_start_date || echo "未知")
    period_end=$(get_period_end_date "$period_start")

    if [[ -n "$TRAFFIC_LIMIT" && -n "$TRAFFIC_TOLERANCE" ]]; then
        limit=$(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc)" GB"
    else
        limit="未知"
    fi

    today=$(date '+%Y-%m-%d')
    expire_formatted=$(echo "$EXPIRE_DATE" | tr '.' '-')
    expire_ts=$(date -d "$expire_formatted 00:00:00" +%s 2>/dev/null)
    today_ts=$(date -d "$today 00:00:00" +%s 2>/dev/null)
    if [[ -z "$expire_ts" || -z "$today_ts" ]]; then
        diff_days="未知"; diff_emoji="⚫"
    else
        diff_days=$(( (expire_ts - today_ts) / 86400 ))
        if (( diff_days < 0 )); then
            diff_emoji="⚫"; diff_days="$((-diff_days))天前"
        elif (( diff_days <= 30 )); then
            diff_emoji="🔴"
        elif (( diff_days <= 60 )); then
            diff_emoji="🟡"
        else
            diff_emoji="🟢"
        fi
        diff_days="${diff_days}天"
    fi

    local content
    content="<b>${MACHINE_NAME}</b> 每日报告\n\n"
    content+="日期：${today}\n"
    content+="${diff_emoji}剩余：${diff_days}\n"
    content+="周期：${period_start} 到 ${period_end}\n"
    content+="已用：${current_usage} GB\n"
    content+="套餐：${limit}"

    tg_send "$content"
}

# ============================================
# 其余功能（实时流量、手动修正流量）保持不变
# ============================================
get_current_traffic() { ……（与原 pushplus.sh 完全相同）…… }
flow_setting()          { ……（与原 pushplus.sh 完全相同）…… }

# ============================================
# Crontab 管理
# ============================================
setup_cron() {
    local entry="* * * * * $SCRIPT_PATH -cron"
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH -cron" ; echo "$entry") | crontab -
    echo "$(date '+%Y-%m-%d %H:%M:%S') : Crontab 已更新（每分钟检查）" | tee -a "$CRON_LOG"
}

telegram_stop() {
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH -cron"; then
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH -cron" | crontab -
        echo "$(date '+%Y-%m-%d %H:%M:%S') : Crontab 已移除" | tee -a "$CRON_LOG"
    fi
    echo "Telegram 推送功能已停止" | tee -a "$CRON_LOG"
    exit 0
}

# ============================================
# 主入口
# ============================================
main() {
    check_running
    if [[ "$*" == *"-cron"* ]]; then
        # Cron 模式
        if ! read_config; then exit 1; fi
        local now=$(date +%H:%M)
        if [ "$now" = "$DAILY_REPORT_TIME" ]; then
            daily_report
        fi
    else
        # 交互模式
        if ! read_config; then
            echo "未检测到完整配置，进入初始化..."
            initial_config
        fi
        setup_cron
        while true; do
            clear
            echo -e "${BLUE}========== Telegram 管理菜单 ==========${PLAIN}"
            echo -e "${GREEN}1.${PLAIN} 发送每日报告"
            echo -e "${GREEN}2.${PLAIN} 发送测试消息"
            echo -e "${GREEN}3.${PLAIN} 查看实时流量"
            echo -e "${GREEN}4.${PLAIN} 修改配置"
            echo -e "${GREEN}5.${PLAIN} 手动修正已用流量"
            echo -e "${RED}6.${PLAIN} 停止运行（移除定时任务）"
            echo -e "${WHITE}0.${PLAIN} 退出"
            echo -e "${BLUE}======================================${PLAIN}"
            read -rp "请选择 [0-6]: " choice
            case "$choice" in
                1) daily_report ;;
                2) test_telegram_notification ;;
                3) get_current_traffic ;;
                4) initial_config ;;
                5) flow_setting ;;
                6) telegram_stop ;;
                0) exit 0 ;;
                *) echo "无效选项" ;;
            esac
            read -rp "按 Enter 继续..."
        done
    fi
}

main "$@"
