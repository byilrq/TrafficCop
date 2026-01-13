#!/bin/bash
# TrafficCop 管理器 - 交互式管理工具
# 版本 1.0

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

# 安装PushPlus通知
install_pushplus() {
    echo -e "${CYAN}正在安装PushPlus通知功能...${NC}"
    install_script "pushplus.sh"
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
    
    local scripts=("trafficcop.sh" "tg_push.sh" "pushplus.sh" "node.sh" 
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

# ============================================
# 读取当前总流量（与 trafficcop.sh 口径一致：all-time 字段 13/14/15）
# - 读取 traffic_config.txt（仅解析 KEY=VALUE）
# - 读取 traffic_offset.dat
# - vnstat --oneline b 使用 all-time：
#   in=13 out=14 total=15
# - 输出统一格式：0.000（始终三位小数）
# ============================================
Traffic_all() {
    local config_file="$WORK_DIR/traffic_config.txt"
    local offset_file="$WORK_DIR/traffic_offset.dat"

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}找不到流量监控配置文件：$config_file${NC}"
        echo -e "请先运行一次 ${YELLOW}流量监控安装/配置（菜单 1）${NC}"
        return 1
    fi

    # 只解析 KEY=VALUE，避免中文/空格/杂项导致 source 失败
    # shellcheck disable=SC1090
    source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$config_file" | sed 's/\r$//') 2>/dev/null || {
        echo -e "${RED}配置加载失败（可能包含非法行）：$config_file${NC}"
        return 1
    }

    TRAFFIC_MODE=${TRAFFIC_MODE:-total}
    TRAFFIC_PERIOD=${TRAFFIC_PERIOD:-monthly}
    PERIOD_START_DAY=${PERIOD_START_DAY:-1}
    MAIN_INTERFACE=${MAIN_INTERFACE:-eth0}

    local offset
    offset=$(cat "$offset_file" 2>/dev/null || echo 0)
    [[ "$offset" =~ ^-?[0-9]+$ ]] || offset=0

    vnstat -u -i "$MAIN_INTERFACE" >/dev/null 2>&1

    local line raw_bytes rx tx
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>/dev/null || echo "")

    if [ -z "$line" ] || ! echo "$line" | grep -q ';'; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 输出无效（接口：$MAIN_INTERFACE），暂按 0GB 处理。"
        raw_bytes=0
    else
        case "$TRAFFIC_MODE" in
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
            *) raw_bytes=0 ;;
        esac
    fi

    [[ "$raw_bytes" =~ ^[0-9]+$ ]] || raw_bytes=0

    local real_bytes=$((raw_bytes - offset))
    [ "$real_bytes" -lt 0 ] && real_bytes=0

    # ✅ 统一格式：始终输出 3 位小数
    local usage_gb
    usage_gb=$(echo "$real_bytes/1024/1024/1024" | bc -l 2>/dev/null)
    usage_gb=$(printf "%.3f" "${usage_gb:-0}")

    # ✅ 再兜底一次：防止出现 ".355"
    [[ "$usage_gb" == .* ]] && usage_gb="0$usage_gb"

    # 周期起始（简化版）
    local y m d period_start
    y=$(date +%Y); m=$(date +%m); d=$(date +%d)
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
        *) period_start=$(date -d "$y-$m-${PERIOD_START_DAY:-1}" +%Y-%m-%d) ;;
    esac

    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前周期: ${period_start} 起（按 $TRAFFIC_PERIOD 统计）"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 统计模式: $TRAFFIC_MODE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前流量使用: $usage_gb GB"
    echo "$(date '+%Y-%m-%d %H:%M:%S') DEBUG: raw_bytes(all-time)=$raw_bytes offset=$offset real_bytes=$real_bytes iface=$MAIN_INTERFACE"
}

