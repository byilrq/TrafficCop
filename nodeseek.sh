#!/bin/bash
# ============================================
# Telegram Channel → nodeseek监控脚本 v1.0
# 作者：by / 更新时间：2025-11-10
# ============================================
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"
CONFIG_FILE="$WORK_DIR/nodeseek_config.txt"
LOG_FILE="$WORK_DIR/nodeseek.log"
CRON_LOG="$WORK_DIR/nodeseek_cron.log"
SCRIPT_PATH="$WORK_DIR/nodeseek.sh"
# ================== 彩色定义 ==================
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; PURPLE="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"; PLAIN="\033[0m"
export TZ='Asia/Shanghai'

# ============================================
# 配置管理（支持自动加载和持久化保存）
# ============================================
read_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${RED}❌ 配置文件不存在或为空，请先执行配置向导。${PLAIN}"
        return 1
    fi

    # 加载配置
    source "$CONFIG_FILE"

    # 基础校验
    if [ -z "$PUSHPLUS_TOKEN" ] || [ -z "$TG_CHANNELS" ]; then
        echo -e "${RED}❌ 配置不完整，请重新配置。${PLAIN}"
        return 1
    fi
    return 0
}

write_config() {
    cat > "$CONFIG_FILE" <<EOF
PUSHPLUS_TOKEN="$PUSHPLUS_TOKEN"
TG_CHANNELS="$TG_CHANNELS"
KEYWORDS="$KEYWORDS"
EOF
    echo -e "${GREEN}✅ 配置已保存到 $CONFIG_FILE${PLAIN}"
}

# ============================================
# 初始化配置（支持保留旧值）
# ============================================

