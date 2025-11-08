#!/bin/bash
# 设置新的工作目录
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"
# 更新文件路径
CONFIG_FILE="$WORK_DIR/tg_notifier_config.txt"
LOG_FILE="$WORK_DIR/traffic_monitor.log"
SCRIPT_PATH="$WORK_DIR/tg_notifier.sh"
CRON_LOG="$WORK_DIR/tg_notifier_cron.log"
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
    # 读取配置文件
    source "$CONFIG_FILE"
    # 检查必要的配置项是否都存在
    if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] || [ -z "$MACHINE_NAME" ] || [ -z "$DAILY_REPORT_TIME" ]; then
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
# ===============================
# 每日报告函数（安全版）
# - 所有 trafficcop.sh 操作均在独立子 shell 内执行
# - 防止父 shell 环境污染
# - 含空值与超时保护
# ===============================
daily_report() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 开始生成每日报告" | tee -a "$CRON_LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') : DAILY_REPORT_TIME=$DAILY_REPORT_TIME" | tee -a "$CRON_LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') : BOT_TOKEN=${BOT_TOKEN:0:5}... CHAT_ID=$CHAT_ID" | tee -a "$CRON_LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 日志文件路径: $LOG_FILE" | tee -a "$CRON_LOG"

    # ========= 获取当前流量 =========
    local current_usage
    current_usage=$(get_current_traffic)
    if [ $? -ne 0 ] || [ -z "$current_usage" ] || [ "$current_usage" = "未知" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 获取最新流量失败或为空，设置为 未知" | tee -a "$CRON_LOG"
        current_usage="未知"
    fi

    # ========= 在子 shell 读取限额配置 =========
    local tmp_limit_file
    tmp_limit_file=$(mktemp /tmp/tlimits_XXXXXX)
    bash -c "
        set -e
        source '$WORK_DIR/trafficcop.sh' >/dev/null 2>&1 || true
        if read_config >/dev/null 2>&1; then
            echo \"\$TRAFFIC_LIMIT|\$TRAFFIC_TOLERANCE|\$TRAFFIC_MODE|\$MAIN_INTERFACE\"
        fi
    " > "$tmp_limit_file" 2>/dev/null

    local limit="未知" limit_threshold="未知" TLIMIT="" TTOL=""
    if [ -s "$tmp_limit_file" ]; then
        IFS='|' read -r TLIMIT TTOL MODE IFACE < "$tmp_limit_file"
        rm -f "$tmp_limit_file"
        if [[ -n "$TLIMIT" && -n "$TTOL" ]]; then
            limit_threshold=$(echo "$TLIMIT - $TTOL" | bc 2>/dev/null || echo "0")
            limit="${limit_threshold} GB"
            echo "$(date '+%Y-%m-%d %H:%M:%S') : 限制流量: $limit (原始: $TLIMIT, 容差: $TTOL, 模式: $MODE, iface: $IFACE)" | tee -a "$CRON_LOG"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') : trafficcop.sh 返回空的限额数据" | tee -a "$CRON_LOG"
        fi
    else
        rm -f "$tmp_limit_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 无法读取限额配置 (trafficcop.sh 子 shell 失败)" | tee -a "$CRON_LOG"
    fi

    # ========= 构建并发送 Telegram 消息 =========
    local message="📊 [${MACHINE_NAME}]每日流量报告%0A%0A🖥️ 机器总流量：%0A当前使用：${current_usage} GB%0A流量限制：${limit}"

    echo "$(date '+%Y-%m-%d %H:%M:%S') : [调试] 发送到TG的消息内容:" | tee -a "$CRON_LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') : [调试] $message" | tee -a "$CRON_LOG"

    local url="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
    local response
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 尝试发送Telegram消息" | tee -a "$CRON_LOG"
    response=$(curl -s -X POST "$url" -d "chat_id=$CHAT_ID" -d "text=$message")

    if echo "$response" | grep -q '"ok":true'; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 每日报告发送成功" | tee -a "$CRON_LOG"
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 每日报告发送失败. 响应: $response" | tee -a "$CRON_LOG"
        return 1
    fi
}


# 获取当前总流量（返回纯数值，用于 daily_report）
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
            echo "======================================"
            echo " Telegram 通知脚本管理菜单"
            echo "======================================"
            echo "当前配置摘要："
            echo "机器名称: $MACHINE_NAME"
            echo "每日报告时间: $DAILY_REPORT_TIME"
            echo "Bot Token: ${BOT_TOKEN:0:10}..." # 只显示前10个字符
            echo "Chat ID: $CHAT_ID"
            echo "======================================"
            echo "1. 手动发送每日报告"
            echo "2. 发送测试消息"
            echo "3. 重新加载配置"
            echo "4. 修改配置"
            echo "5. 修改每日报告时间"
            echo "6. 实时查询并推送当前流量"
            echo "7. 实时查询当前流量"
            echo "0. 退出"
            echo "======================================"
            echo -n "请选择操作 [0-6]: "
           
            read choice
            echo
           
            case $choice in
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
                    echo "修改每日报告时间"
                    echo -n "请输入新的每日报告时间 (HH:MM): "
                    read -r new_time
                    if [[ $new_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                        # 直接使用命令行工具修改配置，避免交互环境问题
                        cp "$CONFIG_FILE" "$CONFIG_FILE.backup"
                        awk -v new_time="$new_time" '
                        /^DAILY_REPORT_TIME=/ { print "DAILY_REPORT_TIME=" new_time; next }
                        { print }
                        ' "$CONFIG_FILE.backup" > "$CONFIG_FILE"
                       
                        echo "每日报告时间已更新为 $new_time"
                        # 更新 cron 任务
                        update_cron_time "$new_time"
                    else
                        echo "无效的时间格式。请使用 HH:MM 格式 (如: 09:30)"
                    fi
                    ;;
                6)
                    echo "正在实时查询并推送当前流量..."
                    send_current_traffic
                    ;;
                7)
                    echo "正在实时查询并推送当前流量..."
                    get_current_traffic
                    ;;
            
                *)
                    echo "无效的选择，请输入 0-6"
                    ;;
            esac
           
            if [ "$choice" != "0" ]; then
                echo
                echo "按 Enter 键继续..."
                read
            fi
        done
    fi
}
# 执行主函数
main "$@"
echo "----------------------------------------------"| tee -a "$CRON_LOG"
