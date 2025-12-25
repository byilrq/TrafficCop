#!/bin/bash
# ============================================
# Node 最新帖子监控脚本
# 更新时间：2025-12-21
# 修复点：
# 1) 不再依赖 gawk 的 PROCINFO["sorted_in"] 排序（Debian 常见 awk=mawk 会乱序）
#    -> 统一用 sort -n -t'|' -k1,1 做稳定排序
# 2) -cron 是常驻 while true 进程：修改脚本后务必 stop_cron 再启动，否则老进程仍用旧逻辑写文件
# ============================================

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TZ='Asia/Shanghai'

# 配置路径
WORK_DIR="/root/TrafficCop"
mkdir -p "$WORK_DIR"
CONFIG_FILE="$WORK_DIR/node_config.txt"
LOG_FILE="$WORK_DIR/node.log"
CRON_LOG="$WORK_DIR/node_cron.log"
SCRIPT_PATH="$WORK_DIR/node.sh"

# 用于条件请求（If-Modified-Since）
LAST_MOD_FILE="$WORK_DIR/.node_last_modified"

# ================== 彩色定义 ==================
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; PURPLE="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"; PLAIN="\033[0m"

# ============================================
# 配置管理（自动加载 & 持久化保存）
# ============================================
read_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${RED}❌ 配置文件不存在或为空，请先执行配置向导。${PLAIN}"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    # 兼容旧配置：没写就默认 180 秒
    [[ -z "$INTERVAL_SEC" ]] && INTERVAL_SEC=180

    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_PUSH_CHAT_ID" ] || [ -z "$NS_URL" ]; then
        echo -e "${RED}❌ 配置不完整（需 TG_BOT_TOKEN / TG_PUSH_CHAT_ID / NS_URL），请重新配置。${PLAIN}"
        return 1
    fi
    return 0
}

write_config() {
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_PUSH_CHAT_ID="$TG_PUSH_CHAT_ID"
NS_URL="$NS_URL"
KEYWORDS="$KEYWORDS"
INTERVAL_SEC="$INTERVAL_SEC"
EOF
    echo -e "${GREEN}✅ 配置已保存到 $CONFIG_FILE${PLAIN}"
}

# ============================================
# 时间格式：2025.12.08.10:40
# ============================================
fmt_time() { date '+%Y.%m.%d.%H:%M'; }

# ============================================
# Telegram 推送（content 必须是“真实换行”文本）
# ============================================
tg_send() {
    local content="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_PUSH_CHAT_ID}" \
        --data-urlencode "text=${content}" \
        -d "disable_web_page_preview=true" \
        >/dev/null
}

