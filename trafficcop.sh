#!/bin/bash
# ============================================
# TrafficCop - 版本：1.0.86（仅记录配置/新周期/限速状态变化）
# ============================================

# 设置 PATH 确保 cron 环境能找到所有命令
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TZ='Asia/Shanghai'

WORK_DIR="/root/TrafficCop"
CONFIG_FILE="$WORK_DIR/traffic_config.txt"
LOG_FILE="$WORK_DIR/traffic.log"
LOCK_FILE="$WORK_DIR/traffic.lock"
OFFSET_FILE="$WORK_DIR/traffic_offset.dat"
PERIOD_MARK_FILE="$WORK_DIR/traffic_period.dat"
STATE_FILE="$WORK_DIR/limit_state.dat"

mkdir -p "$WORK_DIR"

# ============================================
# 日志横幅（仅交互/初始化时输出，避免 cron 每分钟刷屏）
# ============================================
log_banner() {
    echo "-----------------------------------------------------" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前版本：1.0.86（减少日志噪音，仅记录关键事件）" | tee -a "$LOG_FILE"
}

# ============================================
# 杀死其他实例（仅交互模式使用，cron 模式使用 flock 静默互斥）
# ============================================
kill_other_instances() {
    local current_pid=$$
    for pid in $(pgrep -f "$(basename "$0")"); do
        if [ "$pid" != "$current_pid" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 终止其他实例 PID: $pid" | tee -a "$LOG_FILE"
            kill "$pid" 2>/dev/null
        fi
    done
}

# ============================================
# 文件迁移（兼容旧版本脚本/文件名）
# ============================================
migrate_files() {
    mkdir -p "$WORK_DIR"
    for file in /root/traffic_monitor_config.txt /root/traffic_monitor.log /root/.traffic_monitor_packages_installed; do
        [ -f "$file" ] && mv "$file" "$WORK_DIR/"
    done
    if crontab -l 2>/dev/null | grep -q "/root/traffic_monitor.sh"; then
        (crontab -l 2>/dev/null | sed "s|/root/traffic_monitor.sh|/root/TrafficCop/trafficcop.sh|g") | crontab -
    fi
}

# ============================================
# 安装依赖（vnstat/jq/bc/iproute2/cron）
# ============================================
check_and_install_packages() {
    local packages=("vnstat" "jq" "bc" "iproute2" "cron")
    for package in "${packages[@]}"; do
        dpkg -s "$package" >/dev/null 2>&1 || {
            apt-get update && apt-get install -y "$package"
        }
    done
    local main_interface
    main_interface=$(ip route | grep default | awk '{print $5}' | head -n1)
    echo "$(date '+%Y-%m-%d %H:%M:%S') 主要网络接口: ${main_interface:-未知}" | tee -a "$LOG_FILE"
}

# ============================================
# 读取配置（仅解析 KEY=VALUE，避免中文/杂项导致 source 失败）
# ============================================
read_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置文件不存在：$CONFIG_FILE" | tee -a "$LOG_FILE"
        return 1
    fi

    unset TRAFFIC_MODE TRAFFIC_PERIOD TRAFFIC_LIMIT TRAFFIC_TOLERANCE PERIOD_START_DAY LIMIT_SPEED MAIN_INTERFACE LIMIT_MODE

    # shellcheck disable=SC1090
    source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$CONFIG_FILE" | sed 's/\r$//') 2>/dev/null || {
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置加载失败（可能包含非法行）：$CONFIG_FILE" | tee -a "$LOG_FILE"
        return 1
    }

    TRAFFIC_MODE=${TRAFFIC_MODE:-total}
    TRAFFIC_PERIOD=${TRAFFIC_PERIOD:-monthly}
    TRAFFIC_LIMIT=${TRAFFIC_LIMIT:-0}
    TRAFFIC_TOLERANCE=${TRAFFIC_TOLERANCE:-0}
    PERIOD_START_DAY=${PERIOD_START_DAY:-1}
    LIMIT_SPEED=${LIMIT_SPEED:-20}
    LIMIT_MODE=${LIMIT_MODE:-tc}

    # PERIOD_START_DAY 防呆：必须是 1-31
    if ! [[ "$PERIOD_START_DAY" =~ ^([1-9]|[12][0-9]|3[01])$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') PERIOD_START_DAY 非法($PERIOD_START_DAY)，强制设为 1" | tee -a "$LOG_FILE"
        PERIOD_START_DAY=1
    fi

    # 主接口兜底：配置没写就自动探测
    if [ -z "$MAIN_INTERFACE" ]; then
        MAIN_INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
        [ -z "$MAIN_INTERFACE" ] && MAIN_INTERFACE=$(ip link | awk -F': ' '/state UP/ {print $2; exit}')
    fi

    if [ -z "$MAIN_INTERFACE" ] || ! ip link show "$MAIN_INTERFACE" >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 主接口无效/不存在：MAIN_INTERFACE=$MAIN_INTERFACE（请检查配置）" | tee -a "$LOG_FILE"
        return 1
    fi

    # 注意：此处只在交互模式会打印（cron 模式不会调用 log_banner，但 read_config 仍可能输出错误）
    echo "$(date '+%Y-%m-%d %H:%M:%S') 已加载配置：MODE=$TRAFFIC_MODE PERIOD=$TRAFFIC_PERIOD START_DAY=$PERIOD_START_DAY IFACE=$MAIN_INTERFACE LIMIT=$TRAFFIC_LIMIT TOL=$TRAFFIC_TOLERANCE LIMIT_MODE=$LIMIT_MODE" | tee -a "$LOG_FILE"
    return 0
}

# ============================================
# 写入配置（保证配置文件只包含 KEY=VALUE）
# ============================================
write_config() {
    mkdir -p "$WORK_DIR"
    cat > "$CONFIG_FILE" <<EOF
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

# ============================================
# 获取主网卡（交互选择）
# ============================================
get_main_interface() {
    local iface
    iface=$(ip route | grep default | awk '{print $5}' | head -n1)
    [ -z "$iface" ] && iface=$(ip link | grep 'state UP' | awk -F: '{print $2}' | head -n1 | xargs)
    while true; do
        read -p "检测到主要接口: ${iface:-无}，直接回车使用或输入新接口: " input
        input=${input:-$iface}
        ip link show "$input" >/dev/null 2>&1 && { echo "$input"; return; }
        echo "接口无效，请重新输入"
    done
}

# ============================================
# 初始配置向导（交互设置模式/周期/限速/基准 offset）
# ============================================
initial_config() {
    MAIN_INTERFACE=$(get_main_interface)

    while :; do
        echo "1. 出站  2. 进站  3. 总和  4. 出入较大者"
        read -p "选择流量统计模式 (1-4): " c
        case $c in
            1) TRAFFIC_MODE=out; break ;;
            2) TRAFFIC_MODE=in; break ;;
            3) TRAFFIC_MODE=total; break ;;
            4) TRAFFIC_MODE=max; break ;;
        esac
    done

    read -p "统计周期 (m/q/y，默认为m): " p
    TRAFFIC_PERIOD=${p:-monthly}
    TRAFFIC_PERIOD=$(echo "$TRAFFIC_PERIOD" | cut -c1)
    [ "$TRAFFIC_PERIOD" = "q" ] && TRAFFIC_PERIOD=quarterly
    [ "$TRAFFIC_PERIOD" = "y" ] && TRAFFIC_PERIOD=yearly
    [ "$TRAFFIC_PERIOD" != "quarterly" ] && [ "$TRAFFIC_PERIOD" != "yearly" ] && TRAFFIC_PERIOD=monthly

    read -p "周期起始日 (1-31，默认为1): " PERIOD_START_DAY
    PERIOD_START_DAY=${PERIOD_START_DAY:-1}
    [[ ! $PERIOD_START_DAY =~ ^[1-9]$|^[12][0-9]$|^3[01]$ ]] && PERIOD_START_DAY=1

    while :; do
        read -p "流量限制 (GB): " TRAFFIC_LIMIT
        [[ $TRAFFIC_LIMIT =~ ^[0-9]+(\.[0-9]*)?$ ]] && break
    done

    while :; do
        read -p "容错范围 (GB): " TRAFFIC_TOLERANCE
        [[ $TRAFFIC_TOLERANCE =~ ^[0-9]+(\.[0-9]*)?$ ]] && break
    done

    while :; do
        echo "1. TC限速  2. 关机"
        read -p "限制模式 (1-2): " m
        case $m in
            1)
                LIMIT_MODE=tc
                read -p "限速值 kbit/s (默认20): " LIMIT_SPEED
                LIMIT_SPEED=${LIMIT_SPEED:-20}
                break
                ;;
            2)
                LIMIT_MODE=shutdown
                break
                ;;
        esac
    done

    write_config

    echo
    echo "================ 流量基准设置 ================"
    echo "你可以在这里手动设定“本周期已使用流量（GB）”，"
    echo "用于同步运营商面板 / 实际使用情况。"
    echo "如果不确定，直接回车，默认从 0 开始统计。"
    echo "=============================================="
    read -r -p "请输入当前本周期实际已使用流量(GB，默认0): " real_gb

    if [ -z "$real_gb" ]; then
        echo 0 > "$OFFSET_FILE" || { echo "写入 OFFSET_FILE 失败：$OFFSET_FILE"; return 1; }
        echo "$(date '+%Y-%m-%d %H:%M:%S') 首次初始化 OFFSET_FILE=0（本周期从 0GB 开始统计）" | tee -a "$LOG_FILE"
        return 0
    fi

    if ! [[ "$real_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "输入格式不正确，已按 0GB 处理。"
        echo 0 > "$OFFSET_FILE" || { echo "写入 OFFSET_FILE 失败：$OFFSET_FILE"; return 1; }
        echo "$(date '+%Y-%m-%d %H:%M:%S') OFFSET_FILE=0（用户输入无效）" | tee -a "$LOG_FILE"
        return 0
    fi

    local line raw_bytes rx tx real_bytes new_offset
    vnstat -u -i "$MAIN_INTERFACE" >/dev/null 2>&1
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>/dev/null || echo "")

    if [ -z "$line" ] || ! echo "$line" | grep -q ';'; then
        echo "vnstat 输出无效，已将 OFFSET_FILE 设置为 0。"
        echo 0 > "$OFFSET_FILE" || { echo "写入 OFFSET_FILE 失败：$OFFSET_FILE"; return 1; }
        echo "$(date '+%Y-%m-%d %H:%M:%S') 初始化：vnstat 输出无效，OFFSET_FILE=0" | tee -a "$LOG_FILE"
        return 0
    fi

    # all-time 字段：in=13 out=14 total=15
    raw_bytes=0
    case $TRAFFIC_MODE in
        out)   raw_bytes=$(echo "$line" | cut -d';' -f14) ;;
        in)    raw_bytes=$(echo "$line" | cut -d';' -f13) ;;
        total) raw_bytes=$(echo "$line" | cut -d';' -f15) ;;
        max)
            rx=$(echo "$line" | cut -d';' -f13)
            tx=$(echo "$line" | cut -d';' -f14)
            rx=${rx:-0}; tx=${tx:-0}
            [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
            [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
            raw_bytes=$((rx > tx ? rx : tx))
            ;;
        *) raw_bytes=$(echo "$line" | cut -d';' -f15) ;;
    esac

    raw_bytes=${raw_bytes:-0}
    if ! [[ "$raw_bytes" =~ ^[0-9]+$ ]]; then
        echo "vnstat 返回累计流量异常(raw_bytes=$raw_bytes)，OFFSET_FILE 将设为 0。"
        echo 0 > "$OFFSET_FILE" || { echo "写入 OFFSET_FILE 失败：$OFFSET_FILE"; return 1; }
        echo "$(date '+%Y-%m-%d %H:%M:%S') 初始化：raw_bytes 异常，OFFSET_FILE=0" | tee -a "$LOG_FILE"
        return 0
    fi

    real_bytes=$(echo "$real_gb * 1024 * 1024 * 1024" | bc | cut -d'.' -f1)
    new_offset=$((raw_bytes - real_bytes))

    echo "$new_offset" > "$OFFSET_FILE" || { echo "写入 OFFSET_FILE 失败：$OFFSET_FILE"; return 1; }
    echo "$(date '+%Y-%m-%d %H:%M:%S') 初始化：OFFSET_FILE=$new_offset（对应本周期已用 $real_gb GB）" | tee -a "$LOG_FILE"
    return 0
}

