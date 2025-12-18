#!/bin/bash

# TrafficCop 管理器 - 交互式管理工具
# 版本 1.0
# 最后更新：2025-11.09


# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 基础目录
WORK_DIR="/root/TrafficCop"
REPO_URL="https://raw.githubusercontent.com/byilrq/TrafficCop/main"

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}此脚本必须以root权限运行${NC}"
        exit 1
    fi
}

# 创建工作目录
create_work_dir() {
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
}

# 下载脚本
install_script() {
    local script_name="$1"
    echo -e "${YELLOW}正在下载 $script_name...${NC}"
    curl -fsSL "$REPO_URL/$script_name" -o "$WORK_DIR/$script_name"
    chmod +x "$WORK_DIR/$script_name"
}

# 运行脚本
run_script() {
    local script_path="$1"
    bash "$script_path"
}

# 安装流量监控
install_monitor() {
    echo -e "${CYAN}正在安装流量监控功能...${NC}"
    install_script "trafficcop.sh"
    run_script "$WORK_DIR/trafficcop.sh"
    echo -e "${GREEN}流量监控功能安装完成！${NC}"
    read -p "按回车键继续..."
}

# 安装Telegram通知
install_tg_notifier() {
    echo -e "${CYAN}正在安装Telegram通知功能...${NC}"
    install_script "tg_push.sh"
    run_script "$WORK_DIR/tg_push.sh"
    echo -e "${GREEN}tg_push.sh执行完毕！！${NC}"
    read -p "按回车键继续..."
}

# 安装let监控通知  
install_let() {
    echo -e "${CYAN}功能暂未开发...${NC}"
    read -p "按回车键继续..."
}

# 安装PushPlus通知
install_pushplus() {

    echo -e "${CYAN}正在安装PushPlus通知功能...${NC}"
    install_script "pushplus.shh"
    run_script "$WORK_DIR/pushplus.sh"
    echo -e "${GREEN} pushplus.sh执行完毕！${NC}"
    read -p "按回车键继续..."
}


# 查看日志
view_logs() {
    echo -e "${CYAN}查看日志${NC}"
    echo "1) 流量监控日志"
    echo "2) Telegram通知日志"
    echo "3) PushPlus通知日志"
    echo "0) 返回主菜单"
    
    read -p "请选择要查看的日志 [0-5]: " log_choice
    
    case $log_choice in
        1)
            if [ -f "$WORK_DIR/traffic_monitor.log" ]; then
                echo -e "${YELLOW}====== 最近 50 条 流量监控日志 ======${NC}"
                tail -50 "$WORK_DIR/traffic_monitor.log"
            else
                echo -e "${RED}流量监控日志不存在${NC}"
                echo -e "（预期位置: $WORK_DIR/traffic.log）"
            fi
            ;;
        2)
            if [ -f "$WORK_DIR/tg_notifier_cron.log" ]; then
                echo -e "${YELLOW}====== 最近 20 条 Telegram 通知日志 ======${NC}"
                tail -20 "$WORK_DIR/tg_notifier_cron.log"
            else
                echo -e "${RED}Telegram通知日志不存在${NC}"
                echo -e "（预期位置: $WORK_DIR/tg_notifier_cron.log）"
            fi
            ;;
        3)
            if [ -f "$WORK_DIR/pushplus_notifier_cron.log" ]; then
                echo -e "${YELLOW}====== 最近 20 条 PushPlus 通知日志 ======${NC}"
                tail -20 "$WORK_DIR/pushplus_cron.log"
            else
                echo -e "${RED}PushPlus通知日志不存在${NC}"
                echo -e "（预期位置: $WORK_DIR/pushplus_cron.log）"
            fi
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效的选择${NC}"
            ;;
    esac
    
    read -p "按回车键继续..."
}


