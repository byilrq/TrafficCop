#!/bin/bash
# 设置新的工作目录
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"
# 更新文件路径
CONFIG_FILE="$WORK_DIR/tg_notifier_config.txt"
LOG_FILE="$WORK_DIR/traffic_monitor.log"
SCRIPT_PATH="$WORK_DIR/tg_notifier.sh"
CRON_LOG="$WORK_DIR/tg_notifier_cron.log"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"
hui='\e[37m'
lan='\033[34m'
zi='\033[35m'

# 文件迁移函数
migrate_files() {
    # 迁移配置文件
    if [ -f "/root/tg_notifier_config.txt" ]; then
        mv "/root/tg_notifier_config.txt" "$CONFIG_FILE"
    fi
    # 迁移日志文件
    if [ -f "/root/traffic_monitor.log" ]; then
        mv "/root/traffic_monitor.log" "$LOG_FILE"
    fi
    # 迁移脚本文件
    if [ -f "/root/tg_notifier.sh" ]; then
        mv "/root/tg_notifier.sh" "$SCRIPT_PATH"
    fi
    # 迁移 cron 日志文件
    if [ -f "/root/tg_notifier_cron.log" ]; then
        mv "/root/tg_notifier_cron.log" "$CRON_LOG"
    fi
    # 更新 crontab 中的脚本路径
    if crontab -l | grep -q "/root/tg_notifier.sh"; then
        crontab -l | sed "s|/root/tg_notifier.sh|$SCRIPT_PATH|g" | crontab -
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') 文件已迁移到新的工作目录: $WORK_DIR" | tee -a "$CRON_LOG"
}
# 在脚本开始时调用迁移函数
migrate_files
# 切换到工作目录
cd "$WORK_DIR" || exit 1
# 设置时区为上海（东八区）
export TZ='Asia/Shanghai'
echo "----------------------------------------------"| tee -a "$CRON_LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S') : 版本号：9.6"
# 检查是否有同名的 crontab 正在执行:
check_running() {
    # 新增：添加日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 开始检查是否有其他实例运行" >> "$CRON_LOG"
    if pidof -x "$(basename "\$0")" -o $$ > /dev/null; then
        # 新增：添加日志
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 另一个脚本实例正在运行，退出脚本" >> "$CRON_LOG"
        echo "另一个脚本实例正在运行，退出脚本"
        exit 1
    fi
    # 新增：添加日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 没有其他实例运行，继续执行" >> "$CRON_LOG"
}
# 函数：获取非空输入
get_valid_input() {
    local prompt="${1:-"请输入："}"
    local input=""
    while true; do
        read -p "${prompt}" input
        if [[ -n "${input}" ]]; then
            echo "${input}"
            return
        else
            echo "输入不能为空，请重新输入。"
        fi
    done
}

# 读取配置
read_config() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo "配置文件不存在或为空，需要进行初始化配置。"
        return 1
    fi
    source "$CONFIG_FILE"
    if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] || [ -z "$MACHINE_NAME" ] || [ -z "$DAILY_REPORT_TIME" ] || [ -z "$EXPIRE_DATE" ]; then
        echo "配置文件不完整，需要重新进行配置。"
        return 1
    fi
    return 0
}
# 写入配置
write_config() {
    cat > "$CONFIG_FILE" << EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
DAILY_REPORT_TIME="$DAILY_REPORT_TIME"
MACHINE_NAME="$MACHINE_NAME"
EXPIRE_DATE="$EXPIRE_DATE"
EOF
    echo "配置已保存到 $CONFIG_FILE"
}