# ============================================
# 初始化配置（支持保留旧值）
# ============================================
initial_config() {
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} node 最新帖子监控 配置向导${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    echo ""
    echo "提示：按 Enter 保留当前配置，输入新值将覆盖原配置。"
    echo ""

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    # --- Telegram Bot Token ---
    if [ -n "$TG_BOT_TOKEN" ]; then
        local token_display="${TG_BOT_TOKEN:0:10}...${TG_BOT_TOKEN: -4}"
        read -rp "请输入 Telegram Bot Token [当前: $token_display]: " new_bot_token
        [[ -z "$new_bot_token" ]] && new_bot_token="$TG_BOT_TOKEN"
    else
        read -rp "请输入 Telegram Bot Token: " new_bot_token
        while [[ -z "$new_bot_token" ]]; do
            echo "❌ Bot Token 不能为空，请重新输入。"
            read -rp "请输入 Telegram Bot Token: " new_bot_token
        done
    fi

    # --- 个人私聊 Chat ID ---
    if [ -n "$TG_PUSH_CHAT_ID" ]; then
        read -rp "请输入个人推送 Chat ID [当前: $TG_PUSH_CHAT_ID]: " new_chat_id
        [[ -z "$new_chat_id" ]] && new_chat_id="$TG_PUSH_CHAT_ID"
    else
        read -rp "请输入个人推送 Chat ID（不知道可先填0，稍后再改）: " new_chat_id
        [[ -z "$new_chat_id" ]] && new_chat_id="0"
    fi

    # --- node RSS URL ---
    local default_url="https://rss.nodeseek.com/?sortBy=postTime"
    if [ -n "$NS_URL" ]; then
        read -rp "请输入要监控的 node RSS URL [当前: $NS_URL] (回车默认最新帖): " new_url
        [[ -z "$new_url" ]] && new_url="$NS_URL"
    else
        read -rp "请输入要监控的 node RSS URL [默认: $default_url]: " new_url
        [[ -z "$new_url" ]] && new_url="$default_url"
    fi

    # --- 监控间隔（秒）---
    echo ""
    if [ -n "$INTERVAL_SEC" ]; then
        read -rp "请输入监控间隔秒数 [当前: $INTERVAL_SEC]（建议>=60，最低20）: " new_interval
        [[ -z "$new_interval" ]] && new_interval="$INTERVAL_SEC"
    else
        read -rp "请输入监控间隔秒数 [默认: 180]（建议>=60，最低20）: " new_interval
        [[ -z "$new_interval" ]] && new_interval="180"
    fi

    # ✅ 校验：必须是数字，最低允许 20 秒
    if ! [[ "$new_interval" =~ ^[0-9]+$ ]]; then
        new_interval="180"
    fi
    if (( new_interval < 20 )); then
        new_interval="20"
    fi
    INTERVAL_SEC="$new_interval"

    # 写入 cron（直跑，无 flock 包装）
    setup_cron

    # --- 关键词过滤设置 ---
    echo ""
    echo "当前关键词：${KEYWORDS:-未设置}"
    echo "支持写法："
    echo "  - 单关键词：抽奖"
    echo "  - 双关键词AND：车&box   （标题里必须同时包含“车”和“box”）"
    echo ""
    read -rp "是否需要重置关键词？(Y/N): " reset_kw

    if [[ "$reset_kw" =~ ^[Yy]$ ]]; then
        while true; do
            echo "请输入关键词（多个用 , 分隔），示例：抽奖,cloudsilk,车&box"
            read -rp "输入关键词(留空=清空关键词): " new_keywords

            if [[ -z "$new_keywords" ]]; then
                KEYWORDS=""
                echo "关键词已清空。"
                break
            fi

            # 逗号转空格，压缩多余空格
            new_keywords=$(echo "$new_keywords" | sed 's/,/ /g' | awk '{$1=$1; print}')
            kw_count=$(echo "$new_keywords" | wc -w)

            if (( kw_count > 20 )); then
                echo "❌ 关键词数量建议不超过 20 个（当前：$kw_count 个）。请重新输入。"
            else
                KEYWORDS="$new_keywords"
                echo "关键词已更新为：$KEYWORDS"
                break
            fi
        done
    else
        echo "保持原有关键词：${KEYWORDS:-未设置}"
    fi

    TG_BOT_TOKEN="$new_bot_token"
    TG_PUSH_CHAT_ID="$new_chat_id"
    NS_URL="$new_url"
    write_config

    echo ""
    echo -e "${GREEN}✅ 配置已更新并保存成功！${PLAIN}"
    echo ""
    read_config
}

