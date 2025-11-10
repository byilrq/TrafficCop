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
# 配置文件管理
# ============================================
read_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "配置文件不存在或为空。"
        return 1
    fi
    source "$CONFIG_FILE"
    if [ -z "$PUSHPLUS_TOKEN" ] || [ -z "$TG_CHANNELS" ]; then
        echo "配置不完整。"
        return 1
    fi
    return 0
}

write_config() {
    cat > "$CONFIG_FILE" <<EOF
PUSHPLUS_TOKEN="$PUSHPLUS_TOKEN"
TG_CHANNELS="$TG_CHANNELS"
KEYWORDS="$KEYWORDS"
CHECK_INTERVAL="$CHECK_INTERVAL"
EOF
    echo -e "${GREEN}✅ 配置已保存到 $CONFIG_FILE${PLAIN}"
}

# ============================================
# 初始化配置（带保留旧值逻辑）
# ============================================
initial_config() {
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} VPS 监控配置向导${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    echo ""
    echo "提示：按 Enter 保留当前配置，输入新值则更新配置"
    echo ""

    # --- PushPlus Token ---
    if [ -n "$PUSHPLUS_TOKEN" ]; then
        local token_display="${PUSHPLUS_TOKEN:0:10}...${PUSHPLUS_TOKEN: -4}"
        read -rp "请输入 PushPlus Token [当前: $token_display]: " new_token
    else
        read -rp "请输入 PushPlus Token: " new_token
    fi
    if [[ -z "$new_token" && -n "$PUSHPLUS_TOKEN" ]]; then
        new_token="$PUSHPLUS_TOKEN"
        echo " → 保留原配置"
    fi
    while [[ -z "$new_token" ]]; do
        echo "❌ Token 不能为空，请重新输入。"
        read -rp "请输入 PushPlus Token: " new_token
    done

    # --- Telegram Channel(s) ---
    if [ -n "$TG_CHANNELS" ]; then
        read -rp "请输入要监控的 Telegram 频道 [当前: $TG_CHANNELS] (可输入多个或URL): " new_channels
    else
        read -rp "请输入要监控的 Telegram 频道（多个用空格分隔）: " new_channels
    fi
    if [[ -z "$new_channels" && -n "$TG_CHANNELS" ]]; then
        new_channels="$TG_CHANNELS"
        echo " → 保留原配置"
    fi
    while [[ -z "$new_channels" ]]; do
        echo "❌ 频道不能为空，请重新输入。"
        read -rp "请输入频道名或URL: " new_channels
    done

    # --- 关键词过滤 ---
    if [ -n "$KEYWORDS" ]; then
        read -rp "请输入关键词过滤 [当前: $KEYWORDS] (留空保留原配置): " new_keywords
        [[ -z "$new_keywords" ]] && new_keywords="$KEYWORDS" && echo " → 保留原配置"
    else
        read -rp "请输入关键词过滤（如：上架 库存 补货），留空则不过滤: " new_keywords
    fi

    # --- 检查周期 ---
    if [ -n "$CHECK_INTERVAL" ]; then
        read -rp "请输入检查周期 [当前: ${CHECK_INTERVAL}s]: " new_interval
    else
        read -rp "请输入检查周期（单位：秒，如 60 表示每分钟）: " new_interval
    fi
    if [[ -z "$new_interval" && -n "$CHECK_INTERVAL" ]]; then
        new_interval="$CHECK_INTERVAL"
        echo " → 保留原配置"
    fi
    while [[ -z "$new_interval" || ! "$new_interval" =~ ^[0-9]+$ ]]; do
        echo "❌ 周期必须是数字。请重新输入: "
        read -rp "检查周期（秒）: " new_interval
    done

    # --- 写入配置 ---
    PUSHPLUS_TOKEN="$new_token"
    TG_CHANNELS="$new_channels"
    KEYWORDS="$new_keywords"
    CHECK_INTERVAL="$new_interval"

    write_config
    echo ""
    echo -e "${GREEN}✅ 配置已更新成功！${PLAIN}"
    echo ""
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
    # 抓取HTML，模拟浏览器 + 压缩 + 重试
    local html=$(curl -s --compressed -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36" "$url" || echo "")
    [[ -z "$html" ]] && echo "" && return
    # 提取最后一个消息文本块（匹配当前Telegram class，无 js-message_text）
    local message=$(echo "$html" | awk '
        BEGIN { RS="</div>" } # 以 </div> 分隔记录
        /tgme_widget_message_text/ && !/tgme_widget_message_views/ && !/tgme_widget_message_date/ {
            gsub(/.*tgme_widget_message_text[^>]*>/, ""); # 移除开头标签
            gsub(/<[^>]+>/, ""); # 移除所有HTML标签
            gsub(/^[ \t\n\r]+|[ \t\n\r]+$/, ""); # 清理空白
            if (length($0) > 0) messages[NR] = $0;
        }
        END {
            if (length(messages) > 0) {
                for (i in messages) last = messages[i]; # 取最后一个
                print last;
            }
        }
    ')
    # 如果 awk 没提取到，备用方案（极少情况）
    if [[ -z "$message" ]]; then
        message=$(echo "$html" | grep -Poz '(?s)<div class="tgme_widget_message_text[^>]*>(.*?)</div>' | tail -n1 | sed 's/<[^>]*>//g; s/^[\n ]*//; s/[\n ]*$//')
    fi
    # 替换<br>为换行
    message=$(echo "$message" | sed 's/<br>/\n/gI')
    # 解码常见HTML实体（增强版，添加 $、@ 等）
    message=$(echo "$message" | sed 's/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#036;/$/g; s/&#64;/@/g; s/&#10;/\n/g; s/&#13;//g')
    # 清理多余空白和空行，但保留换行结构
    message=$(echo "$message" | sed 's/^[ \t]*//; s/[ \t]*$//' | awk 'NF > 0 {print $0}')
    # 过滤掉明显是视图/日期/空的消息（views 可能是纯数字、"xxviews" 或 "xx views"）
    local pattern='^( *[0-9]+ ?(views?|次)? *$)|^[0-9]{1,2}:[0-9]{2}$|^[0-9]{4}/[0-9]{2}/[0-9]{2}'
    if [[ -z "$message" || ${#message} -lt 15 || "$message" =~ $pattern ]]; then
        message=""
    fi
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
    echo -e "${PURPLE} 最新频道消息${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    for ch in $TG_CHANNELS; do
        local msg=$(get_latest_message "$ch")
        echo -e "${CYAN}频道：$ch${PLAIN}"
        if [[ -z "$msg" ]]; then
            echo "最新消息：（暂无消息或提取失败）"
        else
            echo -e "最新消息：\n$msg"
        fi
        echo "--------------------------------------"
    done
    # 移除这里的 read -p，统一由主循环处理
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
    # 移除这里的 read -p，统一由主循环处理
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
        echo -e "${PURPLE} VPS 监控管理菜单${PLAIN}"
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
            1) initial_config; setup_cron; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            2)
                read -rp "请输入新的周期(秒): " CHECK_INTERVAL
                write_config
                echo -e "${GREEN}✅ 周期已更新${PLAIN}"
                echo -e "${GREEN}操作完成。${PLAIN}"
                ;;
            3) print_latest; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            4) manual_push; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            5)
                crontab -l | grep -v "vps_moniter.sh" | crontab -
                echo -e "${RED}已停止定时任务并清理配置。${PLAIN}"
                echo -e "${GREEN}操作完成。${PLAIN}"
                ;;
            0) exit 0 ;;
            *) echo "无效选项"; echo -e "${GREEN}操作完成。${PLAIN}" ;;
        esac
        read -p "按 Enter 返回菜单..."
    done
}
main_menu