# 初始配置
initial_config() {
    echo "======================================"
    echo " 修改 Telegram 通知配置"
    echo "======================================"
    echo ""
    echo "提示：按 Enter 保留当前配置，输入新值则更新配置"
    echo ""
   
    local new_token new_chat_id new_machine_name new_daily_report_time
    # Bot Token
    if [ -n "$BOT_TOKEN" ]; then
        # 隐藏部分Token显示
        local token_display="${BOT_TOKEN:0:10}...${BOT_TOKEN: -4}"
        echo "请输入Telegram Bot Token [当前: $token_display]: "
    else
        echo "请输入Telegram Bot Token: "
    fi
    read -r new_token
    # 如果输入为空且有原配置，保留原配置
    if [[ -z "$new_token" ]] && [[ -n "$BOT_TOKEN" ]]; then
        new_token="$BOT_TOKEN"
        echo " → 保留原配置"
    fi
    # 如果还是空（首次配置），要求必须输入
    while [[ -z "$new_token" ]]; do
        echo "Bot Token 不能为空。请重新输入: "
        read -r new_token
    done
    # Chat ID
    if [ -n "$CHAT_ID" ]; then
        echo "请输入Telegram Chat ID [当前: $CHAT_ID]: "
    else
        echo "请输入Telegram Chat ID: "
    fi
    read -r new_chat_id
    if [[ -z "$new_chat_id" ]] && [[ -n "$CHAT_ID" ]]; then
        new_chat_id="$CHAT_ID"
        echo " → 保留原配置"
    fi
    while [[ -z "$new_chat_id" ]]; do
        echo "Chat ID 不能为空。请重新输入: "
        read -r new_chat_id
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
        echo "请输入每日报告时间 (时区已经固定为东八区，输入格式为 HH:MM，例如 01:00): "
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
    
    # 更新配置文件（使用引号防止空格等特殊字符问题）
    BOT_TOKEN="$new_token"
    CHAT_ID="$new_chat_id"
    MACHINE_NAME="$new_machine_name"
    DAILY_REPORT_TIME="$new_daily_report_time"
   
    write_config
   
    echo ""
    echo "======================================"
    echo "配置已更新成功！"
    echo "======================================"
    echo ""
    read_config
}

# 设置测试通知消息
test_telegram_notification() {
    local message="🔔 [${MACHINE_NAME}]这是一条测试消息。如果您收到这条消息，说明Telegram通知功能正常工作。"
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "text=${message}" \
        -d "disable_notification=true")
   
    if echo "$response" | grep -q '"ok":true'; then
        echo "✅ [${MACHINE_NAME}]测试消息已成功发送，请检查您的Telegram。"
    else
        echo "❌ [${MACHINE_NAME}]发送测试消息失败。请检查您的BOT_TOKEN和CHAT_ID设置。"
    fi
}
# 设置定时任务
setup_cron() {
    local correct_entry="* * * * * $SCRIPT_PATH -cron"
    local current_crontab=$(crontab -l 2>/dev/null)
    local tg_notifier_entries=$(echo "$current_crontab" | grep "tg_notifier.sh")
    local correct_entries_count=$(echo "$tg_notifier_entries" | grep -F "$correct_entry" | wc -l)
    if [ "$correct_entries_count" -eq 1 ]; then
        echo "正确的 crontab 项已存在且只有一个，无需修改。"
    else
        # 删除所有包含 tg_notifier.sh 的条目
        new_crontab=$(echo "$current_crontab" | grep -v "tg_notifier.sh")
       
        # 添加一个正确的条目
        new_crontab="${new_crontab}
$correct_entry"
        # 更新 crontab
        echo "$new_crontab" | crontab -
        echo "已更新 crontab。删除了所有旧的 tg_notifier.sh 条目，并添加了一个每分钟执行的条目。"
    fi
    # 显示当前的 crontab 内容
    echo "当前的 crontab 内容："
    crontab -l
}

# 更新cron任务中的时间（当修改每日报告时间时调用）
update_cron_time() {
    local new_time="$1"
    echo "正在更新cron任务时间为: $new_time"
   
    # 重新读取配置以获取最新时间
    read_config
   
    # 重新设置cron任务
    setup_cron
   
    echo "cron任务时间已更新"
}

