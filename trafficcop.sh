#!/bin/bash
# 设置 PATH 确保 cron 环境能找到所有命令
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORK_DIR="/root/TrafficCop"
CONFIG_FILE="$WORK_DIR/traffic_config.txt"
LOG_FILE="$WORK_DIR/traffic.log"
SCRIPT_PATH="$WORK_DIR/traffic.sh"
LOCK_FILE="$WORK_DIR/traffic.lock"
OFFSET_FILE="$WORK_DIR/traffic_offset.dat"   # 新增：周期流量偏移基准文件
PERIOD_MARK_FILE="$WORK_DIR/period_mark.dat"

# 设置时区为上海（东八区）
export TZ='Asia/Shanghai'

echo "-----------------------------------------------------" | tee -a "$LOG_FILE"
echo "$(date '+%Y-%m-%d %H:%M:%S') 当前版本：1.0.85（修复周期不清零问题）" | tee -a "$LOG_FILE"

# 杀死其他实例
kill_other_instances() {
    local current_pid=$$
    for pid in $(pgrep -f "$(basename "$0")"); do
        if [ "$pid" != "$current_pid" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 终止其他实例 PID: $pid" | tee -a "$LOG_FILE"
            kill "$pid" 2>/dev/null
        fi
    done
}

# 文件迁移（兼容旧版本）
migrate_files() {
    mkdir -p "$WORK_DIR"
    for file in /root/traffic_monitor_config.txt /root/traffic_monitor.log /root/.traffic_monitor_packages_installed; do
        [ -f "$file" ] && mv "$file" "$WORK_DIR/"
    done
    if crontab -l 2>/dev/null | grep -q "/root/traffic_monitor.sh"; then
        (crontab -l 2>/dev/null | sed "s|/root/traffic_monitor.sh|$SCRIPT_PATH|g") | crontab -
    fi
}

# 安装必要软件包
check_and_install_packages() {
    local packages=("vnstat" "jq" "bc" "iproute2" "cron")
    for package in "${packages[@]}"; do
        dpkg -s "$package" >/dev/null 2>&1 || {
            apt-get update && apt-get install -y "$package"
        }
    done
    local main_interface=$(ip route | grep default | awk '{print $5}' | head -n1)
    echo "$(date '+%Y-%m-%d %H:%M:%S') 主要网络接口: ${main_interface:-未知}" | tee -a "$LOG_FILE"
}

# 读写配置
read_config() { [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" && return 0 || return 1; }
write_config() {
    cat > "$CONFIG_FILE" << EOF
TRAFFIC_MODE=$TRAFFIC_MODE
TRAFFIC_PERIOD=$TRAFFIC_PERIOD
TRAFFIC_LIMIT=$TRAFFIC_LIMIT
TRAFFIC_TOLERANCE=$TRAFFIC_TOLERANCE
PERIOD_START_DAY=${PERIOD_START_DAY:-1}
LIMIT_SPEED=${LIMIT_SPEED:-20}
MAIN_INTERFACE=$MAIN_INTERFACE
LIMIT_MODE=$LIMIT_MODE
EOF
}

# 获取主要接口（带手动选择）
get_main_interface() {
    local iface=$(ip route | grep default | awk '{print $5}' | head -n1)
    [ -z "$iface" ] && iface=$(ip link | grep 'state UP' | awk -F: '{print $2}' | head -n1 | xargs)
    while true; do
        read -p "检测到主要接口: ${iface:-无}，直接回车使用或输入新接口: " input
        input=${input:-$iface}
        ip link show "$input" >/dev/null 2>&1 && { echo "$input"; return; }
        echo "接口无效，请重新输入"
    done
}

# 初始配置
initial_config() {
    MAIN_INTERFACE=$(get_main_interface)
    while :; do
        echo "1. 出站  2. 进站  3. 总和  4. 出入较大者"
        read -p "选择流量统计模式 (1-4): " c
        case $c in 1) TRAFFIC_MODE=out; break;; 2) TRAFFIC_MODE=in; break;; 3) TRAFFIC_MODE=total; break;; 4) TRAFFIC_MODE=max; break;; esac
    done
    read -p "统计周期 (m/q/y，默认为m): " p; TRAFFIC_PERIOD=${p:-monthly}; TRAFFIC_PERIOD=$(echo "$TRAFFIC_PERIOD" | cut -c1)
    [ "$TRAFFIC_PERIOD" = "q" ] && TRAFFIC_PERIOD=quarterly
    [ "$TRAFFIC_PERIOD" = "y" ] && TRAFFIC_PERIOD=yearly
    [ "$TRAFFIC_PERIOD" != "quarterly" ] && [ "$TRAFFIC_PERIOD" != "yearly" ] && TRAFFIC_PERIOD=monthly
    read -p "周期起始日 (1-31，默认为1): " PERIOD_START_DAY; PERIOD_START_DAY=${PERIOD_START_DAY:-1}
    [[ ! $PERIOD_START_DAY =~ ^[1-9]$|^[12][0-9]$|^3[01]$ ]] && PERIOD_START_DAY=1
    while :; do read -p "流量限制 (GB): " TRAFFIC_LIMIT; [[ $TRAFFIC_LIMIT =~ ^[0-9]+(\.[0-9]*)?$ ]] && break; done
    while :; do read -p "容错范围 (GB): " TRAFFIC_TOLERANCE; [[ $TRAFFIC_TOLERANCE =~ ^[0-9]+(\.[0-9]*)?$ ]] && break; done
    while :; do
        echo "1. TC限速  2. 关机"
        read -p "限制模式 (1-2): " m
        case $m in
            1) LIMIT_MODE=tc; read -p "限速值 kbit/s (默认20): " LIMIT_SPEED; LIMIT_SPEED=${LIMIT_SPEED:-20}; break;;
            2) LIMIT_MODE=shutdown; break;;
        esac
    done
    write_config

 echo
    echo "================ 流量基准设置 ================"
    echo "你可以在这里手动设定“本周期已使用流量（GB）”，"
    echo "用于同步运营商面板 / 实际使用情况。"
    echo "如果不确定，直接回车，默认从 0 开始统计。"
    echo "=============================================="
    read -p "请输入当前本周期实际已使用流量(GB，默认0): " real_gb

    # 如果直接回车，就把 OFFSET_FILE 设为 0
    if [ -z "$real_gb" ]; then
        echo 0 > "$OFFSET_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 首次初始化 OFFSET_FILE，设置为 0（本周期从 0GB 开始统计）" | tee -a "$LOG_FILE"
        return
    fi

    # 校验输入是否为数字
    if ! [[ "$real_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "输入格式不正确，已按 0GB 处理。"
        echo 0 > "$OFFSET_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') OFFSET_FILE 设置为 0（用户输入无效）" | tee -a "$LOG_FILE"
        return
    fi

    # 读取当前 vnstat 累计字节数 raw_bytes
    local line raw_bytes rx tx
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>&1 || echo "")

    # vnstat 还没数据的情况
    if echo "$line" | grep -qi "Not enough data available yet"; then
        echo "vnstat 数据尚未准备好，无法根据当前累计流量反推 offset。"
        echo "已暂时将 OFFSET_FILE 设置为 0，本周期从 $real_gb GB 逻辑上会不精确。"
        echo 0 > "$OFFSET_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 无数据，OFFSET_FILE 强制设为 0" | tee -a "$LOG_FILE"
        return
    fi

    if [ -z "$line" ]; then
        echo "vnstat 输出为空，已将 OFFSET_FILE 设置为 0。"
        echo 0 > "$OFFSET_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 输出为空，OFFSET_FILE 强制设为 0" | tee -a "$LOG_FILE"
        return
    fi

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
            rx=$(echo "$line" | cut -d';' -f9)
            tx=$(echo "$line" | cut -d';' -f10)
            rx=${rx:-0}
            tx=${tx:-0}
            [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
            [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
            if [ "$rx" -gt "$tx" ] 2>/dev/null; then
                raw_bytes="$rx"
            else
                raw_bytes="$tx"
            fi
            ;;
    esac

    # 防止 raw_bytes 不是数字
    if ! [[ "$raw_bytes" =~ ^[0-9]+$ ]]; then
        echo "vnstat 返回的累计流量不是纯数字(raw_bytes=$raw_bytes)，OFFSET_FILE 将设为 0。"
        echo 0 > "$OFFSET_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') raw_bytes 异常，OFFSET_FILE 强制设为 0" | tee -a "$LOG_FILE"
        return
    fi

    # real_gb 转字节（用 1024^3，与 get_traffic_usage 保持一致）
    local real_bytes new_offset
    real_bytes=$(echo "$real_gb * 1024 * 1024 * 1024" | bc | cut -d'.' -f1)
    new_offset=$((raw_bytes - real_bytes))
    # 注：这里刻意允许 new_offset 为负数，用于“新机器补历史用量”
    # 例如 raw≈0.7GB、你填 60GB，则 offset≈-59GB，
    # 后续 real = raw - offset = raw + 59GB，正好从 60GB 起算
    echo "$new_offset" > "$OFFSET_FILE"

    echo "--------------------------------------"
    echo "当前累计流量 raw_bytes : $raw_bytes bytes"
    echo "你设定的本周期已用    : $real_gb GB"
    echo "计算得到新的 offset   : $new_offset"
    echo "已写入 $OFFSET_FILE"
    echo "--------------------------------------"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 首次配置时设置 OFFSET_FILE=$new_offset（对应本周期已用 $real_gb GB）" | tee -a "$LOG_FILE"
}

# 获取当前周期起始日期
get_period_start_date() {
    local y=$(date +%Y) m=$(date +%m) d=$(date +%d)
    case $TRAFFIC_PERIOD in
        monthly)
            if [ $d -lt $PERIOD_START_DAY ]; then
                date -d "$y-$m-$PERIOD_START_DAY -1 month" +%Y-%m-%d 2>/dev/null || date -d "$y-$(expr $m - 1)-$PERIOD_START_DAY" +%Y-%m-%d
            else
                date -d "$y-$m-$PERIOD_START_DAY" +%Y-%m-%d
            fi ;;
        quarterly)
            local qm=$(( ((m-1)/3*3 +1) ))
            qm=$(printf "%02d" $qm)
            if [ $d -lt $PERIOD_START_DAY ]; then
                date -d "$y-$qm-$PERIOD_START_DAY -3 months" +%Y-%m-%d
            else
                date -d "$y-$qm-$PERIOD_START_DAY" +%Y-%m-%d
            fi ;;
        yearly)
            if [ $d -lt $PERIOD_START_DAY ]; then
                date -d "$((y-1))-$PERIOD_START_DAY +1 year -1 day" +%Y-%m-%d
            else
                date -d "$y-01-$PERIOD_START_DAY" +%Y-%m-%d
            fi ;;
    esac
}

