#!/bin/bash
# ============================================
# Telegram Channel → PushPlus VPS监控脚本 v1.0
# 作者：by / 更新时间：2025-11-10
# ============================================

WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"

CONFIG_FILE="$WORK_DIR/vps_moniter_config.txt"
LOG_FILE="$WORK_DIR/vps_moniter.log"
CRON_LOG="$WORK_DIR/vps_moniter_cron.log"
SCRIPT_PATH="$WORK_DIR/vps_moniter.sh"

# ================== 彩色定义 ==================
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; PURPLE="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"; PLAIN="\033[0m"

export TZ='Asia/Shanghai'

# ============================================
# 读取配置
# ============================================
read_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "配置文件不存在或为空。"
        return 1
    fi
    source "$CONFIG_FILE"
    return 0
}

# ============================================
# 写入配置
# ============================================
write_config() {
    cat > "$CONFIG_FILE" <<EOF
PUSHPLUS_TOKEN="$PUSHPLUS_TOKEN"
TG_CHANNELS="$TG_CHANNELS"
KEYWORDS="$KEYWORDS"
CHECK_INTERVAL="$CHECK_INTERVAL"
EOF
    echo "配置已保存到 $CONFIG_FILE"
}

# ============================================
# 初始化配置
# ============================================
initial_config() {
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE}         VPS 监控配置向导${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"

    read -rp "请输入 PushPlus Token: " PUSHPLUS_TOKEN
    while [[ -z "$PUSHPLUS_TOKEN" ]]; do
        echo "❌ Token 不能为空，请重新输入。"
        read -rp "请输入 PushPlus Token: " PUSHPLUS_TOKEN
    done

    echo ""
    echo "请输入要监控的 Telegram 频道（支持多个，用空格分隔）"
    echo "示例：hosts_bid greencloud_hosts_bid"
    read -rp "频道名: " TG_CHANNELS
    while [[ -z "$TG_CHANNELS" ]]; do
        echo "❌ 频道不能为空。"
        read -rp "请输入频道名: " TG_CHANNELS
    done

    echo ""
    echo "请输入关键词过滤（用空格分隔，如：上架 库存 补货），留空则不过滤"
    read -rp "关键词: " KEYWORDS

    echo ""
    echo "请输入检查周期（单位：秒，例如 60 表示每分钟检查一次）"
    read -rp "检查周期: " CHECK_INTERVAL
    [[ -z "$CHECK_INTERVAL" ]] && CHECK_INTERVAL=60

    write_config
    echo -e "${GREEN}✅ 配置已完成！${PLAIN}"
    read_config
}

# ============================================
# 推送到 PushPlus
# ============================================
pushplus_send() {
    local title="$1"
    local content="$2"
    curl -s -X POST "http://www.pushplus.plus/send" \
        -H "Content-Type: application/json" \
        -d "{\"token\":\"${PUSHPLUS_TOKEN}\",\"title\":\"${title}\",\"content\":\"${content}\",\"template\":\"markdown\"}" \
        >/dev/null
}