# 查看当前配置
view_config() {
    echo -e "${CYAN}查看当前配置${NC}"
    echo "1) 流量监控配置"
    echo "2) Telegram通知配置"
    echo "3) PushPlus通知配置"
    echo "4) cron任务配置"
    echo "0) 返回主菜单"
    
    read -p "请选择要查看的配置类型 [0-4]: " config_choice
    
    case $config_choice in
        1)
            if [ -f "$WORK_DIR/traffic_monitor_config.txt" ]; then
                cat "$WORK_DIR/traffic_monitor_config.txt"
            else
                echo -e "${RED}流量监控配置不存在${NC}"
            fi
            ;;
        2)
            if [ -f "$WORK_DIR/tg_notifier_config.txt" ]; then
                cat "$WORK_DIR/tg_notifier_config.txt"
            else
                echo -e "${RED}Telegram通知配置不存在${NC}"
            fi
            ;;
        3)
            if [ -f "$WORK_DIR/pushplus_notifier_config.txt" ]; then
                cat "$WORK_DIR/pushplus_notifier_config.txt"
            else
                echo -e "${RED}PushPlus通知配置不存在${NC}"
            fi
            ;;
        4)
            echo -e "${CYAN}当前 cron 任务列表${NC}"
            echo "--------------------------------------"
            # 检查当前用户 crontab
            if crontab -l >/dev/null 2>&1; then
                crontab -l | grep -E "TrafficCop|pushplus|tg_notifier|traffic_monitor" --color=always || echo "（未发现相关任务）"
            else
                echo -e "${RED}未找到当前用户的 crontab 任务${NC}"
            fi
            echo "--------------------------------------"
            echo ""
            echo "如需查看系统级任务，可执行："
            echo "  cat /etc/crontab"
            echo "  ls /etc/cron.d/"
            echo "  cat /var/spool/cron/root"
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效的选择${NC}"
            ;;
    esac
    
    read -p "按回车键继续..."
}


# 停止所有服务
stop_all_services() {
    echo -e "${CYAN}正在停止所有TrafficCop服务...${NC}"
    
    # 停止流量监控进程
    pkill -f "trafficcop.sh" 2>/dev/null
    pkill -f "traffic_monitor.sh" 2>/dev/null
    echo "✓ 流量监控进程已停止"
    
    # 移除cron任务
    crontab -l 2>/dev/null | grep -v "trafficcop.sh\|traffic_monitor.sh" | crontab - 2>/dev/null
    echo "✓ 定时任务已清理"
    
    # 清除TC规则
    local interface=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -n "$interface" ]; then
        tc qdisc del dev "$interface" root 2>/dev/null
        echo "✓ TC限速规则已清除"
    fi
    
    # 取消关机计划
    shutdown -c 2>/dev/null
    echo "✓ 关机计划已取消"
    
    echo -e "${GREEN}所有服务已停止！${NC}"
    read -p "按回车键继续..."
}

# 更新所有脚本
update_all_scripts() {
    echo -e "${CYAN}正在更新所有脚本到最新版本...${NC}"
    
    local scripts=("trafficcop.sh" "tg_push.sh" "pushplus.sh" "nodeseek.sh" 
)
    
    for script in "${scripts[@]}"; do
        if curl -fsSL "$REPO_URL/$script" -o "$WORK_DIR/$script.new" 2>/dev/null; then
            mv "$WORK_DIR/$script.new" "$WORK_DIR/$script"
            chmod +x "$WORK_DIR/$script"
            echo -e "${GREEN}✓ $script 已更新${NC}"
        else
            echo -e "${YELLOW}! $script 更新失败或不存在${NC}"
        fi
    done
    
    echo -e "${GREEN}脚本更新完成！${NC}"
    read -p "按回车键继续..."
}