# ============================================
# 抓取 node RSS（带 If-Modified-Since，减少风控概率）
# ============================================
fetch_node_rss() {
    local url="$1"
    local tmp_h="$WORK_DIR/.tmp_headers"
    local tmp_b="$WORK_DIR/.tmp_body"

    local ims_arg=()
    if [[ -s "$LAST_MOD_FILE" ]]; then
        local lm
        lm=$(cat "$LAST_MOD_FILE" 2>/dev/null | tr -d '\r\n')
        [[ -n "$lm" ]] && ims_arg=(-H "If-Modified-Since: $lm")
    fi

    local http_code
    http_code=$(curl -sS --compressed -L \
        -D "$tmp_h" -o "$tmp_b" \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36" \
        -H "Accept: application/rss+xml, application/xml;q=0.9, */*;q=0.8" \
        -H "Accept-Language: zh-CN,zh;q=0.9,en;q=0.8" \
        "${ims_arg[@]}" \
        -w "%{http_code}" \
        "$url" 2>>"$LOG_FILE")

    if [[ "$http_code" == "304" ]]; then
        return 2
    fi

    if [[ "$http_code" != "200" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [node] ❌ RSS请求失败 HTTP=$http_code" >> "$LOG_FILE"
        return 1
    fi

    local new_lm
    new_lm=$(grep -i '^last-modified:' "$tmp_h" | tail -n 1 | sed 's/^[Ll]ast-[Mm]odified:[ ]*//; s/\r//')
    if [[ -n "$new_lm" ]]; then
        echo "$new_lm" > "$LAST_MOD_FILE"
    fi

    cat "$tmp_b"
    return 0
}

# ============================================
# 从 RSS 提取最新帖子（id|title|url）
# ============================================
extract_posts() {
    local xml="$1"

    if echo "$xml" | grep -qiE "Just a moment|cf-turnstile|challenge-platform|captcha"; then
        echo "__BLOCKED__"
        return 0
    fi

    echo "$xml" \
      | tr '\n' ' ' \
      | sed 's/<item/\n<item/g' \
      | awk '
        BEGIN { IGNORECASE=1 }

        /<item/ {
            item=$0
            title=""; link=""; guid=""

            # ✅ title：允许跨行、允许中间有空格
            if (match(item, /<title>[[:space:]]*<!\[CDATA\[.*?\]\]>[[:space:]]*<\/title>/)) {
                t=substr(item, RSTART, RLENGTH)
                sub(/.*<!\[CDATA\[/,"",t)
                sub(/\]\]>.*$/,"",t)
                title=t
            }

            # link
            if (match(item, /<link>[[:space:]]*[^<]+[[:space:]]*<\/link>/)) {
                l=substr(item, RSTART, RLENGTH)
                sub(/.*<link>[[:space:]]*/,"",l)
                sub(/[[:space:]]*<\/link>.*/,"",l)
                link=l
            }

            # guid
            if (match(item, /<guid[^>]*>[[:space:]]*[0-9]+[[:space:]]*<\/guid>/)) {
                g=substr(item, RSTART, RLENGTH)
                sub(/.*>/,"",g)
                sub(/<\/guid>.*/,"",g)
                guid=g
            }

            id=guid
            if (id == "" && link ~ /post-[0-9]+-1/) {
                id=link
                sub(/.*post-/,"",id)
                sub(/-1.*/,"",id)
            }

            if (length(id) > 0 && length(title) > 0 && length(link) > 0) {
                gsub(/^[ \t]+|[ \t]+$/, "", title)
                print id "|" title "|" link
            }
        }
      ' \
      | head -n 120
}

# ============================================
# ✅ 关键词匹配函数
# 规则：
# - KEYWORDS 为空：不匹配
# - token 不含 & ：单关键词（title 包含即可）
# - token 含 & ：双关键词AND（title 必须同时包含左右两部分）
# 返回：
#   echo 匹配到的关键词（用于日志显示），不匹配则 echo 空串
# ============================================
match_title() {
    local title="$1"
    local title_lower
    title_lower=$(echo "$title" | tr 'A-Z' 'a-z')

    [[ -z "$KEYWORDS" ]] && { echo ""; return; }

    local token
    for token in $KEYWORDS; do
        token=$(echo "$token" | awk '{$1=$1;print}')
        [[ -z "$token" ]] && continue

        local token_lower
        token_lower=$(echo "$token" | tr 'A-Z' 'a-z')

        # 双关键词 AND：a&b
        if [[ "$token_lower" == *"&"* ]]; then
            local t
            t=$(echo "$token_lower" | tr -d ' ')
            local a b
            a="${t%%&*}"
            b="${t#*&}"

            [[ -z "$a" || -z "$b" ]] && continue

            if [[ "$title_lower" == *"$a"* && "$title_lower" == *"$b"* ]]; then
                echo "$a&$b"
                return
            fi
        else
            if [[ "$title_lower" == *"$token_lower"* ]]; then
                echo "$token_lower"
                return
            fi
        fi
    done

    echo ""
}

# ============================================
# 手动打印最新帖子标题
# ============================================
print_latest() {
    read_config || return
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${PURPLE} node 最新帖子（缓存）${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"

    local STATE_FILE="$WORK_DIR/last_node.txt"
    if [ ! -s "$STATE_FILE" ]; then
        echo "暂无缓存，请先执行「手动刷新」"
        return
    fi

    echo -e "最新10条（最新在下）："
    local i=1
    tail -n 10 "$STATE_FILE" | while IFS= read -r line; do
        local id title url sent
        id=$(echo "$line"   | awk -F'|' '{print $1}')
        title=$(echo "$line"| awk -F'|' '{print $2}')
        url=$(echo "$line"  | awk -F'|' '{print $3}')
        sent=$(echo "$line" | awk -F'|' '{print $4}')

        [[ -z "$sent" ]] && sent="0"
        local tag="未推送"
        [[ "$sent" == "1" ]] && tag="已推送"

        echo "${i}) [$id] ($tag) $title"
        echo "    $url"
        ((i++))
    done
}

# ============================================
# 手动刷新：抓取最新帖子并更新缓存（✅稳定排序版）
# ============================================
manual_fresh() {
    read_config || return
    local STATE_FILE="$WORK_DIR/last_node.txt"
    [[ -f "$STATE_FILE" ]] || touch "$STATE_FILE"

    local xml
    xml=$(fetch_node_rss "$NS_URL")
    local rc=$?

    if [[ $rc -eq 2 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [node] ℹ️ RSS未更新（304 Not Modified）" >> "$LOG_FILE"
        return
    fi
    if [[ $rc -ne 0 || -z "$xml" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [node] ❌ 获取RSS失败或为空" >> "$LOG_FILE"
        return
    fi

    local posts
    posts=$(extract_posts "$xml")

    if [[ "$posts" == "__BLOCKED__" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [node] ⚠️ 可能被挑战页拦截" >> "$LOG_FILE"
        return
    fi
    if [[ -z "$posts" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [node] ❌ 未提取到帖子" >> "$LOG_FILE"
        return
    fi

    local NP_FILE="$WORK_DIR/.tmp_newposts"
    printf "%s\n" "$posts" > "$NP_FILE"

    awk -F'|' 'BEGIN{OFS="|"}
    FNR==NR{
        if (NF < 3 || $1 == "") next
        id=$1
        new_title[id]=$2
        new_url[id]=$3
        next
    }
    {
        if (NF < 3 || $1 == "") next
        id=$1

        old_sent="0"
        if (NF >= 4 && $4 ~ /^[01]$/) old_sent=$4

        title=$2
        url=$3

        if (id in new_title) {
            title=new_title[id]
            url=new_url[id]
        }

        final_title[id]=title
        final_url[id]=url
        sent[id]=old_sent
    }
    END{
        for (id in new_title) {
            if (!(id in final_title)) {
                final_title[id]=new_title[id]
                final_url[id]=new_url[id]
                sent[id]="0"
            }
        }
        for (id in final_title) {
            print id, final_title[id], final_url[id], sent[id]
        }
    }' "$NP_FILE" "$STATE_FILE" \
    | LC_ALL=C sort -n -t'|' -k1,1 \
    | tail -n 200 > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    rm -f "$NP_FILE"

    echo "$(date '+%Y-%m-%d %H:%M:%S') [node] ✅ 缓存更新完成（严格去重，保留sent标记，稳定排序，最新200条）" >> "$LOG_FILE"
}

# ============================================
# 手动推送（关键词匹配）
# ============================================
manual_push() {
    read_config || return

    local STATE_FILE="$WORK_DIR/last_node.txt"
    if [[ ! -s "$STATE_FILE" ]]; then
        echo "❌ 无缓存文件，请先手动更新（刷新缓存）"
        return
    fi

    if [[ -z "$KEYWORDS" ]]; then
        echo "❌ 未设置关键词，跳过推送"
        return
    fi

    local lines=()
    while IFS= read -r line; do lines+=("$line"); done < "$STATE_FILE"

    local total=${#lines[@]}
    local start=$(( total > 20 ? total - 20 : 0 ))
    local matched=()

    for ((i=start; i<total; i++)); do
        local id title url
        id=$(echo "${lines[$i]}" | awk -F'|' '{print $1}')
        title=$(echo "${lines[$i]}" | awk -F'|' '{print $2}')
        url=$(echo "${lines[$i]}" | awk -F'|' '{print $3}')

        local hit
        hit=$(match_title "$title")
        if [[ -n "$hit" ]]; then
            matched+=("${id}|${title}|${url}|${hit}")
        fi
    done

    if [[ ${#matched[@]} -eq 0 ]]; then
        echo "⚠️ 无匹配关键词帖子"
        return
    fi

    local now_t
    now_t=$(fmt_time)

    local push_text=""
    for x in "${matched[@]}"; do
        local id title url hit
        id=$(echo "$x" | awk -F'|' '{print $1}')
        title=$(echo "$x" | awk -F'|' '{print $2}')
        url=$(echo "$x" | awk -F'|' '{print $3}')
        hit=$(echo "$x" | awk -F'|' '{print $4}')

        push_text+=$'🎯node:【'"${hit}"'】\n'
        push_text+=$'📆时间: '"${now_t}"$'\n'
        push_text+=$'🔖标题: '"${title}"$'\n'
        push_text+=$'🧬链接: '"${url}"$'\n\n'
    done

    tg_send "$push_text"
    echo "✅ 推送完成（匹配 ${#matched[@]} 条）"
}

# ============================================
# 自动推送（cron）—— 匹配关键词且只推送一次（✅稳定排序版）
# ============================================
auto_push() {
    read_config || return

    local STATE_FILE="$WORK_DIR/last_node.txt"
    if [[ ! -s "$STATE_FILE" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [node] ⚠️无缓存文件，跳过自动推送" >> "$LOG_FILE"
        return
    fi

    if [[ -z "$KEYWORDS" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [node] ⚠️无关键词，跳过自动推送" >> "$LOG_FILE"
        return
    fi

    local lines=()
    while IFS= read -r line; do lines+=("$line"); done < "$STATE_FILE"

    local total=${#lines[@]}
    local start=$(( total > 30 ? total - 30 : 0 ))

    local nowlog
    nowlog=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$nowlog [node] 当前关键词：$KEYWORDS" >> "$LOG_FILE"
    echo "$nowlog [node] 最新30条帖子匹配情况如下：" >> "$LOG_FILE"

    local now_t
    now_t=$(fmt_time)

    local push_text=""
    local ids_to_mark=()

    for ((i=start; i<total; i++)); do
        local id title url sent
        id=$(echo "${lines[$i]}"   | awk -F'|' '{print $1}')
        title=$(echo "${lines[$i]}"| awk -F'|' '{print $2}')
        url=$(echo "${lines[$i]}"  | awk -F'|' '{print $3}')
        sent=$(echo "${lines[$i]}" | awk -F'|' '{print $4}')

        [[ -z "$sent" ]] && sent="0"

        if [[ "$sent" == "1" ]]; then
            echo "$nowlog [node] 已推送过（跳过）：[$id] $title" >> "$LOG_FILE"
            continue
        fi

        local hit
        hit=$(match_title "$title")

        if [[ -n "$hit" ]]; then
            echo "$nowlog [node] 匹配 ✔：[$id] $title（命中：$hit）" >> "$LOG_FILE"

            push_text+="🎯node:【${hit}】"$'\n'
            push_text+="📆时间: ${now_t}"$'\n'
            push_text+="🔖标题: ${title}"$'\n'
            push_text+="🧬链接: ${url}"$'\n\n'

            ids_to_mark+=("$id")
        else
            echo "$nowlog [node] 未匹配 ✖：[$id] $title" >> "$LOG_FILE"
        fi
    done

    if [[ ${#ids_to_mark[@]} -eq 0 ]]; then
        echo "$nowlog [node] ⚠️无匹配或均已推送过" >> "$LOG_FILE"
        return
    fi

    tg_send "$push_text"

    awk -F'|' -v OFS='|' -v ids="$(printf "%s," "${ids_to_mark[@]}")" '
      BEGIN{
        split(ids, a, ",")
        for (i in a) if (a[i]!="") mark[a[i]]=1
      }
      {
        id=$1; title=$2; url=$3; sent=(NF>=4?$4:0)
        if (id in mark) sent=1
        print id, title, url, sent
      }
    ' "$STATE_FILE" \
    | LC_ALL=C sort -n -t'|' -k1,1 \
    | tail -n 100 > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    echo "$nowlog [node] 📩 自动推送成功（${#ids_to_mark[@]} 条），已在 last_node.txt 标记 sent=1（稳定排序）" >> "$LOG_FILE"
}

# ============================================
# 测试 Telegram 推送（真换行）
# ============================================
test_notification() {
    read_config || return

    local now_t
    now_t=$(fmt_time)

    local msg=""
    msg+=$'🎯node\n'
    msg+=$'📆时间: '"${now_t}"$'\n'
    msg+=$'🔖标题: 这是来自脚本的测试推送\n'
    msg+=$'🧬链接: https://www.nodeseek.com/?sortBy=postTime'

    tg_send "$msg"
    echo -e "${GREEN}✅ Telegram 测试推送已发送（请到私聊查看）${PLAIN}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ Telegram 测试推送已发送" >> "$LOG_FILE"
}

# ============================================
# 日志清理（不归档）：每天 0 点只清空一次，保证日志体积
# ============================================
log_rotate() {
    local files=("$LOG_FILE" "$CRON_LOG")
    local today
    today=$(date +%Y-%m-%d)

    local state_file="$WORK_DIR/.log_last_reset_day"
    local last_reset=""

    [[ -f "$state_file" ]] && last_reset=$(cat "$state_file" 2>/dev/null | tr -d '\r\n')

    if [[ "$last_reset" != "$today" ]]; then
        for f in "${files[@]}"; do
            [[ -f "$f" ]] || touch "$f"
            : > "$f"
        done
        echo "$today" > "$state_file"
    fi
}

# ============================================
# 设置定时任务（cron 每分钟触发一次，脚本内部自循环）
# ============================================
setup_cron() {
    local entry="* * * * * /root/TrafficCop/node.sh -cron"
    echo "🛠 正在检查并更新 node 定时任务（cron直跑，无 flock 包装）..."

    crontab -l 2>/dev/null \
        | grep -v "node.sh -cron" \
        | grep -v "/usr/bin/flock -n /tmp/node.lock" \
        > /tmp/cron.node.tmp || true

    {
        cat /tmp/cron.node.tmp
        echo "$entry"
    } | crontab -

    rm -f /tmp/cron.node.tmp
    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ node cron 已更新为：$entry" | tee -a "$CRON_LOG"
}

# ============================================
# 关闭定时任务（杀掉常驻 -cron 进程 + 从 crontab 移除）
# ============================================
stop_cron() {
    echo -e "${YELLOW}⏳ 正在停止 node 定时任务...${PLAIN}"

    pkill -f "node.sh -cron" 2>/dev/null || true
    sleep 1
    pkill -f "node.sh -cron" 2>/dev/null || true

    crontab -l 2>/dev/null \
        | grep -v "node.sh -cron" \
        | grep -v "/usr/bin/flock -n /tmp/node.lock" \
        | crontab - 2>/dev/null

    echo -e "${GREEN}✔ 已从 crontab 中移除 node 定时任务${PLAIN}"
    systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null
    echo -e "${GREEN}✔ node 定时监控已完全停止${PLAIN}"
}

# ============================================
# cron 模式：按配置间隔执行 manual_fresh + auto_push
# 内置 flock 锁，避免重复启动
# ============================================
if [[ "$1" == "-cron" ]]; then
    LOCK_FILE="$WORK_DIR/.node.lock"
    exec 200>"$LOCK_FILE"
    flock -n 200 || exit 0

    read_config >/dev/null 2>&1 || true
    INTERVAL=${INTERVAL_SEC:-180}
    if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]]; then
        INTERVAL=180
    fi
    if (( INTERVAL < 20 )); then
        INTERVAL=20
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') 🚀 定时任务已启动（每${INTERVAL}秒执行 manual_fresh + auto_push）" >> "$CRON_LOG"

    while true; do
        start_ts=$(date +%s)

        log_rotate

        trim_file() {
            local file="$1"
            local max_lines=200
            [[ -f "$file" ]] || return
            local cnt
            cnt=$(wc -l < "$file")
            if (( cnt > max_lines )); then
                tail -n "$max_lines" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
            fi
        }

        trim_file "$CRON_LOG"
        trim_file "$LOG_FILE"
        trim_file "$WORK_DIR/last_node.txt"

        echo "$(date '+%Y-%m-%d %H:%M:%S') ▶️ 执行 manual_fresh()" >> "$CRON_LOG"
        manual_fresh >/dev/null 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ manual_fresh() 执行完成" >> "$CRON_LOG"

        echo "$(date '+%Y-%m-%d %H:%M:%S') ▶️ 执行 auto_push()" >> "$CRON_LOG"
        auto_push >/dev/null 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ auto_push() 执行完成" >> "$CRON_LOG"

        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))
        sleep_time=$((INTERVAL - elapsed))
        (( sleep_time < 1 )) && sleep_time=1

        echo "$(date '+%Y-%m-%d %H:%M:%S') 📆 等待${sleep_time}秒进入下次周期..." >> "$CRON_LOG"
        echo "" >> "$CRON_LOG"

        sleep "$sleep_time"
    done
    exit 0
fi

# ============================================
# 主菜单
# ============================================
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${PURPLE} node 监控管理菜单 ${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 安装/修改配置"
        echo -e "${GREEN}2.${PLAIN} 打印最新帖子"
        echo -e "${GREEN}3.${PLAIN} 推送最新帖子"
        echo -e "${GREEN}4.${PLAIN} 推送测试消息"
        echo -e "${GREEN}5.${PLAIN} 手动刷新"
        echo -e "${RED}6.${PLAIN} 清除cron任务"
        echo -e "${WHITE}0.${PLAIN} 退出"
        echo -e "${BLUE}======================================${PLAIN}"
        read -rp "请选择操作 [0-6]: " choice
        echo
        case $choice in
            1) initial_config; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            2) print_latest; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            3) manual_push; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            4) test_notification; echo -e "${GREEN}操作完成。${PLAIN}" ;;
            5) manual_fresh; echo -e "${GREEN}手动更新完成。${PLAIN}" ;;
            6) stop_cron; echo -e "${GREEN}停止cron任务完成。${PLAIN}" ;;
            0) exit 0 ;;
            *) echo "无效选项"; echo -e "${GREEN}操作完成。${PLAIN}" ;;
        esac
        read -p "按 Enter 返回菜单..."
    done
}

main_menu