# ======================================================
# 手动设置已用流量（管理脚本版本，口径与 trafficcop.sh 一致）
# - 使用 vnstat all-time 字段：in=13 out=14 total=15
# - offset = raw_all_time_bytes - target_bytes
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

    local config_file="$WORK_DIR/traffic_config.txt"
    local offset_file="$WORK_DIR/traffic_offset.dat"
    local log_file="$WORK_DIR/traffic.log"

    if [ ! -f "$config_file" ]; then
        echo "错误：找不到配置文件 $config_file，请先在菜单[1]完成流量监控安装/配置。"
        return 1
    fi

    # 只解析 KEY=VALUE，避免中文/空格/杂项导致 source 失败
    # shellcheck disable=SC1090
    source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$config_file" | sed 's/\r$//') 2>/dev/null || {
        echo "错误：配置加载失败（可能包含非法行）：$config_file"
        return 1
    }

    TRAFFIC_MODE=${TRAFFIC_MODE:-total}
    MAIN_INTERFACE=${MAIN_INTERFACE:-eth0}

    if [ -z "$MAIN_INTERFACE" ] || [ -z "$TRAFFIC_MODE" ]; then
        echo "错误：未能获取 MAIN_INTERFACE / TRAFFIC_MODE，请先在菜单[1]完成配置。"
        return 1
    fi

    # 强制刷新 vnstat 数据库，避免读到旧值
    vnstat -u -i "$MAIN_INTERFACE" >/dev/null 2>&1

    local line raw_bytes rx tx target_bytes new_offset
    line=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>&1 || echo "")

    # vnstat 没数据/未就绪：raw_bytes 按 0 处理（允许写负 offset）
    if echo "$line" | grep -qiE "Not enough data available yet|No data\. Timestamp of last update is same"; then
        raw_bytes=0
    else
        # 其它异常：必须是包含 ';' 的 oneline 数据
        if [ -z "$line" ] || ! echo "$line" | grep -q ';'; then
            echo "vnstat 输出无效，无法计算 raw_bytes：$line"
            echo "$(date '+%Y-%m-%d %H:%M:%S') flow_setting：vnstat 输出无效($line)，放弃修改 OFFSET_FILE" | tee -a "$log_file"
            return 1
        fi

        # ✅ 关键：使用 all-time 字段（与 trafficcop.sh 一致）
        raw_bytes=0
        case "$TRAFFIC_MODE" in
            out)
                raw_bytes=$(echo "$line" | cut -d';' -f14)   # all-time tx
                ;;
            in)
                raw_bytes=$(echo "$line" | cut -d';' -f13)   # all-time rx
                ;;
            total)
                raw_bytes=$(echo "$line" | cut -d';' -f15)   # all-time total
                ;;
            max)
                rx=$(echo "$line" | cut -d';' -f13)
                tx=$(echo "$line" | cut -d';' -f14)
                rx=${rx:-0}; tx=${tx:-0}
                [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
                [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
                raw_bytes=$((rx > tx ? rx : tx))
                ;;
            *)
                raw_bytes=$(echo "$line" | cut -d';' -f15)
                ;;
        esac
    fi

    raw_bytes=${raw_bytes:-0}
    if ! [[ "$raw_bytes" =~ ^[0-9]+$ ]]; then
        echo "vnstat 返回的累计流量不是纯数字(raw_bytes=$raw_bytes)，放弃修改。"
        echo "$(date '+%Y-%m-%d %H:%M:%S') flow_setting：raw_bytes 异常($raw_bytes)，放弃修改 OFFSET_FILE" | tee -a "$log_file"
        return 1
    fi

    # real_gb -> bytes（1024^3）
    target_bytes=$(echo "$real_gb * 1024 * 1024 * 1024" | bc 2>/dev/null | cut -d'.' -f1)
    target_bytes=${target_bytes:-0}
    [[ "$target_bytes" =~ ^[0-9]+$ ]] || target_bytes=0

    # offset = 当前 all-time 累计 - 目标本周期用量
    # 后续显示：已用 = 当前 all-time - offset ≈ real_gb
    new_offset=$((raw_bytes - target_bytes))

    echo "$new_offset" > "$offset_file"

    echo "--------------------------------------"
    echo "当前累计流量 raw_bytes(all-time): $raw_bytes bytes"
    echo "设定本周期使用量            : $real_gb GB"
    echo "目标字节 target_bytes        : $target_bytes bytes"
    echo "新的 offset                 : $new_offset"
    echo "（后续统计：已用 = 当前累计 - offset，将从 ${real_gb}GB 附近开始往上增长）"
    echo "--------------------------------------"
    echo "$(date '+%Y-%m-%d %H:%M:%S') flow_setting：手动设置 OFFSET_FILE=$new_offset（对应本周期已用 $real_gb GB）" | tee -a "$log_file"

    return 0
}
# ======================================================
# IP 域名禁止访问功能
# ======================================================
ip_ban() {
  set -euo pipefail

  # ===== 可按需调整 =====
  local LIST_DIR="/etc/xray"
  local BAN_LIST="${LIST_DIR}/banned_domains.txt"
  local RULE_TAG="ip_ban_block_domains"
  local BLOCK_OUT_TAG="block"
  # Xray 配置路径：按常见路径自动探测
  local XRAY_CONFIG="${XRAY_CONFIG:-}"
  # =====================

  _need_root() { [[ "${EUID}" -eq 0 ]] || { echo "[ip_ban] 需要 root 执行"; return 1; }; }
  _need_cmd()  { command -v "$1" >/dev/null 2>&1 || { echo "[ip_ban] 缺少命令：$1"; return 1; }; }

  _normalize_domain() {
    local d="$1"
    d="${d#http://}"; d="${d#https://}"
    d="${d%%/*}"; d="${d%%:*}"
    d="$(echo "$d" | tr -d '[:space:]')"
    echo "$d"
  }

  _detect_config() {
    if [[ -n "$XRAY_CONFIG" && -f "$XRAY_CONFIG" ]]; then return 0; fi
    for p in /usr/local/etc/xray/config.json /etc/xray/config.json /etc/xray/xray.json; do
      if [[ -f "$p" ]]; then XRAY_CONFIG="$p"; return 0; fi
    done
    echo "[ip_ban] 未找到 Xray config.json。请设置环境变量 XRAY_CONFIG=/path/to/config.json" >&2
    return 1
  }

  _ensure_list_file() {
    mkdir -p "$LIST_DIR"
    touch "$BAN_LIST"
  }

  _restart_xray() {
    if command -v systemctl >/dev/null 2>&1; then
      systemctl restart xray 2>/dev/null || systemctl restart xray.service
    else
      service xray restart
    fi
  }

  _apply_to_xray_config() {
    _need_cmd jq
    _detect_config
    _ensure_list_file

    # 生成 domain 列表：["domain:example.com", ...]
    local domains_json
    domains_json="$(grep -vE '^\s*($|#)' "$BAN_LIST" \
      | sed 's/[[:space:]]//g' \
      | awk 'NF{print "domain:"$0}' \
      | jq -R . | jq -s 'unique')"

    # 备份
    cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

    # 更新配置：
    # 1) 确保存在 blackhole outbound tag=block
    # 2) 确保 routing.rules 中存在我们这条规则（放在最前，优先匹配）
    # 3) 确保 inbounds 开启 sniffing（用于识别 SNI/Host；否则“按域名”无法可靠生效）
    jq \
      --arg rt "$RULE_TAG" \
      --arg bot "$BLOCK_OUT_TAG" \
      --argjson domains "$domains_json" \
      '
      .outbounds = (.outbounds // []) |
      (if ([.outbounds[]? | select(.tag==$bot)] | length) == 0
       then .outbounds += [{"protocol":"blackhole","tag":$bot}]
       else .
       end) |

      .routing = (.routing // {}) |
      .routing.rules = (.routing.rules // []) |

      # 删除旧同名 ruleTag，再插入新规则到最前
      .routing.rules = ([.routing.rules[]? | select((.ruleTag // "") != $rt)]
                        | [{"type":"field","ruleTag":$rt,"domain":$domains,"outboundTag":$bot}] + .) |

      # 尽量确保 sniffing 打开（对按域名生效很关键）
      .inbounds = (.inbounds // []) |
      .inbounds |= (map(
        .sniffing = (.sniffing // {}) |
        .sniffing.enabled = true |
        .sniffing.destOverride = ((.sniffing.destOverride // []) + ["http","tls"] | unique)
      ))
      ' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"

    mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

    # 如果封禁列表为空，也保留规则（domain=[] 时相当于不拦截）
    _restart_xray

    echo "[ip_ban] 已更新 Xray 配置并重启。配置文件：$XRAY_CONFIG"
    echo "[ip_ban] 封禁列表：$BAN_LIST"
  }

  _add_domains() {
    _ensure_list_file
    local input="$1"
    input="$(echo "$input" | tr ',' ' ')"
    local added=0
    for x in $input; do
      local d="$(_normalize_domain "$x")"
      [[ -n "$d" ]] || continue
      if ! grep -qxF "$d" "$BAN_LIST" 2>/dev/null; then
        echo "$d" >> "$BAN_LIST"
        added=$((added+1))
      fi
    done
    echo "[ip_ban] 已添加 $added 个域名到封禁列表。"
    _apply_to_xray_config
  }

  _remove_domains() {
    _ensure_list_file
    local input="$1"
    input="$(echo "$input" | tr ',' ' ')"
    local removed=0
    for x in $input; do
      local d="$(_normalize_domain "$x")"
      [[ -n "$d" ]] || continue
      if grep -qxF "$d" "$BAN_LIST" 2>/dev/null; then
        sed -i "\#^${d}\$#d" "$BAN_LIST"
        removed=$((removed+1))
      fi
    done
    echo "[ip_ban] 已撤销 $removed 个域名的封禁。"
    _apply_to_xray_config
  }

  _need_root || return 1

  # ===== 菜单（你要求的两项）=====
  while true; do
    echo
    echo "================= Xray 域名访问控制（ip_ban） ================="
    echo "1) 设置域名禁止访问"
    echo "2) 撤销禁止访问"
    echo "0) 退出"
    echo "==============================================================="
    read -r -p "请选择 [0-2]: " choice

    case "${choice:-}" in
      1)
        read -r -p "输入要禁止访问的域名（空格或逗号分隔）: " domains
        [[ -n "${domains// /}" ]] || { echo "[ip_ban] 未输入域名。"; continue; }
        _add_domains "$domains"
        ;;
      2)
        read -r -p "输入要撤销的域名（空格或逗号分隔）: " domains
        [[ -n "${domains// /}" ]] || { echo "[ip_ban] 未输入域名。"; continue; }
        _remove_domains "$domains"
        ;;
      0)
        echo "[ip_ban] 已退出。"
        break
        ;;
      *)
        echo "[ip_ban] 无效选项：$choice"
        ;;
    esac
  done
}

# ======================================================
# 安装 / 管理 node 监控通知
# ======================================================
install_node() {
    echo -e "${CYAN}正在安装 node 监控脚本...${NC}"

    local file="node.sh"
    local url="https://raw.githubusercontent.com/byilrq/TrafficCop/main/node.sh"
    local dest="$WORK_DIR/$file"

    echo -e "${BLUE}➡ 下载 node.sh ...${NC}"
    curl -fsSL "$url" -o "$dest"

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}❌ 下载失败，请检查网络或 GitHub 链接。${NC}"
        read -p "按回车继续..."
        return
    fi

    chmod +x "$dest"
    echo -e "${GREEN}✔ node.sh 安装完成${NC}"

    echo -e "${CYAN}➡ 运行 node 配置管理...${NC}"
    bash "$dest"

    echo -e "${GREEN}✔ node 监控功能已启动！${NC}"
    read -p "按回车继续..."
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
    echo -e "${YELLOW}4) 安装/管理node监控${NC}"  
    echo -e "${YELLOW}5) 查看配置${NC}"
    echo -e "${YELLOW}6) 实时流量${NC}" 
    echo -e "${YELLOW}7) 补偿流量${NC}" 
    echo -e "${RED}8) 停止服务${NC}"
    echo -e "${BLUE}9) 更新脚本${NC}"
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
        read -p "请选择操作 [0-9]: " choice
        
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
                install_node
                ;;                  
            5)
                view_config
                ;;
            6)
                Traffic_all
                ;;    
            7)
                flow_setting
                ;;              
            8)
                stop_all_services
                ;;
            9)
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
