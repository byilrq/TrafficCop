#!/bin/bash
# ============================================
# BWH + Telegram 流量监控通知脚本
# 文件名：/root/TrafficCop/bwhpush.sh
# 基于：tg_push.sh（增加 KiwiVM API 读取搬瓦工面板流量）
# 版本：2026-01-14
#
# 支持两种流量来源：
#   1) vnstat（本机网卡口径，支持 offset 校准）
#   2) bwh_api（KiwiVM 面板口径，直接读取 data_counter）
#
# 依赖：curl / jq / bc / iproute2（vnstat 仅在 vnstat 模式需要）
# ============================================

export TZ='Asia/Shanghai'

WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"

CONFIG_FILE="$WORK_DIR/bwhpush_config.txt"
CRON_LOG="$WORK_DIR/bwhpush_cron.log"
SCRIPT_PATH="$WORK_DIR/bwhpush.sh"

TRAFFIC_CONFIG="$WORK_DIR/traffic_config.txt"
OFFSET_FILE="$WORK_DIR/traffic_offset.dat"

# KiwiVM API Endpoint（一般不需要改）
BWH_API_ENDPOINT_DEFAULT="https://api.64clouds.com/v1/getServiceInfo"

# 颜色
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"
PURPLE="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"; PLAIN="\033[0m"

cd "$WORK_DIR" || exit 1


# ============================================
# 日志裁剪：只保留最近 150 行
# ============================================
trim_cron_log() {
    local file="$CRON_LOG"
    local max_lines=150
    [[ -f "$file" ]] || return 0

    local cnt
    cnt=$(wc -l < "$file" 2>/dev/null || echo 0)

    if (( cnt > max_lines )); then
        tail -n "$max_lines" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

# ============================================
# 记录 cron 日志（并自动裁剪）
# ============================================
log_cron() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $*" | tee -a "$CRON_LOG" >/dev/null
    trim_cron_log
}

# ============================================
# 防止重复运行（pidof）
# ============================================
check_running() {
    if pidof -x "$(basename "$0")" -o $$ >/dev/null 2>&1; then
        log_cron "已有实例运行，退出。"
        exit 1
    fi
}

# ============================================
# 读取配置（bwhpush_config.txt）
# 必填：TG_BOT_TOKEN TG_CHAT_ID MACHINE_NAME DAILY_REPORT_TIME EXPIRE_DATE
# 可选：TRAFFIC_SOURCE(bwh_api/vnstat) BWH_VEID BWH_API_KEY BWH_API_ENDPOINT
# ============================================
read_config() {
    [ ! -s "$CONFIG_FILE" ] && return 1
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || return 1

    # 默认值
    TRAFFIC_SOURCE=${TRAFFIC_SOURCE:-vnstat}
    BWH_API_ENDPOINT=${BWH_API_ENDPOINT:-$BWH_API_ENDPOINT_DEFAULT}

    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" || -z "$MACHINE_NAME" || -z "$DAILY_REPORT_TIME" || -z "$EXPIRE_DATE" ]] && return 1

    # 若选择 bwh_api，则要求 VEID/API_KEY
    if [[ "$TRAFFIC_SOURCE" == "bwh_api" ]]; then
        [[ -z "$BWH_VEID" || -z "$BWH_API_KEY" ]] && return 1
    fi

    return 0
}

# ============================================
# 写入配置（bwhpush_config.txt）
# ============================================
write_config() {
    cat >"$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
MACHINE_NAME="$MACHINE_NAME"
DAILY_REPORT_TIME="$DAILY_REPORT_TIME"
EXPIRE_DATE="$EXPIRE_DATE"

# 流量来源：vnstat 或 bwh_api
TRAFFIC_SOURCE="$TRAFFIC_SOURCE"

# 搬瓦工 / KiwiVM API（仅 bwh_api 模式需要）
BWH_VEID="$BWH_VEID"
BWH_API_KEY="$BWH_API_KEY"
BWH_API_ENDPOINT="$BWH_API_ENDPOINT"
EOF
    log_cron "配置已保存到 $CONFIG_FILE"
}