# ============================================
# 计算当前周期起始日（支持 monthly/quarterly/yearly，按 PERIOD_START_DAY）
# ============================================
get_period_start_date() {
    # 工具：返回某年某月的最后一天（数字）
    _last_day_of_month() {
        date -d "$1-$2-01 +1 month -1 day" +%d 2>/dev/null
    }

    local y m d
    y=$(date +%Y)
    m=$(date +%m)
    d=$(date +%d)

    local mm=$((10#$m))
    local dd=$((10#$d))

    local sd="$PERIOD_START_DAY"
    if ! [[ "$sd" =~ ^([1-9]|[12][0-9]|3[01])$ ]]; then
        sd=1
    fi

    case "$TRAFFIC_PERIOD" in
        monthly)
            if (( dd < sd )); then
                local py pm last_prev
                py=$(date -d "$y-$m-01 -1 day" +%Y)
                pm=$(date -d "$y-$m-01 -1 day" +%m)
                last_prev=$(_last_day_of_month "$py" "$pm")
                (( sd > 10#$last_prev )) && sd=$((10#$last_prev))
                date -d "$py-$pm-$(printf "%02d" "$sd")" +%Y-%m-%d
            else
                local last_cur
                last_cur=$(_last_day_of_month "$y" "$m")
                (( sd > 10#$last_cur )) && sd=$((10#$last_cur))
                date -d "$y-$m-$(printf "%02d" "$sd")" +%Y-%m-%d
            fi
            ;;
        quarterly)
            local qstart=$(( ( (mm-1)/3 )*3 + 1 ))
            local qs_month
            qs_month=$(printf "%02d" "$qstart")

            if (( mm == qstart && dd < sd )); then
                local qy qm last_qm
                qy=$(date -d "$y-$qs_month-01 -3 months" +%Y)
                qm=$(date -d "$y-$qs_month-01 -3 months" +%m)
                last_qm=$(_last_day_of_month "$qy" "$qm")
                (( sd > 10#$last_qm )) && sd=$((10#$last_qm))
                date -d "$qy-$qm-$(printf "%02d" "$sd")" +%Y-%m-%d
            else
                local last_qs
                last_qs=$(_last_day_of_month "$y" "$qs_month")
                (( sd > 10#$last_qs )) && sd=$((10#$last_qs))
                date -d "$y-$qs_month-$(printf "%02d" "$sd")" +%Y-%m-%d
            fi
            ;;
        yearly)
            if (( mm == 1 && dd < sd )); then
                date -d "$((y-1))-01-$(printf "%02d" "$sd")" +%Y-%m-%d
            else
                date -d "$y-01-$(printf "%02d" "$sd")" +%Y-%m-%d
            fi
            ;;
        *)
            date -d "$y-$m-$(printf "%02d" "$sd")" +%Y-%m-%d
            ;;
    esac
}

# ============================================
# 新周期检测：period_start 变化时更新 OFFSET 与 PERIOD_MARK，并清除限速
# ============================================
save_offset_on_new_period() {
    local period_start last_mark line total_bytes rx tx

    mkdir -p "$WORK_DIR"

    period_start=$(get_period_start_date)
    last_mark=$(cat "$PERIOD_MARK_FILE" 2>/dev/null || echo "")

    if [ "$last_mark" != "$period_start" ]; then
        vnstat -u -i "$MAIN_INTERFACE" >/dev/null 2>&1
        line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>/dev/null || echo "")

        if [ -z "$line" ] || ! echo "$line" | grep -q ';'; then
            # 不写 mark，稍后 cron 再试
            echo "$(date '+%Y-%m-%d %H:%M:%S') 新周期检测到但 vnstat 输出无效，稍后重试（不写入 mark）" | tee -a "$LOG_FILE"
            return 0
        fi

        total_bytes=0
        case $TRAFFIC_MODE in
            out)   total_bytes=$(echo "$line" | cut -d';' -f14) ;;
            in)    total_bytes=$(echo "$line" | cut -d';' -f13) ;;
            total) total_bytes=$(echo "$line" | cut -d';' -f15) ;;
            max)
                rx=$(echo "$line" | cut -d';' -f13)
                tx=$(echo "$line" | cut -d';' -f14)
                rx=${rx:-0}; tx=${tx:-0}
                [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
                [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
                total_bytes=$((rx > tx ? rx : tx))
                ;;
            *) total_bytes=$(echo "$line" | cut -d';' -f15) ;;
        esac

        total_bytes=${total_bytes:-0}
        if ! [[ "$total_bytes" =~ ^[0-9]+$ ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 新周期基准异常(total_bytes=$total_bytes)，稍后重试（不写入 mark）" | tee -a "$LOG_FILE"
            return 0
        fi

        echo "$total_bytes" > "$OFFSET_FILE"
        echo "$period_start" > "$PERIOD_MARK_FILE"

        echo "$(date '+%Y-%m-%d %H:%M:%S') 进入新周期：$last_mark -> $period_start，写入 OFFSET_FILE=$total_bytes，并清除限速/关机" | tee -a "$LOG_FILE"
        tc qdisc del dev "$MAIN_INTERFACE" root 2>/dev/null
        shutdown -c 2>/dev/null
        echo "normal" > "$STATE_FILE" 2>/dev/null || true
    fi
}

# ============================================
# 读取本周期用量（GB）：all-time(raw) - offset，输出 3 位小数
# ============================================
get_traffic_usage() {
    local offset raw_bytes real_bytes line rx tx

    offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
    [[ "$offset" =~ ^-?[0-9]+$ ]] || offset=0

    vnstat -u -i "$MAIN_INTERFACE" >/dev/null 2>&1
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>/dev/null || echo "")

    if [ -z "$line" ] || ! echo "$line" | grep -q ';'; then
        printf "0.000"
        return 0
    fi

    raw_bytes=0
    case $TRAFFIC_MODE in
        out)   raw_bytes=$(echo "$line" | cut -d';' -f14) ;;
        in)    raw_bytes=$(echo "$line" | cut -d';' -f13) ;;
        total) raw_bytes=$(echo "$line" | cut -d';' -f15) ;;
        max)
            rx=$(echo "$line" | cut -d';' -f13)
            tx=$(echo "$line" | cut -d';' -f14)
            rx=${rx:-0}; tx=${tx:-0}
            [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
            [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
            raw_bytes=$((rx > tx ? rx : tx))
            ;;
        *) raw_bytes=$(echo "$line" | cut -d';' -f15) ;;
    esac

    raw_bytes=${raw_bytes:-0}
    [[ "$raw_bytes" =~ ^[0-9]+$ ]] || raw_bytes=0

    real_bytes=$((raw_bytes - offset))
    [ "$real_bytes" -lt 0 ] && real_bytes=0

    printf "%.3f" "$(echo "scale=6; $real_bytes/1024/1024/1024" | bc 2>/dev/null || echo 0)"
}

# ============================================
# 超限处理：仅在状态变化时记录日志（limited <-> normal）
# ============================================
check_and_limit_traffic() {
    local usage threshold prev_state new_state

    usage=$(get_traffic_usage)
    threshold=$(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc 2>/dev/null || echo 0)

    prev_state=$(cat "$STATE_FILE" 2>/dev/null || echo "normal")
    new_state="$prev_state"

    if (( $(echo "$usage > $threshold" | bc -l 2>/dev/null || echo 0) )); then
        new_state="limited"
        if [ "$prev_state" != "limited" ]; then
            if [ "$LIMIT_MODE" = "tc" ]; then
                tc qdisc add dev "$MAIN_INTERFACE" root tbf rate ${LIMIT_SPEED}kbit burst 32kbit latency 400ms 2>/dev/null || \
                tc qdisc change dev "$MAIN_INTERFACE" root tbf rate ${LIMIT_SPEED}kbit burst 32kbit latency 400ms
                echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超限：已用 ${usage}GB > 阈值 ${threshold}GB，开始限速 ${LIMIT_SPEED}kbit" | tee -a "$LOG_FILE"
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超限：已用 ${usage}GB > 阈值 ${threshold}GB，60秒后关机" | tee -a "$LOG_FILE"
                shutdown -h +1 "流量超限自动关机"
            fi
        fi
    else
        new_state="normal"
        if [ "$prev_state" != "normal" ]; then
            tc qdisc del dev "$MAIN_INTERFACE" root 2>/dev/null
            shutdown -c 2>/dev/null
            echo "$(date '+%Y-%m-%d %H:%M:%S') 流量恢复：已用 ${usage}GB <= 阈值 ${threshold}GB，解除限速/取消关机" | tee -a "$LOG_FILE"
        fi
    fi

    echo "$new_state" > "$STATE_FILE" 2>/dev/null || true
}

# ============================================
# 设置 cron：每分钟执行一次本脚本 --run（自动获取真实路径）
# ============================================
setup_crontab() {
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "/root/TrafficCop/trafficcop.sh")"
    (crontab -l 2>/dev/null | grep -v " $self --run" | grep -v "/root/TrafficCop/traffic.sh --run" ; echo "* * * * * $self --run") | crontab -
}

# ============================================
# 主流程：--run 为 cron 模式（静默+互斥），否则交互配置模式
# ============================================
main() {
    cd "$WORK_DIR" || exit 1

    # cron 模式：不打印横线/版本，不互杀，只做互斥+核心逻辑
    if [ "$1" = "--run" ]; then
        exec 9>"$LOCK_FILE"
        flock -n 9 || exit 0

        read_config || exit 0
        save_offset_on_new_period
        check_and_limit_traffic
        exit 0
    fi

    # 交互模式：打印横幅/迁移/安装/配置
    log_banner
    kill_other_instances
    migrate_files
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
    save_offset_on_new_period

    echo "$(date '+%Y-%m-%d %H:%M:%S') 配置完成：已设置每分钟自动检查（cron）" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前本周期已用流量: $(get_traffic_usage) GB" | tee -a "$LOG_FILE"
}

main "$@"