# 读取当前总流量（不再 source trafficcop.sh，直接读配置+vnstat）
Traffic_all() {
    local config_file="$WORK_DIR/traffic_config.txt"
    local offset_file="$WORK_DIR/traffic_offset.dat"

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}找不到流量监控配置文件：$config_file${NC}"
        echo -e "请先运行一次 ${YELLOW}流量监控安装/配置（菜单 1）${NC}"
        return 1
    fi

    # 读取配置：TRAFFIC_MODE / TRAFFIC_PERIOD / PERIOD_START_DAY / MAIN_INTERFACE / 限制等
    # shellcheck disable=SC1090
    source "$config_file"

    # 读 OFFSET，如果没有就按 0
    local offset
    offset=$(cat "$offset_file" 2>/dev/null || echo 0)
    [[ -z "$offset" ]] && offset=0

    # 从 vnstat 取当前累计字节数
    local line raw_bytes rx tx
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>&1 || echo "")

    if echo "$line" | grep -qi "Not enough data available yet"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 数据尚未准备好（接口：$MAIN_INTERFACE），暂按 0GB 处理。"
        raw_bytes=0
    elif [ -z "$line" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 输出为空（接口：$MAIN_INTERFACE），暂按 0GB 处理。"
        raw_bytes=0
    else
        case "$TRAFFIC_MODE" in
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
            *)
                raw_bytes=0
                ;;
        esac
    fi

    [[ "$raw_bytes" =~ ^[0-9]+$ ]] || raw_bytes=0

    local real_bytes=$((raw_bytes - offset))
    [ "$real_bytes" -lt 0 ] && real_bytes=0

    local usage_gb
    usage_gb=$(echo "scale=3; $real_bytes/1024/1024/1024" | bc 2>/dev/null || echo 0)

    # 计算当前周期起始日期（简化版，与 trafficcop 的 get_period_start_date 逻辑一致）
    local y m d period_start
    y=$(date +%Y)
    m=$(date +%m)
    d=$(date +%d)
    PERIOD_START_DAY=${PERIOD_START_DAY:-1}

    case "$TRAFFIC_PERIOD" in
        monthly)
            if [ "$d" -lt "$PERIOD_START_DAY" ]; then
                period_start=$(date -d "$y-$m-$PERIOD_START_DAY -1 month" +%Y-%m-%d 2>/dev/null || \
                               date -d "$y-$(expr "$m" - 1)-$PERIOD_START_DAY" +%Y-%m-%d)
            else
                period_start=$(date -d "$y-$m-$PERIOD_START_DAY" +%Y-%m-%d)
            fi
            ;;
        quarterly)
            local mm qm
            mm=$((10#$m))
            qm=$(( ((mm-1)/3*3 +1) ))
            qm=$(printf "%02d" "$qm")
            if [ "$d" -lt "$PERIOD_START_DAY" ]; then
                period_start=$(date -d "$y-$qm-$PERIOD_START_DAY -3 months" +%Y-%m-%d)
            else
                period_start=$(date -d "$y-$qm-$PERIOD_START_DAY" +%Y-%m-%d)
            fi
            ;;
        yearly)
            if [ "$d" -lt "$PERIOD_START_DAY" ]; then
                period_start=$(date -d "$((y-1))-01-$PERIOD_START_DAY" +%Y-%m-%d)
            else
                period_start=$(date -d "$y-01-$PERIOD_START_DAY" +%Y-%m-%d)
            fi
            ;;
        *)
            period_start=$(date -d "$y-$m-${PERIOD_START_DAY:-1}" +%Y-%m-%d)
            ;;
    esac

    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前周期: ${period_start} 起（按 $TRAFFIC_PERIOD 统计）"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 统计模式: $TRAFFIC_MODE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前流量使用: $usage_gb GB"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 测试记录: vnstat 数据库路径 /var/lib/vnstat/$MAIN_INTERFACE (检查文件修改时间以验证更新)"
}



