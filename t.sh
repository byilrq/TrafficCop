#!/bin/bash

# TrafficCop 管理器 - 交互式管理工具
# 版本 2.4
# 最后更新：2025-10-19 20:00

SCRIPT_VERSION="2.4"
LAST_UPDATE="2025-10-19 20:00"

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
    install_script "tg_notifier.sh"
    run_script "$WORK_DIR/tg_notifier.sh"
    echo -e "${GREEN}Telegram通知功能安装完成！${NC}"
    read -p "按回车键继续..."
}

# 安装PushPlus通知
install_pushplus_notifier() {
    echo -e "${CYAN}正在安装PushPlus通知功能...${NC}"
    
    # 检查pushplus_notifier.sh是否在仓库中，如果不在，使用本地的
    if curl -s --head "$REPO_URL/pushplus_notifier.sh" | grep "HTTP/2 200\|HTTP/1.1 200" > /dev/null; then
        install_script "pushplus_notifier.sh"
    else
        echo -e "${YELLOW}从仓库下载失败，使用本地文件...${NC}"
        # 复制当前目录下的pushplus_notifier.sh到工作目录
        if [ -f "pushplus_notifier.sh" ]; then
            cp "pushplus_notifier.sh" "$WORK_DIR/pushplus_notifier.sh"
            chmod +x "$WORK_DIR/pushplus_notifier.sh"
        else
            echo -e "${RED}本地pushplus_notifier.sh文件不存在！${NC}"
            read -p "按回车键继续..."
            return
        fi
    fi
    run_script "$WORK_DIR/pushplus_notifier.sh"
    echo -e "${GREEN}PushPlus通知功能安装完成！${NC}"
    read -p "按回车键继续..."
}

# 安装Server酱通知
install_serverchan_notifier() {
    echo -e "${CYAN}正在安装Server酱通知功能...${NC}"
    
    # 检查serverchan_notifier.sh是否在仓库中，如果不在，使用本地的
    if curl -s --head "$REPO_URL/serverchan_notifier.sh" | grep "HTTP/2 200\|HTTP/1.1 200" > /dev/null; then
        install_script "serverchan_notifier.sh"
    else
        echo -e "${YELLOW}从仓库下载失败，使用本地文件...${NC}"
        # 复制当前目录下的serverchan_notifier.sh到工作目录
        if [ -f "serverchan_notifier.sh" ]; then
            cp "serverchan_notifier.sh" "$WORK_DIR/serverchan_notifier.sh"
            chmod +x "$WORK_DIR/serverchan_notifier.sh"
        else
            echo -e "${RED}本地serverchan_notifier.sh文件不存在！${NC}"
            read -p "按回车键继续..."
            return
        fi
    fi
    run_script "$WORK_DIR/serverchan_notifier.sh"
    echo -e "${GREEN}Server酱通知功能安装完成！${NC}"
    read -p "按回车键继续..."
}


# 查看日志
view_logs() {
    echo -e "${CYAN}查看日志${NC}"
    echo "1) 流量监控日志"
    echo "2) Telegram通知日志"
    echo "3) PushPlus通知日志"
    echo "4) Server酱通知日志"
    echo "0) 返回主菜单"
    
    read -p "请选择要查看的日志 [0-5]: " log_choice
    
    case $log_choice in
        1)
            if [ -f "$WORK_DIR/traffic_monitor.log" ]; then
                tail -50 "$WORK_DIR/traffic_monitor.log"
            else
                echo -e "${RED}流量监控日志不存在${NC}"
            fi
            ;;
        2)
            if [ -f "$WORK_DIR/tg_notifier.log" ]; then
                tail -20 "$WORK_DIR/tg_notifier.log"
            else
                echo -e "${RED}Telegram通知日志不存在${NC}"
            fi
            ;;
        3)
            if [ -f "$WORK_DIR/pushplus_notifier.log" ]; then
                tail -20 "$WORK_DIR/pushplus_notifier.log"
            else
                echo -e "${RED}PushPlus通知日志不存在${NC}"
            fi
            ;;
        4)
            if [ -f "$WORK_DIR/serverchan_notifier.log" ]; then
                tail -20 "$WORK_DIR/serverchan_notifier.log"
            else
                echo -e "${RED}Server酱通知日志不存在${NC}"
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
    echo "4) Server酱通知配置"
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
            if [ -f "$WORK_DIR/serverchan_notifier_config.txt" ]; then
                cat "$WORK_DIR/serverchan_notifier_config.txt"
            else
                echo -e "${RED}Server酱通知配置不存在${NC}"
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
    
    local scripts=("trafficcop.sh" "tg_notifier.sh" "pushplus_notifier.sh" "serverchan_notifier.sh" 
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


# 读取当前总流量  Traffic_all 函数：读取当前流量并打印，用于测试统计和记录
Traffic_all() {
    if [ -f "$WORK_DIR/trafficcop.sh" ]; then
        # Source the trafficcop.sh to load required functions (suppress output to avoid running main logic)
        source "$WORK_DIR/trafficcop.sh" >/dev/null 2>&1
    else
        echo -e "${RED}流量监控脚本 (trafficcop.sh) 不存在，请先安装流量监控功能 (选项1)。${NC}"
        return 1
    fi

    if read_config; then # 加载配置（TRAFFIC_MODE, TRAFFIC_PERIOD 等）
        local current_usage=$(get_traffic_usage)
        local start_date=$(get_period_start_date)
        local end_date=$(get_period_end_date)
        echo "$(date '+%Y-%m-%d %H:%M:%S') 当前周期: $start_date 到 $end_date"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 统计模式: $TRAFFIC_MODE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 当前流量使用: $current_usage GB"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 测试记录: vnstat 数据库路径 /var/lib/vnstat/$MAIN_INTERFACE (检查文件修改时间以验证更新)"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置加载失败，无法读取流量"
    fi
}

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         TrafficCop 管理工具 v${SCRIPT_VERSION}        ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo -e "${PURPLE}====================================${NC}"
    echo -e "${CYAN}最后更新: ${LAST_UPDATE}${NC}"
    echo ""
    echo -e "${YELLOW}1) 安装/管理流量监控${NC}"
    echo -e "${YELLOW}2) 安装/管理Telegram通知${NC}"
    echo -e "${YELLOW}3) 安装/管理PushPlus通知${NC}"
    echo -e "${YELLOW}4) 安装/管理Server酱通知${NC}"
    echo -e "${YELLOW}5) 查看日志${NC}"
    echo -e "${YELLOW}6) 查看当前配置${NC}"
    echo -e "${GREEN}7) 停止所有服务${NC}"
    echo -e "${GREEN}8) 更新所有脚本到最新版本${NC}"
    echo -e "${YELLOW}9) 读取当前使用流量${NC}"   
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
        read -p "请选择操作 [0-12]: " choice
        
        case $choice in
            1)
                install_monitor
                ;;
            2)
                install_tg_notifier
                ;;
            3)
                install_pushplus_notifier
                ;;
            4)
                install_serverchan_notifier
                ;;
            5)
                view_logs
                ;;
            6)
                view_config
                ;;

            7)
                stop_all_services
                ;;
            8)
                update_all_scripts
                ;;
            9)
                Traffic_all
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