# ============================================
# 获取频道最新一条消息
# ============================================
get_latest_message() {
    local channel="$1"
    # 自动识别是否为完整URL
    if [[ "$channel" =~ ^https?://t\.me/s/ ]]; then
        local url="$channel"
    else
        local url="https://t.me/s/${channel}"
    fi
    # 抓取整个网页HTML，添加 User-Agent 模拟浏览器
    local html=$(curl -s -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" "$url")
    
    # 改进 awk：提取所有 tgme_widget_message_text 块，并取最后一个完整块
    local message=$(echo "$html" | awk '
        BEGIN { RS="</div>" }  # 以 </div> 为记录分隔符
        /tgme_widget_message_text js-message_text/ {
            gsub(/.*tgme_widget_message_text js-message_text[^>]*>/, "");  # 移除开头标签
            gsub(/<[^>]+>/, "");  # 移除剩余标签
            gsub(/^[ \t\n]+|[ \t\n]+$/, "");  # 清理空白
            if (length($0) > 0) messages[NR] = $0;  # 存储非空消息
        }
        END {
            if (length(messages) > 0) {
                print messages[NR];  # 打印最后一个消息
            }
        }
    ' | tail -n 1)  # 额外保险，取最后一个
    
    # 替换HTML换行标签为真实换行
    message=$(echo "$message" | sed 's/<br>/\n/gI')
    # 删除剩余HTML标签
    message=$(echo "$message" | sed 's/<[^>]*>//g')
    # 解码常见HTML实体
    message=$(echo "$message" | sed 's/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')
    # 清理多余空白行与前后空格，并合并多行为单字符串（如果需要多行，可移除 awk NF）
    message=$(echo "$message" | sed 's/^[ \t]*//;s/[ \t]*$//' | awk 'NF' | tr '\n' ' ' | sed 's/  */ /g')
    
    # 如果消息太短或看起来像视图，可能是提取失败，输出空
    local pattern='[0-9]+ ?views'  # 使用变量存储正则，? 表示可选空格的前一个字符（这里是空格）
    if [[ ${#message} -lt 10 || "$message" =~ $pattern ]]; then
        message=""
    fi
    
    echo "$message"
    
    echo "$message"
}

# ============================================
# 检查频道更新并推送
# ============================================
check_channels() {
    read_config || return
    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"
        local latest=$(get_latest_message "$ch")
        [[ -z "$latest" ]] && continue
        local last=$(cat "$STATE_FILE" 2>/dev/null)

        if [[ "$latest" != "$last" ]]; then
            # 关键词筛选
            if [[ -n "$KEYWORDS" ]]; then
                matched=0
                for kw in $KEYWORDS; do
                    if [[ "$latest" == *"$kw"* ]]; then
                        matched=1
                        break
                    fi
                done
                [[ $matched -eq 0 ]] && continue
            fi

            local msg="📢 频道：${ch}\n🕒 时间：$(date '+%Y-%m-%d %H:%M:%S')\n💬 内容：${latest}"
            pushplus_send "VPS监控通知" "$msg"
            echo "$latest" > "$STATE_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ [$ch] 推送成功: $latest" >> "$LOG_FILE"
        fi
    done
}

# ============================================
# 手动打印 / 推送
# ============================================
print_latest() {
    read_config || return
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE}         最新频道消息${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    for ch in $TG_CHANNELS; do
        echo -e "${CYAN}频道：$ch${PLAIN}"
        echo "最新消息：$(get_latest_message "$ch")"
        echo "--------------------------------------"
    done
    read -p "按 Enter 返回菜单..."
}

manual_push() {
    read_config || return
    for ch in $TG_CHANNELS; do
        latest=$(get_latest_message "$ch")
        [[ -z "$latest" ]] && continue
        pushplus_send "手动推送 [$ch]" "$latest"
        echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ 手动推送成功 [$ch]" >> "$LOG_FILE"
    done
    echo "✅ 手动推送完成。"
    read -p "按 Enter 返回菜单..."
}

# ============================================
# 定时运行（cron模式）
# ============================================
if [[ "$1" == "-cron" ]]; then
    check_channels
    exit 0
fi

# ============================================
# 设置定时任务
# ============================================
setup_cron() {
    read_config || return
    local entry="* * * * * /usr/bin/flock -n /tmp/vps_moniter.lock $SCRIPT_PATH -cron"
    crontab -l 2>/dev/null | grep -v "vps_moniter.sh" | { cat; echo "$entry"; } | crontab -
    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ Crontab 已更新。" | tee -a "$CRON_LOG"
}

# ============================================
# 主菜单
# ============================================
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${PURPLE}          VPS 监控管理菜单${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 安装 / 修改配置"
        echo -e "${GREEN}2.${PLAIN} 设置推送周期 (当前: ${CHECK_INTERVAL:-未设}) 秒"
        echo -e "${GREEN}3.${PLAIN} 打印频道最新消息"
        echo -e "${GREEN}4.${PLAIN} 手动推送最新消息"
        echo -e "${RED}5.${PLAIN} 停止并删除任务"
        echo -e "${WHITE}0.${PLAIN} 退出"
        echo -e "${BLUE}======================================${PLAIN}"
        read -rp "请选择操作 [0-5]: " choice
        echo
        case $choice in
            1) initial_config; setup_cron ;;
            2)
                read -rp "请输入新的周期(秒): " CHECK_INTERVAL
                write_config
                echo -e "${GREEN}✅ 周期已更新${PLAIN}"
                ;;
            3) print_latest ;;
            4) manual_push ;;
            5)
                crontab -l | grep -v "vps_moniter.sh" | crontab -
                echo -e "${RED}已停止定时任务并清理配置。${PLAIN}"
                ;;
            0) exit 0 ;;
            *) echo "无效选项";;
        esac
        read -p "按 Enter 返回菜单..."
    done
}

main_menu