# ======================================================
# 安装 / 管理 nodeseek 监控通知
# ======================================================
install_nodeseek_moniter() {
    echo -e "${CYAN}正在安装 nodeseek 监控脚本...${NC}"

    local file="nodeseek.sh"
    local url="https://raw.githubusercontent.com/byilrq/TrafficCop/main/nodeseek.sh"
    local dest="$WORK_DIR/$file"

    echo -e "${BLUE}➡ 下载 nodeseek.sh ...${NC}"
    curl -fsSL "$url" -o "$dest"

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}❌ 下载失败，请检查网络或 GitHub 链接。${NC}"
        read -p "按回车继续..."
        return
    fi

    chmod +x "$dest"
    echo -e "${GREEN}✔ nodeseek.sh 安装完成${NC}"

    echo -e "${CYAN}➡ 运行 nodeseek 配置管理...${NC}"
    bash "$dest"

    echo -e "${GREEN}✔ nodeseek 监控功能已启动！${NC}"
    read -p "按回车继续..."
}
# ======================================================
# 手动设置已用流量（管理脚本版本）
# ======================================================
flow_setting() {
    echo "================ 手动修正本周期流量 ================"
    echo "用于在运行一段时间后，调整当前周期已用流量（比如对齐运营商面板）。"
    echo "注意：这里输入的是【本周期应当已经使用的总量】，不是要增加的差值。"
    echo "===================================================="
    echo
    echo "请输入当前本周期实际已使用流量(GB)："
    read -r real_gb

    # 输入校验
    if ! [[ "$real_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "输入无效，请输入数字，例如 30 或 12.5"
        return 1
    fi

    # 这些路径在“管理脚本”里自己定义，不再依赖 trafficcop.sh 的变量
    local config_file="$WORK_DIR/traffic_config.txt"
    local offset_file="$WORK_DIR/traffic_offset.dat"
    local log_file="$WORK_DIR/traffic.log"

    # 尝试从配置文件加载 MAIN_INTERFACE / TRAFFIC_MODE
    if { [ -z "$MAIN_INTERFACE" ] || [ -z "$TRAFFIC_MODE" ]; } && [ -f "$config_file" ]; then
        # shellcheck disable=SC1090
        source "$config_file"
    fi

    if [ -z "$MAIN_INTERFACE" ] || [ -z "$TRAFFIC_MODE" ]; then
        echo "错误：未能获取 MAIN_INTERFACE / TRAFFIC_MODE，请先在菜单[1]完成流量监控安装/配置。"
        return 1
    fi

    local line raw_bytes rx tx real_bytes new_offset
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>&1 || echo "")

    # 情况 A：vnstat 还没数据 -> 视为 VPS 首次创建，当前累计流量按 0 处理
    if echo "$line" | grep -qiE "Not enough data available yet|No data\. Timestamp of last update is same"; then
        echo "检测到 vnstat 尚无历史数据，视为首次创建 VPS。"
        echo "将当前累计流量按 0 bytes 处理，根据你输入的 ${real_gb} GB 写入补偿值（可能为负数）。"

        raw_bytes=0

        # real_gb 转换为字节（1024^3）
        real_bytes=$(echo "$real_gb * 1024 * 1024 * 1024" | bc | cut -d'.' -f1)

        # 初始累计为 0，则 offset = 0 - real_bytes（允许为负数）
        new_offset=$((raw_bytes - real_bytes))

        echo "$new_offset" > "$offset_file"

        echo "--------------------------------------"
        echo "当前累计流量 raw_bytes : $raw_bytes bytes (按 0 处理)"
        echo "设定本周期使用量       : $real_gb GB"
        echo "新的 offset            : $new_offset"
        echo "（后续统计：已用 = 当前累计 - offset，将从 ${real_gb}GB 附近开始往上增长）"
        echo "--------------------------------------"
        echo "$(date '+%Y-%m-%d %H:%M:%S') flow_setting：vnstat 无历史数据，按 raw_bytes=0 处理，设置 OFFSET_FILE=$new_offset（对应本周期已用 $real_gb GB）" | tee -a "$log_file"
        return 0
    fi

    # 情况 B：其它异常
    if [ -z "$line" ]; then
        echo "vnstat 输出为空，无法计算 raw_bytes。"
        echo "$(date '+%Y-%m-%d %H:%M:%S') flow_setting：vnstat 输出为空，放弃修改 OFFSET_FILE" | tee -a "$log_file"
        return 1
    fi

    # 如果没有 ';'，说明不是正常的 --oneline b 数据格式
    if ! echo "$line" | grep -q ';'; then
        echo "vnstat 输出不是有效的 oneline 数据：$line"
        echo "$(date '+%Y-%m-%d %H:%M:%S') flow_setting：vnstat oneline 非数据输出($line)，放弃修改 OFFSET_FILE" | tee -a "$log_file"
        return 1
    fi

    # 情况 C：vnstat 有正常数据，按模式取 raw_bytes
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
        *)
            raw_bytes=0
            ;;
    esac

    raw_bytes=${raw_bytes:-0}

    # 防止 raw_bytes 不是数字
    if ! [[ "$raw_bytes" =~ ^[0-9]+$ ]]; then
        echo "vnstat 返回的累计流量不是纯数字(raw_bytes=$raw_bytes)，无法安全计算 offset。"
        echo "$(date '+%Y-%m-%d %H:%M:%S') flow_setting：raw_bytes 异常($raw_bytes)，放弃修改 OFFSET_FILE" | tee -a "$log_file"
        return 1
    fi

    # real_gb 转换为字节（1024^3）
    real_bytes=$(echo "$real_gb * 1024 * 1024 * 1024" | bc | cut -d'.' -f1)

    # 得到新的 offset（允许为负数，用于补历史用量）
    new_offset=$((raw_bytes - real_bytes))

    echo "$new_offset" > "$offset_file"

    echo "--------------------------------------"
    echo "当前累计流量 raw_bytes : $raw_bytes bytes"
    echo "设定本周期使用量       : $real_gb GB"
    echo "新的 offset            : $new_offset"
    echo "（后续统计：已用 = 当前累计 - offset，将从 ${real_gb}GB 附近开始往上增长）"
    echo "--------------------------------------"
    echo "$(date '+%Y-%m-%d %H:%M:%S') flow_setting：手动设置 OFFSET_FILE=$new_offset（对应本周期已用 $real_gb GB）" | tee -a "$log_file"
}