# ============================================
# 读取 TrafficCop 配置（vnstat 模式使用）
# ============================================
read_traffic_config() {
    [ ! -s "$TRAFFIC_CONFIG" ] && return 1

    unset MAIN_INTERFACE TRAFFIC_MODE TRAFFIC_LIMIT TRAFFIC_TOLERANCE TRAFFIC_PERIOD PERIOD_START_DAY LIMIT_SPEED LIMIT_MODE
    # shellcheck disable=SC1090
    source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$TRAFFIC_CONFIG" | sed 's/\r$//') 2>/dev/null || return 1

    TRAFFIC_MODE=${TRAFFIC_MODE:-total}
    TRAFFIC_PERIOD=${TRAFFIC_PERIOD:-monthly}
    TRAFFIC_LIMIT=${TRAFFIC_LIMIT:-0}
    TRAFFIC_TOLERANCE=${TRAFFIC_TOLERANCE:-0}
    PERIOD_START_DAY=${PERIOD_START_DAY:-1}
    MAIN_INTERFACE=${MAIN_INTERFACE:-eth0}

    [[ -z "$MAIN_INTERFACE" || -z "$TRAFFIC_MODE" || -z "$TRAFFIC_LIMIT" || -z "$TRAFFIC_TOLERANCE" ]] && return 1
    ip link show "$MAIN_INTERFACE" >/dev/null 2>&1 || return 1

    return 0
}

# ============================================
# 获取当前周期开始日期（vnstat 模式展示用）
# ============================================
get_period_start_date() {
    local y m d
    y=$(date +%Y); m=$(date +%m); d=$(date +%d)
    PERIOD_START_DAY=${PERIOD_START_DAY:-1}

    case $TRAFFIC_PERIOD in
        monthly)
            if [ "$d" -lt "$PERIOD_START_DAY" ]; then
                date -d "$y-$m-$PERIOD_START_DAY -1 month" +%Y-%m-%d 2>/dev/null || date -d "$y-$m-$PERIOD_START_DAY" +%Y-%m-%d
            else
                date -d "$y-$m-$PERIOD_START_DAY" +%Y-%m-%d 2>/dev/null
            fi
            ;;
        quarterly)
            local qm
            qm=$(( ((10#$m-1)/3*3 +1) ))
            qm=$(printf "%02d" "$qm")
            if [ "$d" -lt "$PERIOD_START_DAY" ]; then
                date -d "$y-$qm-$PERIOD_START_DAY -3 months" +%Y-%m-%d 2>/dev/null || date -d "$y-$qm-$PERIOD_START_DAY" +%Y-%m-%d
            else
                date -d "$y-$qm-$PERIOD_START_DAY" +%Y-%m-%d 2>/dev/null
            fi
            ;;
        yearly)
            if [ "$d" -lt "$PERIOD_START_DAY" ]; then
                date -d "$((y-1))-01-$PERIOD_START_DAY" +%Y-%m-%d 2>/dev/null || date -d "$y-01-$PERIOD_START_DAY" +%Y-%m-%d
            else
                date -d "$y-01-$PERIOD_START_DAY" +%Y-%m-%d 2>/dev/null
            fi
            ;;
        *)
            date -d "$y-$m-${PERIOD_START_DAY:-1}" +%Y-%m-%d 2>/dev/null
            ;;
    esac
}

# ============================================
# 获取当前周期结束日期（vnstat 模式展示用）
# ============================================
get_period_end_date() {
    local start="$1"
    case "$TRAFFIC_PERIOD" in
        monthly)   date -d "$start +1 month -1 day" +%Y-%m-%d 2>/dev/null ;;
        quarterly) date -d "$start +3 month -1 day" +%Y-%m-%d 2>/dev/null ;;
        yearly)    date -d "$start +1 year -1 day" +%Y-%m-%d 2>/dev/null ;;
        *)         date -d "$start +1 month -1 day" +%Y-%m-%d 2>/dev/null ;;
    esac
}