# 新周期开始时保存偏移基准并清除限制
save_offset_on_new_period() {
    local today period_start last_mark
    today=$(date +%Y-%m-%d)
    period_start=$(get_period_start_date)
    last_mark=$(cat "$PERIOD_MARK_FILE" 2>/dev/null || echo "")

    # 只要 period_start 变化，就认为进入新周期（只执行一次）
    if [ "$last_mark" != "$period_start" ]; then
        local total_bytes=0
        local line
        line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>&1 || echo "")

        if echo "$line" | grep -qi "Not enough data available yet"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 新周期检测到但 vnstat 数据尚未就绪，稍后再试（不会写入mark）" | tee -a "$LOG_FILE"
            return
        fi

        case $TRAFFIC_MODE in
            out)   total_bytes=$(echo "$line" | cut -d';' -f10) ;;
            in)    total_bytes=$(echo "$line" | cut -d';' -f9) ;;
            total) total_bytes=$(echo "$line" | cut -d';' -f11) ;;
            max)
                local rx tx
                rx=$(echo "$line" | cut -d';' -f9)
                tx=$(echo "$line" | cut -d';' -f10)
                rx=${rx:-0}; tx=${tx:-0}
                [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
                [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
                total_bytes=$((rx > tx ? rx : tx))
                ;;
        esac

        if ! [[ "$total_bytes" =~ ^[0-9]+$ ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 新周期基准异常(total_bytes=$total_bytes)，稍后再试（不会写入mark）" | tee -a "$LOG_FILE"
            return
        fi

        echo "$total_bytes" > "$OFFSET_FILE"
        echo "$period_start" > "$PERIOD_MARK_FILE"

        echo "$(date '+%Y-%m-%d %H:%M:%S') 进入新周期：period_start=$period_start，已更新基准并清除限速/关机" | tee -a "$LOG_FILE"
        tc qdisc del dev "$MAIN_INTERFACE" root 2>/dev/null
        shutdown -c 2>/dev/null
    fi
}


# 获取本周期真实使用流量（已减去偏移量）
get_traffic_usage() {
    local offset raw_bytes real_bytes line rx tx

    offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

    # 把 stderr 一起抓回来，方便判断错误信息
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>&1 || echo "")

    # 如果 vnstat 还没数据，输出提示并按 0 处理
    if echo "$line" | grep -qi "Not enough data available yet"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 数据尚未准备好，暂按 0 GB 处理（接口：$MAIN_INTERFACE）" | tee -a "$LOG_FILE"
        printf "0.000"
        return 0
    fi

    # 如果 line 为空，也按 0 处理
    if [ -z "$line" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 输出为空，暂按 0 GB 处理（接口：$MAIN_INTERFACE）" | tee -a "$LOG_FILE"
        printf "0.000"
        return 0
    fi

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
            rx=$(echo "$line" | cut -d';' -f9)
            tx=$(echo "$line" | cut -d';' -f10)
            rx=${rx:-0}
            tx=${tx:-0}
            # 如果不是数字就归零
            [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
            [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
            if [ "$rx" -gt "$tx" ] 2>/dev/null; then
                raw_bytes="$rx"
            else
                raw_bytes="$tx"
            fi
            ;;
    esac

    raw_bytes=${raw_bytes:-0}
    # 再做一次数字检查，防止 cut 出来的不是数字
    if ! [[ "$raw_bytes" =~ ^[0-9]+$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 数据异常(raw_bytes=$raw_bytes)，暂按 0 处理" | tee -a "$LOG_FILE"
        raw_bytes=0
    fi

    real_bytes=$((raw_bytes - offset))
    [ "$real_bytes" -lt 0 ] && real_bytes=0

    printf "%.3f" "$(echo "scale=6; $real_bytes/1024/1024/1024" | bc 2>/dev/null || echo 0)"
}


# 检查并执行限速/关机
check_and_limit_traffic() {
    local usage=$(get_traffic_usage)
    local threshold=$(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc)
    echo "$(date '+%Y-%m-%d %H:%M:%S') 本周期已用: $usage GB  阈值: $threshold GB" | tee -a "$LOG_FILE"
    if (( $(echo "$usage > $threshold" | bc -l) )); then
        if [ "$LIMIT_MODE" = "tc" ]; then
            tc qdisc add dev "$MAIN_INTERFACE" root tbf rate ${LIMIT_SPEED}kbit burst 32kbit latency 400ms 2>/dev/null || \
            tc qdisc change dev "$MAIN_INTERFACE" root tbf rate ${LIMIT_SPEED}kbit burst 32kbit latency 400ms
            echo "$(date '+%Y-%m-%d %H:%M:%S') 已限速至 ${LIMIT_SPEED}kbit" | tee -a "$LOG_FILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超限，60秒后关机" | tee -a "$LOG_FILE"
            shutdown -h +1 "流量超限自动关机"
        fi
    else
        tc qdisc del dev "$MAIN_INTERFACE" root 2>/dev/null
        shutdown -c 2>/dev/null
    fi
}

# 设置每分钟定时任务
setup_crontab() {
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --run"; echo "* * * * * $SCRIPT_PATH --run") | crontab -
}

# 主函数
main() {
    kill_other_instances
    migrate_files
    cd "$WORK_DIR" || exit 1
    exec 9>"$LOCK_FILE"
    flock -n 9 || { echo "脚本正在运行中" | tee -a "$LOG_FILE"; exit 1; }

    if [ "$1" = "--run" ]; then
        read_config && save_offset_on_new_period && check_and_limit_traffic
        exit 0
    fi

    check_and_install_packages
    if read_config; then
        echo "检测到已有配置，5秒内按任意键修改，否则保持"
        if read -t 5 -n 1; then
            initial_config
        fi
    else
        initial_config
    fi
    setup_crontab
    write_config
    save_offset_on_new_period   # 确保首次部署也正确初始化
    echo "$(date '+%Y-%m-%d %H:%M:%S') 配置完成，每分钟自动检查一次" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前本周期已用流量: $(get_traffic_usage) GB" | tee -a "$LOG_FILE"
}

main "$@"
echo "-----------------------------------------------------" | tee -a "$LOG_FILE"