# 显示主菜单
show_main_menu() {
    clear
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}        TrafficCop 管理工具              ${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${PURPLE}====================================${NC}"
    echo ""
    echo -e "${YELLOW}1) 安装/管理流量监控${NC}"
    echo -e "${YELLOW}2) 安装/管理Telegram通知${NC}"
    echo -e "${YELLOW}3) 安装/管理PushPlus通知${NC}"
    echo -e "${YELLOW}4) 安装/管理LET监控通知${NC}"  
    echo -e "${YELLOW}5) 安装/管理nodeseek监控通知${NC}"  
    echo -e "${YELLOW}6) 查看日志${NC}"
    echo -e "${YELLOW}7) 查看配置${NC}"
    echo -e "${YELLOW}8) 查看已用流量${NC}" 
    echo -e "${YELLOW}9) 设置已用流量${NC}" 
    echo -e "${RED}10) 停止所有服务${NC}"
    echo -e "${BLUE}11) 更新所有脚本${NC}"
    echo -e "${YELLOW}0) 退出${NC}"
    echo -e "${PURPLE}====================================${NC}"
    echo ""
}

# 主函数
main() {
    check_root
    create_work_dir
    
    while true; do
        show_main_menu
        read -p "请选择操作 [0-11]: " choice
        
        case $choice in
            1)
                install_monitor
                ;;
            2)
                install_tg_notifier
                ;;
            3)
                install_pushplus
                ;;
            4)
                install_let
                ;;      
            5)
                install_nodeseek_moniter
                ;;  
            6)
                view_logs
                ;;
            7)
                view_config
                ;;
            8)
                Traffic_all
                ;;    
            9)
                flow_setting
                ;;              
            10)
                stop_all_services
                ;;
            11)
                update_all_scripts
                ;;

            0)
                echo -e "${GREEN}感谢使用TrafficCop管理工具！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 启动主程序
main "$@"