# ============================================
# vnstat：本周期已用流量（GiB，3 位小数）
# usage = raw_all_time - offset
# ============================================
get_traffic_usage_vnstat() {
    local offset raw=0 line rx tx real

    offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
    [[ "$offset" =~ ^-?[0-9]+$ ]] || offset=0

    vnstat -u -i "$MAIN_INTERFACE" >/dev/null 2>&1
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>/dev/null || echo "")
    [ -z "$line" ] && { printf "0.000"; return 0; }
    echo "$line" | grep -q ';' || { printf "0.000"; return 0; }

    case $TRAFFIC_MODE in
        out)   raw=$(echo "$line" | cut -d';' -f14) ;;
        in)    raw=$(echo "$line" | cut -d';' -f13) ;;
        total) raw=$(echo "$line" | cut -d';' -f15) ;;
        max)
            rx=$(echo "$line" | cut -d';' -f13); tx=$(echo "$line" | cut -d';' -f14)
            rx=${rx:-0}; tx=${tx:-0}
            [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
            [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
            raw=$(( rx > tx ? rx : tx ))
            ;;
        *) raw=0 ;;
    esac

    raw=${raw:-0}
    [[ "$raw" =~ ^[0-9]+$ ]] || raw=0

    real=$((raw - offset))
    (( real < 0 )) && real=0

    printf "%.3f" "$(echo "scale=6; $real/1024/1024/1024" | bc 2>/dev/null || echo 0)"
}

# ============================================
# KiwiVM API：读取搬瓦工面板口径流量
# 输出（通过 echo 写到 stdout，供调用者解析）：
#   used_gib plan_gib next_reset_ts used_bytes plan_bytes
# 失败返回：非 0
# ============================================
get_bwh_info() {
    local json err used_bytes plan_bytes next_reset

    json=$(curl -fsS -G "$BWH_API_ENDPOINT" \
        --data-urlencode "veid=$BWH_VEID" \
        --data-urlencode "api_key=$BWH_API_KEY" 2>/dev/null) || return 1

    err=$(echo "$json" | jq -r '.error // 1' 2>/dev/null)
    [[ "$err" == "0" ]] || return 1

    used_bytes=$(echo "$json" | jq -r '.data_counter // empty' 2>/dev/null)
    plan_bytes=$(echo "$json" | jq -r '.plan_monthly_data // empty' 2>/dev/null)
    next_reset=$(echo "$json" | jq -r '.data_next_reset // empty' 2>/dev/null)

    [[ "$used_bytes" =~ ^[0-9]+$ ]] || return 1
    [[ "$plan_bytes" =~ ^[0-9]+$ ]] || plan_bytes=0
    [[ "$next_reset" =~ ^[0-9]+$ ]] || next_reset=0

    # GiB（1024^3）
    local used_gib plan_gib
    used_gib=$(awk "BEGIN{printf \"%.3f\", $used_bytes/1024/1024/1024}")
    plan_gib=$(awk "BEGIN{printf \"%.3f\", $plan_bytes/1024/1024/1024}")

    echo "$used_gib $plan_gib $next_reset $used_bytes $plan_bytes"
    return 0
}

# ============================================
# Telegram 发送消息
# ============================================
tg_send() {
    local text="$1"

    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${text}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_cron "Telegram 推送成功"
    else
        log_cron "Telegram 推送失败"
    fi
}

# ============================================
# 发送测试消息
# ============================================
test_telegram() {
    tg_send "🖥️ <b>[${MACHINE_NAME}]</b> 测试消息\n\n这是一条测试消息，如果您收到此推送，说明 Telegram 配置正常！"
}