initial_config() {
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} nodeseek 配置向导${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    echo ""
    echo "提示：按 Enter 保留当前配置，输入新值将覆盖原配置。"
    echo ""

    # 若存在旧配置则读取
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    # --- PushPlus Token ---
    if [ -n "$PUSHPLUS_TOKEN" ]; then
        local token_display="${PUSHPLUS_TOKEN:0:10}...${PUSHPLUS_TOKEN: -4}"
        read -rp "请输入 PushPlus Token [当前: $token_display]: " new_token
        [[ -z "$new_token" ]] && new_token="$PUSHPLUS_TOKEN"
    else
        read -rp "请输入 PushPlus Token: " new_token
        while [[ -z "$new_token" ]]; do
            echo "❌ Token 不能为空，请重新输入。"
            read -rp "请输入 PushPlus Token: " new_token
        done
    fi

    # --- Telegram Channel(s) ---
    if [ -n "$TG_CHANNELS" ]; then
        read -rp "请输入要监控的 Telegram 频道 [当前: $TG_CHANNELS] (可输入多个或URL): " new_channels
        [[ -z "$new_channels" ]] && new_channels="$TG_CHANNELS"
    else
        read -rp "请输入要监控的 Telegram 频道（多个用空格分隔）: " new_channels
        while [[ -z "$new_channels" ]]; do
            echo "❌ 频道不能为空，请重新输入。"
            read -rp "请输入频道名或URL: " new_channels
        done
    fi

    # --- 关键词过滤设置 ---
    echo ""
    echo "当前关键词：${KEYWORDS:-未设置}"
    read -rp "是否需要重置关键词？(Y/N): " reset_kw

    if [[ "$reset_kw" =~ ^[Yy]$ ]]; then
        # 用户选择重置
        while true; do
            echo "请输入关键词（多个关键词用 , 分隔），示例：上架,库存,补货"
            read -rp "输入关键词: " new_keywords

            # 允许用户输入空值（表示清空所有关键词）
            if [[ -z "$new_keywords" ]]; then
                KEYWORDS=""
                echo "关键词已清空。"
                break
            fi

            # 将逗号替换为空格，并压缩多个空格
            new_keywords=$(echo "$new_keywords" | sed 's/,/ /g' | awk '{$1=$1; print}')

            # 分割关键词统计数量
            kw_count=$(echo "$new_keywords" | wc -w)

            if (( kw_count > 10 )); then
                echo "❌ 关键词数量不能超过 10 个（当前：$kw_count 个）。请重新输入。"
            else
                KEYWORDS="$new_keywords"
                echo "关键词已更新为：$KEYWORDS"
                break
            fi
        done

    else
        # 用户选择不重置，保持现有 KEYWORDS
        echo "保持原有关键词：${KEYWORDS:-未设置}"
    fi


    # 保存配置
    PUSHPLUS_TOKEN="$new_token"
    TG_CHANNELS="$new_channels"
    write_config

    echo ""
    echo -e "${GREEN}✅ 配置已更新并保存成功！${PLAIN}"
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
# 提取标题函数
# ============================================
extract_title() {
    local message="$1"
    local pattern='^( *[0-9]+ ?(views?|次)? *$)|^[0-9]{1,2}:[0-9]{2}$|^[0-9]{4}/[0-9]{2}/[0-9]{2}'
    if [[ -z "$message" || "$message" =~ $pattern ]]; then
        echo ""
        return
    fi
    if [[ "$message" =~ 【([^】]+)】 ]]; then
        title="${BASH_REMATCH[1]}"
    else
        title=$(echo "$message" | head -n1)
    fi
    if [[ -z "$title" || ${#title} -lt 5 || "$title" =~ $pattern ]]; then
        title=""
    fi
    echo "$title"
}

# ============================================
# 手动打印 
# ============================================
print_latest() {
    read_config || return
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} 最新频道消息标题${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"
        echo -e "${CYAN}频道：$ch${PLAIN}"
        if [ ! -s "$STATE_FILE" ]; then
            echo "最新标题：（暂无消息或提取失败）"
        else
            echo -e "最新10条标题（最新在下）："
            i=1
            while read -r title; do
                echo "${i}) ${title}"
                ((i++))
            done < "$STATE_FILE"
        fi
        echo "--------------------------------------"
    done
}

# ============================================
# 手动刷新10条新的信息
# ============================================
manual_fresh() {
    read_config || return
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} 手动更新并打印所有频道${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"

    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"
        echo -e "${CYAN}频道：$ch${PLAIN}"

        # 抓取频道 HTML
        local html=$(curl -s --compressed -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" "https://t.me/s/${ch}")
        if [[ -z "$html" ]]; then
            echo "❌ 获取频道内容失败。"
            echo "--------------------------------------"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ❌ 手动更新失败（无法获取HTML）" >> "$LOG_FILE"
            continue
        fi

        # 提取最近10条消息
        local raw_messages=()
        while IFS= read -r line; do
            raw_messages+=("$line")
        done < <(echo "$html" | awk '
            BEGIN { RS="</div>" }
            /tgme_widget_message_text/ && !/tgme_widget_message_views/ && !/tgme_widget_message_date/ {
                gsub(/.*tgme_widget_message_text[^>]*>/, "")
                gsub(/<br>/, "\n")
                gsub(/<[^>]+>/, "")
                gsub(/&nbsp;/, " ")
                gsub(/&amp;/, "&")
                gsub(/&lt;/, "<")
                gsub(/&gt;/, ">")
                gsub(/&quot;/, "\"")
                gsub(/&#036;/, "$")
                gsub(/&#64;/, "@")
                gsub(/^[ \t\n\r]+|[ \t\n\r]+$/, "")
                if (length($0) > 0) print $0
            }
        ' | tail -n 10)

        # 提取标题
        local messages=()
        for raw in "${raw_messages[@]}"; do
            local title=$(extract_title "$raw")
            [[ -n "$title" ]] && messages+=("$title")
        done

        if [[ ${#messages[@]} -eq 0 ]]; then
            echo "❌ 未提取到有效消息。"
            echo "--------------------------------------"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ❌ 最新消息更新失败（未解析到消息）" >> "$LOG_FILE"
            continue
        fi

        # 更新缓存文件
        printf "%s\n" "${messages[@]}" > "$STATE_FILE"

        # 打印结果到终端（不写入日志）
        echo -e "${GREEN}最新10条消息标题（最新在下）：${PLAIN}"
        local i=1
        for msg in "${messages[@]}"; do
            echo "${i}) ${msg}"
            ((i++))
        done
        echo "--------------------------------------"

        # 只写入简单成功记录
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 最新消息已更新" >> "$LOG_FILE"
    done

    echo -e "${GREEN}✅ 所有频道已手动更新并打印完成。${PLAIN}"
}


# ============================================
# 手动推送10条新的信息
# ============================================
manual_push() {
    read_config || return

    local KEYWORDS_LOWER=$(echo "$KEYWORDS" | tr 'A-Z' 'a-z')

    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"
        echo -e "${CYAN}频道：$ch${PLAIN}"

        if [[ -z "$KEYWORDS" ]]; then
            echo "❌ 未设置关键词，跳过 [$ch]"
            continue
        fi

        if [[ ! -s "$STATE_FILE" ]]; then
            echo "❌ 无缓存文件，跳过 [$ch]"
            continue
        fi

        # 读取缓存
        local messages=()
        while IFS= read -r line; do messages+=("$line"); done < "$STATE_FILE"

        local total=${#messages[@]}
        local start=$(( total > 10 ? total - 10 : 0 ))
        local matched_msgs=()

        echo "当前关键词：$KEYWORDS"
        echo "最新10条消息标题匹配情况如下："

        # 匹配逻辑
        for ((idx=start; idx<total; idx++)); do
            local msg="${messages[$idx]}"
            local msg_lower=$(echo "$msg" | tr 'A-Z' 'a-z')

            local matched=0
            local matched_kw=""

            for kw in $KEYWORDS_LOWER; do
                if [[ "$msg_lower" == *"$kw"* ]]; then
                    matched=1
                    matched_kw="$kw"
                    break
                fi
            done

            if [[ $matched -eq 1 ]]; then
                matched_msgs+=("$msg")
                echo "${idx}) ${msg}  --匹配：${matched_kw}"
            else
                echo "${idx}) ${msg}  --不匹配"
            fi
        done

        echo ""

        if [[ ${#matched_msgs[@]} -eq 0 ]]; then
            echo "⚠️ 无匹配关键词消息"
            continue
        fi

        # 推送
        local push_text=""
        local i=1
        for msg in "${matched_msgs[@]}"; do
            push_text+="${i}) ${msg}\n\n"
            ((i++))
        done

        pushplus_send "关键词匹配推送 [$ch]" "$push_text"
        echo "✅ 推送完成（匹配 ${#matched_msgs[@]} 条）"
    done
}
# ============================================
# 自动推送（用于 cron）—— 匹配关键词且只推送一次
# ============================================
auto_push() {
    read_config || return

    local KEYWORDS_LOWER=$(echo "$KEYWORDS" | tr 'A-Z' 'a-z')
    local SENT_FILE="$WORK_DIR/sent_nodeseekc.txt"

    # 如果发送记录不存在，创建
    [[ -f "$SENT_FILE" ]] || touch "$SENT_FILE"

    for ch in $TG_CHANNELS; do
        local STATE_FILE="$WORK_DIR/last_${ch}.txt"

        echo -e "${CYAN}自动推送频道：${ch}${PLAIN}"

        if [[ -z "$KEYWORDS" ]]; then
            echo "❌ 未设置关键词，跳过 [$ch]"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ⚠️无关键词，跳过自动推送" >> "$LOG_FILE"
            continue
        fi

        if [[ ! -s "$STATE_FILE" ]]; then
            echo "❌ 无缓存文件，跳过 [$ch]"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ⚠️无缓存文件" >> "$LOG_FILE"
            continue
        fi

        # 读取最近10条消息
        local messages=()
        while IFS= read -r line; do messages+=("$line"); done < "$STATE_FILE"

        local total=${#messages[@]}
        local start=$(( total > 10 ? total - 10 : 0 ))
        local new_matched_msgs=()    # ⬅ 只推送本次新增的消息
        local log_matched_count=0    # ⬅ 用于 cron 显示匹配条数

        # --------------✨ 日志增强输出 ✨---------------
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 当前关键词：$KEYWORDS" >> "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 最新10条消息匹配情况如下：" >> "$LOG_FILE"
        # -------------------------------------------------

        for ((idx = start; idx < total; idx++)); do
            local msg="${messages[$idx]}"
            local msg_lower=$(echo "$msg" | tr 'A-Z' 'a-z')

            local matched=0
            local matched_kw=""

            # 匹配关键词（忽略大小写）
            for kw in $KEYWORDS_LOWER; do
              #  if [[ "$msg_lower" == *"$kw"* ]]; then
                if [[ "$msg_lower" =~ \b"$kw"\b ]]; then
                    matched=1
                    matched_kw="$kw"
                    break
                fi
            done

            if [[ $matched -eq 1 ]]; then
                ((log_matched_count++))

                # -------- 去重判断 --------
                if grep -Fxq "$msg" "$SENT_FILE"; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 已推送过（跳过）：${msg}" >> "$LOG_FILE"
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 匹配 ✔：${msg}（关键词：$matched_kw）" >> "$LOG_FILE"
                    new_matched_msgs+=("$msg")
                fi
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 未匹配 ✖：${msg}" >> "$LOG_FILE"
            fi
        done

        # -----------------------
        # 没有用于推送的新消息
        # -----------------------
        if [[ ${#new_matched_msgs[@]} -eq 0 ]]; then
            echo "⚠️ [$ch] 本次无关键词匹配"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] ⚠️无匹配或均已推送过" >> "$LOG_FILE"
            continue
        fi

        # -----------------------
        # 拼接推送内容
        # -----------------------
        local push_text=""
        local i=1
        for msg in "${new_matched_msgs[@]}"; do
            push_text+="${i}) ${msg}\n\n"
            ((i++))
        done

        # -----------------------
        # 执行推送pushplus
        # -----------------------
        pushplus_send "Node" "$push_text"

        # 写入已推送记录
        for msg in "${new_matched_msgs[@]}"; do
            echo "$msg" >> "$SENT_FILE"
        done

        echo "📨 [$ch] 自动推送成功（${#new_matched_msgs[@]} 条）"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$ch] 📩 自动推送成功（${#new_matched_msgs[@]} 条）" >> "$LOG_FILE"
    done
}


# ============================================
# 测试 PushPlus 推送功能
# ============================================
test_pushplus_notification() {
    read_config || return
    echo -e "${CYAN}正在发送测试推送...${PLAIN}"
    local now_time=$(date '+%Y-%m-%d %H:%M:%S')
    local test_title="🔔 [监控测试消息]"
    local test_content="🕒 时间：${now_time}<br>📢 频道：${TG_CHANNELS:-未设置}<br><br>这是来自 TG频道监控脚本的测试消息。<br>如果您看到此推送，说明 PushPlus 配置正常 ✅"
    local response=$(curl -s -X POST "http://www.pushplus.plus/send" \
        -H "Content-Type: application/json" \
        -d "{\"token\":\"${PUSHPLUS_TOKEN}\",\"title\":\"${test_title}\",\"content\":\"${test_content}\",\"template\":\"markdown\"}")
    if echo "$response" | grep -q '"code":200'; then
        echo -e "${GREEN}✅ PushPlus 测试推送成功！${PLAIN}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ 测试推送成功" >> "$LOG_FILE"
    else
        echo -e "${RED}❌ 推送失败！${PLAIN}"
        echo "返回信息：$response"
        echo "$(date '+%Y-%m-%d %H:%M:%S') ❌ 测试推送失败：$response" >> "$LOG_FILE"
    fi
}

# ============================================
# 日志轮转：每天清理一次日志，只保留最近 7 天
# ============================================
log_rotate() {
    local log_dir="$WORK_DIR"
    local log_file="$CRON_LOG"

    # 标记文件，用来判断是否已经执行过
    local flag_file="$log_dir/log_clean.flag"

    local today=$(date +%Y-%m-%d)

    # 如果 flag 文件中的日期与今天一样，则不重复执行
    if [[ -f "$flag_file" && "$(cat "$flag_file")" == "$today" ]]; then
        return
    fi

    echo "🔥 开始日志轮转：删除 7 天前的日志文件..." >> "$CRON_LOG"

    # 删除 7 天以前的 *.log.* 归档日志
    find "$log_dir" -name "*.log.*" -mtime +7 -delete

    # 压缩当前日志为归档文件
    if [[ -f "$log_file" ]]; then
        mv "$log_file" "${log_file}.${today}"
        touch "$log_file"
    fi

    # 更新标记文件
    echo "$today" > "$flag_file"

    echo "✔ 日志轮转完成" >> "$CRON_LOG"
}
# ============================================
# 定时运行（cron模式）
# 每30秒执行一次 manual_fresh + auto_push
# 自动限制日志文件最多 100 行（cron.log / sent.txt / nodeseek.log）
# ============================================
if [[ "$1" == "-cron" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') 🚀 定时任务已启动（每30秒执行 manual_fresh + auto_push）" >> "$CRON_LOG"

    while true; do

        # ============================
        # 限制文件最多 100 行
        # ============================
        trim_file() {
            local file="$1"
            local max_lines=100
            [[ -f "$file" ]] || return
            local cnt=$(wc -l < "$file")
            if (( cnt > max_lines )); then
                tail -n "$max_lines" "$file" > "${file}.tmp"
                mv "${file}.tmp" "$file"
            fi
        }

        trim_file "$CRON_LOG"
        trim_file "$LOG_FILE"
        trim_file "$WORK_DIR/sent_nodeseekc.txt"

        # ============================
        # 执行并写入简洁日志
        # ============================
        {
            echo "$(date '+%Y-%m-%d %H:%M:%S') ▶️ 执行 manual_fresh()" >> "$CRON_LOG"
            manual_fresh >/dev/null 2>&1
            echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ manual_fresh() 执行完成" >> "$CRON_LOG"

            echo "$(date '+%Y-%m-%d %H:%M:%S') ▶️ 执行 auto_push()" >> "$CRON_LOG"

            # 捕获 auto_push 的匹配数量
            MATCH_OUTPUT=$(auto_push 2>&1)

            # 是否有匹配？
            if echo "$MATCH_OUTPUT" | grep -q "匹配到"; then
                MATCH_COUNT=$(echo "$MATCH_OUTPUT" | grep -oP "(?<=匹配到 ).*(?= 条)" | head -n1)
                echo "⚠️ [nodeseekc] 本次有 ${MATCH_COUNT} 条关键词匹配   自动推送频道：nodeseekc" >> "$CRON_LOG"
            else
                echo "⚠️ [nodeseekc] 本次无关键词匹配" >> "$CRON_LOG"
            fi

            echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ auto_push() 执行完成" >> "$CRON_LOG"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 🕒 等待30秒进入下次周期..." >> "$CRON_LOG"
            echo "" >> "$CRON_LOG"
        } &

        wait
        sleep 30
    done

    exit 0
fi
# ============================================
# 设置定时任务,写入系统cron，*代表1分钟执行一次脚本
# ============================================
setup_cron() {
    read_config || return

    local entry="* * * * * /usr/bin/flock -n /tmp/nodeseek.lock $SCRIPT_PATH -cron"

    echo "🛠 正在检查 nodeseek 定时任务..."

    # 检查是否已存在 nodeseek 任务
    if crontab -l 2>/dev/null | grep -q "nodeseek.sh -cron"; then
        echo "🔍 已检测到现有 nodeseek 定时任务。"

        # 检查是否与最新命令一致
        if crontab -l | grep -q "$entry"; then
            echo "✔ 当前 cron 已是最新版本，无需更新。"
        else
            echo "⚠ 检测到旧版本 cron，正在更新为最新命令..."
            crontab -l | grep -v "nodeseek.sh -cron" | crontab -
            crontab -l | { cat; echo "$entry"; } | crontab -
            echo "✔ nodeseek cron 已成功更新为最新版本。"
        fi
    else
        echo "➕ 未检测到 nodeseek 定时任务，正在添加..."
        crontab -l 2>/dev/null | { cat; echo "$entry"; } | crontab -
        echo "✔ nodeseek 定时任务已成功添加。"
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ nodeseek 定时任务检查并更新完成。" | tee -a "$CRON_LOG"
}


# ============================================
# 关闭定时任务
# ============================================
stop_cron() {
    pkill -f nodeseek
    crontab -l 2>/dev/null | grep -v 'nodeseek' | crontab -
    systemctl restart cron || service cron restart
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
        echo -e "${GREEN}1.${PLAIN} 安装/修改配置"
        echo -e "${GREEN}2.${PLAIN} 打印最新消息"
        echo -e "${GREEN}3.${PLAIN} 推送最新消息"
        echo -e "${GREEN}4.${PLAIN} 推送测试消息"
        echo -e "${GREEN}5.${PLAIN} 手动更新&打印"
        echo -e "${RED}6.${PLAIN} 清除cron任务"
        echo -e "${WHITE}0.${PLAIN} 退出"
        echo -e "${BLUE}======================================${PLAIN}"
        read -rp "请选择操作 [0-6]: " choice
        echo
        case $choice in
            1) initial_config; setup_cron; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            2) print_latest; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            3) manual_push; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            4) get_latest_message; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            5) manual_fresh; echo -e "${GREEN} 手动更新完成。${PLAIN}" ;;
            6) stop_cron; echo -e "${GREEN} 停止cron任务完成。${PLAIN}" ;;
            0) exit 0 ;;
            *) echo "无效选项"; echo -e "${GREEN}操作完成。${PLAIN}" ;;
        esac
        read -p "按 Enter 返回菜单..."
    done
}

main_menu