# 每日报告
# ======================================
# 修改 Telegram 通知配置
# ======================================
initial_config() {
    echo "======================================"
    echo " 修改 Telegram 通知配置"
    echo "======================================"
    echo ""
    echo "提示：按 Enter 保留当前配置，输入新值则更新配置"
    echo ""

    local new_token new_chat_id new_machine_name new_daily_report_time new_expire_date

    # Bot Token
    if [ -n "$BOT_TOKEN" ]; then
        local token_display="${BOT_TOKEN:0:10}...${BOT_TOKEN: -4}"
        echo "请输入Telegram Bot Token [当前: $token_display]: "
    else
        echo "请输入Telegram Bot Token: "
    fi
    read -r new_token
    if [[ -z "$new_token" ]] && [[ -n "$BOT_TOKEN" ]]; then
        new_token="$BOT_TOKEN"
        echo " → 保留原配置"
    fi
    while [[ -z "$new_token" ]]; do
        echo "Bot Token 不能为空。请重新输入: "
        read -r new_token
    done

    # Chat ID
    if [ -n "$CHAT_ID" ]; then
        echo "请输入Telegram Chat ID [当前: $CHAT_ID]: "
    else
        echo "请输入Telegram Chat ID: "
    fi
    read -r new_chat_id
    if [[ -z "$new_chat_id" ]] && [[ -n "$CHAT_ID" ]]; then
        new_chat_id="$CHAT_ID"
        echo " → 保留原配置"
    fi
    while [[ -z "$new_chat_id" ]]; do
        echo "Chat ID 不能为空。请重新输入: "
        read -r new_chat_id
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

    # === 更新配置文件 ===
    BOT_TOKEN="$new_token"
    CHAT_ID="$new_chat_id"
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


# ======================================
# 每日报告推送程序（保留原逻辑 + 增加剩余天数）
# ======================================
daily_report() {
    # === 获取当前流量信息 ===
    local raw_output
    raw_output=$(get_current_traffic)

    local datetime=$(echo "$raw_output" | grep -m1 "当前周期" | cut -d' ' -f1)
    local period=$(echo "$raw_output" | grep "当前周期" | sed 's/.*当前周期: //')
    local usage=$(echo "$raw_output" | grep "当前流量使用" | sed 's/.*当前流量使用: //;s/ GB//')

    [ -z "$datetime" ] && datetime=$(date '+%Y-%m-%d %H:%M:%S')
    [ -z "$period" ] && period="未知"
    [ -z "$usage" ] && usage="未知"

    # === 获取限额信息 ===
    local TLIMIT TTOL limit
    eval "$(source "$WORK_DIR/trafficcop.sh" >/dev/null 2>&1; read_config >/dev/null 2>&1; \
        echo "TLIMIT=$TRAFFIC_LIMIT; TTOL=$TRAFFIC_TOLERANCE;")"
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



    # === 构建美化消息 ===
    local message="🖥️ [${MACHINE_NAME}] 每日报告%0A%0A"
    message+="🕒推送日期：$(date '+%Y-%m-%d')%0A"
    message+="${diff_emoji}剩余天数：${diff_days}%0A"
    message+="📅当前周期：${period}%0A"
    message+="⌛已用流量：${usage} GB%0A"
    message+="🌐流量套餐：${limit}"

    # === 推送 Telegram ===
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$message" >/dev/null
}





# 获取当前总流量（完全复用 Traffic_all 的结构）
get_current_traffic() {
    if [ -f "$WORK_DIR/trafficcop.sh" ]; then
        # 直接加载 trafficcop.sh，避免重复输出
        source "$WORK_DIR/trafficcop.sh" >/dev/null 2>&1
    else
        echo "流量监控脚本 (trafficcop.sh) 不存在，请先安装流量监控功能 (选项1)。"
        return 1
    fi

    if read_config; then
        local current_usage=$(get_traffic_usage)
        local start_date=$(get_period_start_date)
        local end_date=$(get_period_end_date)
        local mode=$TRAFFIC_MODE

        echo "$(date '+%Y-%m-%d %H:%M:%S') 当前周期: $start_date 到 $end_date"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 统计模式: $mode"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 当前流量使用: $current_usage GB"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 测试记录: vnstat 数据库路径 /var/lib/vnstat/$MAIN_INTERFACE (检查文件修改时间以验证更新)"

        # ✅ 只输出当前使用数值，供上层 daily_report 调用
        echo "$current_usage"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置加载失败，无法读取流量"
        return 1
    fi
}




# 实时查询并推送当前流量到TG
send_current_traffic() {
    local current_usage=$(get_current_traffic)
    if [ $? -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 获取流量失败，无法发送" | tee -a "$CRON_LOG"
        return 1
    fi
    local current_time=$(date '+%Y-%m-%d %H:%M:%S')
    local url="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
    local message="📊 [${MACHINE_NAME}] 当前流量使用 (${current_time}): ${current_usage} GB"
    local response=$(curl -s -X POST "$url" -d "chat_id=$CHAT_ID" -d "text=$message")
    if echo "$response" | grep -q '"ok":true'; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 当前流量发送成功" | tee -a "$CRON_LOG"
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 当前流量发送失败. 响应: $response" | tee -a "$CRON_LOG"
        return 1
    fi
}

#停止推送
tgpush_stop() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 开始停止 Telegram 推送功能。" | tee -a "$CRON_LOG"
    
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
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') : ✅ Telegram 推送功能已停止。" | tee -a "$CRON_LOG"
    exit 0
}

# 主任务
main() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 进入主任务" >> "$CRON_LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 参数数量: $#" >> "$CRON_LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 所有参数: $@" >> "$CRON_LOG"
   
    check_running
   
if [[ "$*" == *"-cron"* ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 检测到-cron参数, 进入cron模式" >> "$CRON_LOG"
    if read_config; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 成功读取配置文件" >> "$CRON_LOG"
       

# 检查是否需要发送每日报告
current_time=$(TZ='Asia/Shanghai' date +%H:%M)
echo "$(date '+%Y-%m-%d %H:%M:%S') : 当前时间: $current_time, 设定的报告时间: $DAILY_REPORT_TIME" >> "$CRON_LOG"

if [ "$current_time" == "$DAILY_REPORT_TIME" ]; then
    # === 新增逻辑：清空旧日志，保持每天新日志 ===
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 时间匹配，清空旧日志以生成新日报日志。" > "$CRON_LOG"

    echo "$(date '+%Y-%m-%d %H:%M:%S') : 时间匹配，准备发送每日报告" >> "$CRON_LOG"
    if daily_report; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 每日报告发送成功" >> "$CRON_LOG"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 每日报告发送失败" >> "$CRON_LOG"
    fi
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 当前时间与报告时间不匹配，不发送报告" >> "$CRON_LOG"
fi
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 配置文件不存在或不完整，跳过检查" >> "$CRON_LOG"
    exit 1
fi
else
    # 菜单模式 (替换原来的交互模式)
    if ! read_config; then
        echo "需要进行初始化配置。"
        initial_config
    fi

    setup_cron

# 显示菜单
while true; do
    clear
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE}        Telegram 通知脚本管理菜单${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${YELLOW}当前配置摘要：${PLAIN}"
    echo -e "  ${WHITE}机器名称:${PLAIN} ${GREEN}$MACHINE_NAME${PLAIN}"
    echo -e "  ${WHITE}每日报告时间:${PLAIN} ${GREEN}$DAILY_REPORT_TIME${PLAIN}"
    echo -e "  ${WHITE}Bot Token:${PLAIN} ${CYAN}${BOT_TOKEN:0:10}...${PLAIN}"
    echo -e "  ${WHITE}Chat ID:${PLAIN} ${CYAN}$CHAT_ID${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 手动发送${YELLOW}每日报告${PLAIN}"
    echo -e "${GREEN}2.${PLAIN} 发送${YELLOW}测试消息${PLAIN}"
    echo -e "${GREEN}3.${PLAIN} 重新${CYAN}加载配置${PLAIN}"
    echo -e "${GREEN}4.${PLAIN} 修改${PURPLE}配置参数${PLAIN}"
    echo -e "${GREEN}5.${PLAIN} 实时${YELLOW}查询并推送${PLAIN}${CYAN}当前流量${PLAIN}"
    echo -e "${GREEN}6.${PLAIN} 实时${YELLOW}查询${PLAIN}${CYAN}当前流量${PLAIN}"
    echo -e "${RED}7.${PLAIN} 停止推送"
    echo -e "${WHITE}0.${PLAIN} 退出"
    echo -e "${BLUE}======================================${PLAIN}"
    read -rp "请选择操作 [${YELLOW}0-7${PLAIN}]: " choice
    echo

    case "$choice" in
        0)
            echo "退出脚本。"
            exit 0
            ;;
        1)
            echo "正在发送每日报告..."
            daily_report
            ;;
        2)
            echo "正在发送测试消息..."
            test_telegram_notification
            ;;
        3)
            echo "正在重新加载配置..."
            read_config
            echo "配置已重新加载。"
            ;;
        4)
            echo "进入配置修改模式..."
            initial_config
            ;;
        5)
            echo "正在实时查询并推送当前流量..."
            send_current_traffic
            ;;
        6)
            echo "正在实时查询当前流量..."
            get_current_traffic
            ;;
        7)
            echo "正在停止tg推送..."
            tgpush_stop
            ;;
        *)
            echo "无效的选择，请输入 0-7"
            ;;
    esac

    if [[ "$choice" != "0" ]]; then
        echo
        read -rp "按 Enter 键继续..."
    fi
        done
    fi
}
# 执行主函数
main "$@"
echo "----------------------------------------------"| tee -a "$CRON_LOG"