# ============================================
# 发送每日报告（Telegram）
# ============================================
daily_report() {
    local usage start end limit today expire_ts today_ts diff_days remain_emoji
    local disk_used disk_total disk_pct disk_line msg

    today=$(date +%Y-%m-%d)

    # 到期剩余天数
    expire_ts=$(date -d "${EXPIRE_DATE//./-}" +%s 2>/dev/null)
    today_ts=$(date -d "$today" +%s 2>/dev/null)
    diff_days=$(( (expire_ts - today_ts) / 86400 ))

    remain_emoji="🟢"
    if (( diff_days <= 0 )); then
        remain_emoji="🏴‍☠️"; diff_days="已到期"
    elif (( diff_days <= 30 )); then
        remain_emoji="🔴"
    elif (( diff_days <= 60 )); then
        remain_emoji="🟡"
    fi

    # 硬盘使用情况（根分区 /）
    disk_used=$(df -hP / 2>/dev/null | awk 'NR==2{print $3}')
    disk_total=$(df -hP / 2>/dev/null | awk 'NR==2{print $2}')
    disk_pct=$(df -hP / 2>/dev/null | awk 'NR==2{print $5}')
    if [[ -n "$disk_used" && -n "$disk_total" && -n "$disk_pct" ]]; then
        disk_line="${disk_used}/${disk_total} (${disk_pct})"
    else
        disk_line="未知"
    fi

    if [[ "$TRAFFIC_SOURCE" == "bwh_api" ]]; then
        local info used_gib plan_gib next_reset
        info=$(get_bwh_info) || {
            log_cron "BWH API 读取失败：请检查 VEID/API_KEY/网络/Endpoint"
            return 1
        }
        used_gib=$(echo "$info" | awk '{print $1}')
        plan_gib=$(echo "$info" | awk '{print $2}')
        next_reset=$(echo "$info" | awk '{print $3}')

        usage="$used_gib"
        limit="${plan_gib} GiB"

        # 面板重置时间（若有）
        if [[ "$next_reset" =~ ^[0-9]+$ ]] && (( next_reset > 0 )); then
            end=$(date -d @"$next_reset" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            start="KiwiVM 口径（按重置周期）"
        else
            end="未知"
            start="KiwiVM 口径"
        fi

        msg="🎯 <b>[${MACHINE_NAME}]</b> 流量统计（KiwiVM API）

🕒日期：${today}
${remain_emoji}剩余：${diff_days}天
🔄周期：${start}
⏲重置：${end}
⌛已用：${usage} GiB
🌐套餐：${limit}
💾空间：${disk_line}"

        tg_send "$msg"
        return 0
    fi

    # vnstat 模式
    if ! read_traffic_config; then
        log_cron "未找到/无法读取 TrafficCop 配置（$TRAFFIC_CONFIG）"
        return 1
    fi

    usage=$(get_traffic_usage_vnstat)
    start=$(get_period_start_date)
    end=$(get_period_end_date "$start")
    limit="${TRAFFIC_LIMIT} GB"

    msg="🎯 <b>[${MACHINE_NAME}]</b> 流量统计（vnstat）

🕒日期：${today}
${remain_emoji}剩余：${diff_days}天
🔄周期：${start} 到 ${end}
⌛已用：${usage} GiB
🌐套餐：${limit}
💾空间：${disk_line}"

    tg_send "$msg"
}

# ============================================
# 终端打印实时流量
# ============================================
get_current_traffic() {
    if [[ "$TRAFFIC_SOURCE" == "bwh_api" ]]; then
        local info used_gib plan_gib next_reset
        info=$(get_bwh_info) || { echo "BWH API 读取失败：请检查 VEID/API_KEY"; return 1; }
        used_gib=$(echo "$info" | awk '{print $1}')
        plan_gib=$(echo "$info" | awk '{print $2}')
        next_reset=$(echo "$info" | awk '{print $3}')

        echo "========================================"
        echo "       实时流量信息（KiwiVM API）"
        echo "========================================"
        echo "机器名   : $MACHINE_NAME"
        echo "来源     : bwh_api"
        echo "已用     : ${used_gib} GiB"
        echo "套餐     : ${plan_gib} GiB"
        if [[ "$next_reset" =~ ^[0-9]+$ ]] && (( next_reset > 0 )); then
            echo "重置时间 : $(date -d @"$next_reset" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)"
        else
            echo "重置时间 : 未知"
        fi
        echo "========================================"
        return 0
    fi

    read_traffic_config || { echo "请先运行 trafficcop.sh 初始化（vnstat 模式需要）"; return 1; }
    local usage start
    usage=$(get_traffic_usage_vnstat)
    start=$(get_period_start_date)

    echo "========================================"
    echo "       实时流量信息（vnstat）"
    echo "========================================"
    echo "机器名   : $MACHINE_NAME"
    echo "接口     : $MAIN_INTERFACE"
    echo "模式     : $TRAFFIC_MODE"
    echo "周期     : ${start} 起（按 ${TRAFFIC_PERIOD} 统计）"
    echo "已用     : $usage GiB"
    echo "套餐     : $TRAFFIC_LIMIT GB（容错 $TRAFFIC_TOLERANCE GB）"
    echo "========================================"
}

# ============================================
# vnstat 模式：手动修正 offset（保持原逻辑）
# ============================================
flow_setting() {
    echo "（仅 vnstat 模式可用）请输入本周期实际已用流量（GiB）:"
    read -r real_gb
    [[ ! $real_gb =~ ^[0-9]+(\.[0-9]+)?$ ]] && { echo "输入无效"; return; }
    read_traffic_config || return

    vnstat -u -i "$MAIN_INTERFACE" >/dev/null 2>&1

    local line raw rx tx
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>/dev/null || echo "")
    [ -z "$line" ] && { echo "vnstat 无输出"; return; }
    echo "$line" | grep -q ';' || { echo "vnstat 输出无效：$line"; return; }

    case $TRAFFIC_MODE in
        out)   raw=$(echo "$line" | cut -d';' -f14) ;;
        in)    raw=$(echo "$line" | cut -d';' -f13) ;;
        total) raw=$(echo "$line" | cut -d';' -f15) ;;
        max)
            rx=$(echo "$line" | cut -d';' -f13)
            tx=$(echo "$line" | cut -d';' -f14)
            rx=${rx:-0}; tx=${tx:-0}
            [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
            [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
            raw=$(( rx > tx ? rx : tx ))
            ;;
        *) raw=0 ;;
    esac

    raw=${raw:-0}
    [[ "$raw" =~ ^[0-9]+$ ]] || raw=0

    local target_bytes
    target_bytes=$(echo "$real_gb * 1024*1024*1024" | bc 2>/dev/null | cut -d. -f1)
    target_bytes=${target_bytes:-0}
    [[ "$target_bytes" =~ ^[0-9]+$ ]] || target_bytes=0

    local new_offset=$((raw - target_bytes))
    echo "$new_offset" > "$OFFSET_FILE"
    echo "已修正 offset → $new_offset（当前显示 ≈${real_gb} GiB）"
}

# ============================================
# 配置向导（交互）：第 4 项扩展为“Telegram + 搬瓦工 API + 来源选择”
# ============================================
initial_config() {
    echo "======================================"
    echo "   修改 Telegram + 搬瓦工(KiwiVM)配置"
    echo "======================================"
    echo

    # 1) Telegram
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

    # 2) 流量来源选择
    echo
    echo "请选择流量来源："
    echo "1) vnstat（本机网卡口径，可做 offset 校准）"
    echo "2) bwh_api（KiwiVM 面板口径，推荐用于严格对齐面板）"
    echo "当前: ${TRAFFIC_SOURCE:-vnstat}"
    read -rp "选择 (1-2) [回车保持当前]: " src_choice
    if [[ -n "$src_choice" ]]; then
        case "$src_choice" in
            1) TRAFFIC_SOURCE="vnstat" ;;
            2) TRAFFIC_SOURCE="bwh_api" ;;
            *) echo "无效选择，保持当前：${TRAFFIC_SOURCE:-vnstat}" ;;
        esac
    else
        TRAFFIC_SOURCE=${TRAFFIC_SOURCE:-vnstat}
    fi

    # 3) KiwiVM API（仅 bwh_api 需要）
    BWH_API_ENDPOINT=${BWH_API_ENDPOINT:-$BWH_API_ENDPOINT_DEFAULT}

    if [[ "$TRAFFIC_SOURCE" == "bwh_api" ]]; then
        echo
        echo "===== 搬瓦工 / KiwiVM API 配置（bwh_api 模式必填）====="

        if [[ -n "$BWH_VEID" ]]; then
            echo "请输入 VEID [当前: $BWH_VEID]: "
        else
            echo "请输入 VEID: "
        fi
        read -r new_veid
        [[ -z "$new_veid" && -n "$BWH_VEID" ]] && new_veid="$BWH_VEID"
        while ! [[ "$new_veid" =~ ^[0-9]+$ ]]; do
            echo "VEID 必须为数字，请重新输入："
            read -r new_veid
        done

        if [[ -n "$BWH_API_KEY" ]]; then
            local kshow="${BWH_API_KEY:0:6}...${BWH_API_KEY: -4}"
            echo "请输入 API_KEY [当前: $kshow]（回车保持不变）: "
        else
            echo "请输入 API_KEY: "
        fi
        read -r new_key
        [[ -z "$new_key" && -n "$BWH_API_KEY" ]] && new_key="$BWH_API_KEY"
        while [ -z "$new_key" ]; do
            echo "API_KEY 不能为空，请重新输入："
            read -r new_key
        done

        echo "API Endpoint [当前: ${BWH_API_ENDPOINT}]（一般无需修改，回车保持）: "
        read -r new_ep
        [[ -z "$new_ep" ]] && new_ep="$BWH_API_ENDPOINT"

        # 写入临时变量并做一次测试
        BWH_VEID="$new_veid"
        BWH_API_KEY="$new_key"
        BWH_API_ENDPOINT="$new_ep"

        echo
        echo "正在测试 KiwiVM API..."
        if get_bwh_info >/dev/null 2>&1; then
            echo "API 测试成功。"
        else
            echo "API 测试失败：请检查 VEID/API_KEY 是否正确、网络是否可访问。"
            echo "你仍可保存配置，但 cron 推送会失败。"
        fi
    fi

    TG_BOT_TOKEN="$new_token"
    TG_CHAT_ID="$new_chat"
    MACHINE_NAME="$new_name"
    DAILY_REPORT_TIME="$new_time"
    EXPIRE_DATE="$new_expire"

    write_config
    echo "配置已更新成功！"
}

# ============================================
# 设置 cron：每分钟检查一次（到点才发日报）
# ============================================
setup_cron() {
    local entry="* * * * * $SCRIPT_PATH -cron"
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH -cron" ; echo "$entry") | crontab -
    log_cron "✅ Crontab 已更新：每分钟检查一次，按设定时间发送每日报告。"
}

# ============================================
# 停止服务：移除 cron
# ============================================
stop_service() {
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH -cron" | crontab -
    log_cron "定时任务已移除"
    exit 0
}

# ============================================
# 主入口
# ============================================
main() {
    check_running

    echo "----------------------------------------------" | tee -a "$CRON_LOG" >/dev/null
    log_cron "启动 BWH+Telegram 通知脚本"

    if [[ "$*" == *"-cron"* ]]; then
        if ! read_config; then
            log_cron "配置不完整，跳过 cron 执行。"
            exit 1
        fi

        local current_time
        current_time=$(date +%H:%M)
        log_cron "cron 模式，当前时间: $current_time，设定报告时间: $DAILY_REPORT_TIME"

        if [ "$current_time" = "$DAILY_REPORT_TIME" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') : 时间匹配，开始发送每日报告。" >"$CRON_LOG"
            daily_report
        else
            log_cron "时间未到每日报告点，不发送。"
        fi

        exit 0
    fi

    read_config || echo "首次运行请先选择 4 配置"
    setup_cron

    while true; do
        clear
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${PURPLE}   BWH + Telegram 流量通知管理菜单${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 发送${YELLOW}每日报告${PLAIN}"
        echo -e "${GREEN}2.${PLAIN} 发送${CYAN}测试消息${PLAIN}"
        echo -e "${GREEN}3.${PLAIN} 打印${YELLOW}实时流量${PLAIN}"
        echo -e "${GREEN}4.${PLAIN} 修改${PURPLE}配置（含搬瓦工 API）${PLAIN}"
        echo -e "${GREEN}5.${PLAIN} 修正${YELLOW}vnstat offset${PLAIN}（仅 vnstat 模式）"
        echo -e "${RED}6.${PLAIN} 移除定时任务${PLAIN}"
        echo -e "${WHITE}0.${PLAIN} 退出${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        read -rp "请选择操作 [0-6]: " choice
        echo
        case "$choice" in
            1) daily_report ;;
            2) test_telegram ;;
            3) get_current_traffic ;;
            4) initial_config ;;
            5)
                if [[ "${TRAFFIC_SOURCE:-vnstat}" == "vnstat" ]]; then
                    flow_setting
                else
                    echo "当前为 bwh_api 模式，不需要 offset 修正。"
                fi
                ;;
            6) stop_service ;;
            0) exit 0 ;;
            *) echo "无效选项，请重新输入" ;;
        esac
        read -rp "按 Enter 返回菜单..."
    done
}

main "$@"
