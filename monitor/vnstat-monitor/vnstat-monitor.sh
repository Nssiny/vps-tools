#!/usr/bin/env bash
#
# vnstat-monitor.sh
# Monitors VPS traffic, updates Telegram, and shuts down on threshold.
#
# 用法:
#   vnstat-monitor                  # 立即检查一次（systemd timer / 手动）
#   sudo vnstat-monitor setup       # 交互式设置触发频率并安装 systemd timer（替代 crontab）
#   sudo vnstat-monitor install-timer [分钟]   # 安装/更新 timer（默认用配置 INTERVAL_MINUTES）
#   sudo vnstat-monitor set-interval <分钟>    # 修改频率并重载 timer（持久化到配置）
#   sudo vnstat-monitor timer-status           # 查看 timer 状态
#   sudo vnstat-monitor uninstall-timer        # 移除 timer 与 service（保留配置）
#   vnstat-monitor help            # 显示用法

# ============ 子命令分发（timer 管理，不依赖监控依赖） ============
CMD="${1:-}"
case "$CMD" in
  setup|install-timer|set-interval|timer-status|uninstall-timer|help|-h|--help)
    # 需要 root 的 timer 操作
    if [[ "$CMD" == "setup" || "$CMD" == "install-timer" || "$CMD" == "set-interval" || "$CMD" == "uninstall-timer" ]]; then
      [[ "$(id -u)" -eq 0 ]] || { echo "Error: 需要 root 权限，请用: sudo $0 $*" >&2; exit 1; }
    fi
    vnstat_timer_cmd "$@"
    exit $?
    ;;
esac

CONFIG_FILE="${CONFIG_FILE:-/etc/vnstat-monitor.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file $CONFIG_FILE not found."
    exit 1
fi
source "$CONFIG_FILE"

# 设定默认值
VPS_NAME="${VPS_NAME:-"未命名服务器"}"
TOTAL_GB="${TOTAL_GB:-0}"
OFFSET_GB="${OFFSET_GB:-0}"
SHUTDOWN_PERCENT="${SHUTDOWN_PERCENT:-95}"

# 1. 依赖检查与自动安装（2026-08-08：缺依赖自动装，失败才报错退出）
MISSING_CMDS=()
for cmd in vnstat jq curl ip awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_CMDS+=("$cmd")
    fi
done

if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then
    echo "缺少依赖: ${MISSING_CMDS[*]}，尝试自动安装..."

    # 命令 → 包名映射（发行版差异）
    pkg_for() {  # $1=cmd
        case "$1" in
            ip)
                if [[ "$PKG_MGR" == "apt-get" ]]; then
                    echo "iproute2"     # Debian/Ubuntu
                else
                    echo "iproute"      # RHEL/CentOS/Alma/Rocky
                fi
                ;;
            awk) echo "gawk" ;;         # Debian 默认 mawk 亦可用，装 gawk 更稳
            *)   echo "$1" ;;
        esac
    }

    # 包管理器探测
    PKG_MGR=""
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt-get"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    fi
    if [[ -z "$PKG_MGR" ]]; then
        echo "Error: 不支持的包管理器（apt-get/dnf/yum 均不可用），请手动安装: ${MISSING_CMDS[*]}"
        exit 1
    fi

    # root 检测：非 root 且有 sudo 则用 sudo
    SUDO=""
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            echo "Error: 需要 root 权限安装依赖（当前非 root 且无 sudo），请手动安装: ${MISSING_CMDS[*]}"
            exit 1
        fi
    fi

    # 组装包名并安装
    PKGS=()
    for cmd in "${MISSING_CMDS[@]}"; do
        PKGS+=("$(pkg_for "$cmd")")
    done
    echo "安装: ${PKGS[*]} (via $PKG_MGR)"
    if [[ "$PKG_MGR" == "apt-get" ]]; then
        $SUDO apt-get update -y >/dev/null 2>&1 || { echo "Error: apt-get update 失败"; exit 1; }
        $SUDO apt-get install -y "${PKGS[@]}" || { echo "Error: 依赖安装失败"; exit 1; }
    else
        $SUDO "$PKG_MGR" install -y "${PKGS[@]}" || { echo "Error: 依赖安装失败"; exit 1; }
    fi

    # 安装后复查
    for cmd in "${MISSING_CMDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' 安装后仍不可用，请手动安装。"
            exit 1
        fi
    done
    echo "依赖安装完成。"
fi

# 2. 自动检测网卡
if [[ -z "$INTERFACE" || "$INTERFACE" == "auto" ]]; then
    INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$INTERFACE" ]]; then
        echo "Error: Could not auto-detect network interface."
        exit 1
    fi
fi

# 3. 自动配置 vnstat 流量重置日
if [[ -n "$RESET_DAY" && "$RESET_DAY" =~ ^[0-9]+$ ]]; then
    if (( RESET_DAY >= 1 && RESET_DAY <= 28 )); then
        CUR_ROTATE=$(awk '/^MonthRotate/ {print $2}' /etc/vnstat.conf 2>/dev/null)
        if [[ "$CUR_ROTATE" != "$RESET_DAY" && -f /etc/vnstat.conf ]]; then
            if grep -q "^#MonthRotate" /etc/vnstat.conf; then
                sed -i "s/^#MonthRotate.*/MonthRotate $RESET_DAY/" /etc/vnstat.conf
            elif grep -q "^MonthRotate" /etc/vnstat.conf; then
                sed -i "s/^MonthRotate.*/MonthRotate $RESET_DAY/" /etc/vnstat.conf
            else
                echo "MonthRotate $RESET_DAY" >> /etc/vnstat.conf
            fi
            systemctl restart vnstat || service vnstat restart
            sleep 2 # 等待守护进程刷新数据库
        fi
    fi
fi

# 4. 从 vnstat 获取 JSON 数据
JSON_OUT=$(vnstat -i "$INTERFACE" --json 2>/dev/null)
if [[ $? -ne 0 || -z "$JSON_OUT" ]]; then
    echo "Error: Failed to fetch data from vnstat for interface $INTERFACE."
    exit 1
fi

LATEST_MONTH=$(echo "$JSON_OUT" | jq -c '.interfaces[0].traffic.month // [] | sort_by(.date.year, .date.month) | last' 2>/dev/null)

if [[ "$LATEST_MONTH" == "null" || -z "$LATEST_MONTH" ]]; then
    RX_BYTES=0
    TX_BYTES=0
    BILLING_YEAR=$(date +%Y)
    BILLING_MONTH=$(date +%-m)
else
    RX_BYTES=$(echo "$LATEST_MONTH" | jq -r '.rx')
    TX_BYTES=$(echo "$LATEST_MONTH" | jq -r '.tx')
    BILLING_YEAR=$(echo "$LATEST_MONTH" | jq -r '.date.year')
    BILLING_MONTH=$(echo "$LATEST_MONTH" | jq -r '.date.month')
    
    if [[ "$RX_BYTES" == "null" ]]; then RX_BYTES=0; fi
    if [[ "$TX_BYTES" == "null" ]]; then TX_BYTES=0; fi
fi

# 5. 根据设定的模式计算原始流量
case "$CALC_MODE" in
    in)    RAW_USED_BYTES=$RX_BYTES ;;
    out)   RAW_USED_BYTES=$TX_BYTES ;;
    max)   RAW_USED_BYTES=$(( RX_BYTES > TX_BYTES ? RX_BYTES : TX_BYTES )) ;;
    both|*) RAW_USED_BYTES=$(( RX_BYTES + TX_BYTES )) ;;
esac

# 6. 计算已用流量与进度条
TOTAL_BYTES=$(awk -v gb="$TOTAL_GB" 'BEGIN {printf "%.0f", gb * 1024 * 1024 * 1024}')
OFFSET_BYTES=$(awk -v gb="$OFFSET_GB" 'BEGIN {printf "%.0f", gb * 1024 * 1024 * 1024}')

# 应用偏移量校准
USED_BYTES=$(awk -v used="$RAW_USED_BYTES" -v offset="$OFFSET_BYTES" 'BEGIN { val = used + offset; if (val < 0) val = 0; printf "%.0f", val }')
USED_GB=$(awk -v b="$USED_BYTES" 'BEGIN {printf "%.2f", b / (1024 * 1024 * 1024)}')
RX_GB=$(awk -v b="$RX_BYTES" 'BEGIN {printf "%.2f", b / (1024 * 1024 * 1024)}')
TX_GB=$(awk -v b="$TX_BYTES" 'BEGIN {printf "%.2f", b / (1024 * 1024 * 1024)}')

MSG_EMOJI="🟢"
IS_UNLIMITED=false
if awk -v t="$TOTAL_GB" 'BEGIN { exit (t == 0 ? 0 : 1) }'; then
    IS_UNLIMITED=true
fi

if [[ "$IS_UNLIMITED" == "true" ]]; then
    PROGRESS_SECTION=$(cat <<EOF
🌟 <code>无限流量模式 (Unlimited)</code>

📈 <b>已用总计:</b> <code>${USED_GB} GB</code>
EOF
)
    SHUTDOWN_TRIGGERED=false
else
    PERCENT=$(awk -v used="$USED_BYTES" -v total="$TOTAL_BYTES" 'BEGIN { if(total==0) print 0; else printf "%.2f", (used/total)*100 }')
    PROGRESS_BAR=$(awk -v p="$PERCENT" 'BEGIN {
        if (p>100) p=100;
        if (p<0) p=0;
        filled = int(p / 10 + 0.5);
        if (filled > 10) filled = 10;
        empty = 10 - filled;
        for (i=0; i<filled; i++) printf "█";
        for (i=0; i<empty; i++) printf "░";
    }')
    
    if awk -v p="$PERCENT" 'BEGIN { exit (p >= 80 ? 0 : 1) }'; then MSG_EMOJI="🟠"; fi
    if awk -v p="$PERCENT" -v limit="$SHUTDOWN_PERCENT" 'BEGIN { exit (p >= limit ? 0 : 1) }'; then MSG_EMOJI="🔴"; fi
    
    PROGRESS_SECTION=$(cat <<EOF
<code>${PROGRESS_BAR} ${PERCENT}%</code>

📈 <b>已用总计:</b> <code>${USED_GB} GB</code> / <code>${TOTAL_GB} GB</code>
EOF
)
    
    if awk -v p="$PERCENT" -v limit="$SHUTDOWN_PERCENT" 'BEGIN { exit (p >= limit ? 0 : 1) }'; then
        SHUTDOWN_TRIGGERED=true
    else
        SHUTDOWN_TRIGGERED=false
    fi
fi

# 7. 生成 Telegram 消息内容
CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")

read -r -d '' MESSAGE_TEXT <<EOF
${MSG_EMOJI} <b>VPS 流量监控 | ${VPS_NAME}</b>

📅 <b>计费周期:</b> <code>${BILLING_YEAR}年${BILLING_MONTH}月</code> (每月 ${RESET_DAY:-1} 日重置)
⏱ <b>同步时间:</b> <code>${CURRENT_TIME}</code>

➖➖➖➖➖➖➖➖➖➖➖➖

📊 <b>流量概况 (模式: ${CALC_MODE})</b>

${PROGRESS_SECTION}

⬇️ <b>入站流量:</b> <code>${RX_GB} GB</code>
⬆️ <b>出站流量:</b> <code>${TX_GB} GB</code>
EOF

if awk -v o="$OFFSET_GB" 'BEGIN {exit (o != 0 ? 0 : 1)}'; then
    MESSAGE_TEXT="${MESSAGE_TEXT}

🔧 <b>手动校准:</b> <code>${OFFSET_GB} GB</code>"
fi

# 8. Telegram API 请求封装 (采用 data-urlencode 避免换行丢失)
# --max-time 30: 防止网络挂死导致 cron 重叠/竞态（2026-08-08 修复）
send_msg() {
    curl -s --max-time 30 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$1"
}

update_msg() {
    curl -s --max-time 30 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "message_id=$2" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$1"
}

# 9. 状态维护及消息发送逻辑
STATE_DIR=$(dirname "$STATE_FILE")
LOG_FILE="${STATE_DIR}/vnstat-monitor.log"
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "Error: Cannot create directory $STATE_DIR. Are you running as root?"
    exit 1
fi

# 原子写状态（tmp + mv），防并发/半写（2026-08-08 修复）
write_state() {
    echo "STORED_MONTH=\"$1\"" > "${STATE_FILE}.tmp"
    echo "STORED_MSG_ID=\"$2\"" >> "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

STORED_MONTH=""
STORED_MSG_ID=""
if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
fi

CURRENT_CYCLE_STR="${BILLING_YEAR}-${BILLING_MONTH}"

if [[ "$STORED_MONTH" == "$CURRENT_CYCLE_STR" && -n "$STORED_MSG_ID" ]]; then
    RESPONSE=$(update_msg "$MESSAGE_TEXT" "$STORED_MSG_ID")
    OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
    if [[ "$OK" != "true" ]]; then
        ERROR_DESC=$(echo "$RESPONSE" | jq -r '.description' 2>/dev/null)
        # 错误分类（2026-08-08 修复）：仅"消息确实不存在"才降级发新卡；
        # 网络类错误（超时/429/5xx/响应为空）跳过本轮保留旧 ID，避免制造孤儿卡片
        if [[ "$ERROR_DESC" == *"is not modified"* ]]; then
            :  # 内容完全一致（Telegram 限制），静默跳过
        elif [[ "$ERROR_DESC" == *"message to edit not found"* || "$ERROR_DESC" == *"message not found"* || "$ERROR_DESC" == *"chat not found"* || "$ERROR_DESC" == *"there is no message to edit"* ]]; then
            # 旧消息已被删除 → 降级发新消息并更新状态
            RESPONSE=$(send_msg "$MESSAGE_TEXT")
            NEW_MSG_ID=$(echo "$RESPONSE" | jq -r '.result.message_id' 2>/dev/null)
            if [[ "$NEW_MSG_ID" != "null" && -n "$NEW_MSG_ID" ]]; then
                write_state "$CURRENT_CYCLE_STR" "$NEW_MSG_ID"
                echo "$(date '+%F %T') degrade: message deleted, new id=$NEW_MSG_ID" >> "$LOG_FILE"
            fi
        else
            # 网络类/其他错误：跳过本轮，保留旧 message_id，下次 cron 再试
            echo "$(date '+%F %T') skip: edit failed (not deletion): ${ERROR_DESC:-empty response}" >> "$LOG_FILE"
        fi
    fi
else
    # 跨越计费周期或首次运行，直接发送新消息
    RESPONSE=$(send_msg "$MESSAGE_TEXT")
    NEW_MSG_ID=$(echo "$RESPONSE" | jq -r '.result.message_id' 2>/dev/null)
    if [[ "$NEW_MSG_ID" != "null" && -n "$NEW_MSG_ID" ]]; then
        write_state "$CURRENT_CYCLE_STR" "$NEW_MSG_ID"
    fi
fi

# 10. 阈值检查与关机动作
if [[ "$SHUTDOWN_TRIGGERED" == "true" ]]; then
    read -r -d '' ALERT_TEXT <<EOF
🚨 <b>严重告警: ${VPS_NAME} 流量超载！</b>

当前使用率: <b>${PERCENT}%</b> (已达关机阈值 ${SHUTDOWN_PERCENT}%)

为避免产生超额账单，服务器正在执行紧急关机动作！
EOF
    send_msg "$ALERT_TEXT"
    sleep 3
    sudo shutdown -h now
fi

# ============ systemd timer 管理（替代 crontab） ============
# 用法见文件头。设计：频率持久化到 /etc/vnstat-monitor.env 的 INTERVAL_MINUTES，
# timer 由 .service(oneshot) + .timer(OnUnitActiveSec) 驱动，改频率即重写 timer 并 reload。

TIMER_SERVICE="/etc/systemd/system/vnstat-monitor.service"
TIMER_UNIT="/etc/systemd/system/vnstat-monitor.timer"

# 从配置读取当前频率（不存在时用默认 15）
read_interval() {
  local f="${CONFIG_FILE:-/etc/vnstat-monitor.env}"
  if [[ -f "$f" ]]; then
    local v
    v=$(grep -E '^INTERVAL_MINUTES=' "$f" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' | tr -d ' ')
    if [[ -n "$v" ]]; then
      echo "$v"
      return 0
    fi
  fi
  echo "15"
}

# 写/更新配置里的 INTERVAL_MINUTES（原子：tmp + mv，避免并发半写）
persist_interval() {  # $1=分钟数
  local f="${CONFIG_FILE:-/etc/vnstat-monitor.env}" minutes="$1"
  [[ -f "$f" ]] || { echo "Error: 配置不存在: $f" >&2; return 1; }
  if grep -qE '^INTERVAL_MINUTES=' "$f"; then
    sed -i "s/^INTERVAL_MINUTES=.*/INTERVAL_MINUTES=\"${minutes}\"/" "$f"
  else
    echo "INTERVAL_MINUTES=\"${minutes}\"" >> "$f"
  fi
  echo "已更新配置: $f -> INTERVAL_MINUTES=${minutes}"
}

# 校验分钟数（1-1440 整数）
valid_interval() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 1440 ))
}

# 生成并启用 systemd timer（核心）
write_timer() {  # $1=分钟数
  local minutes="$1"
  mkdir -p "$(dirname "$TIMER_SERVICE")"
  cat > "$TIMER_SERVICE" <<EOF
[Unit]
Description=vnstat-monitor traffic check (oneshot)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vnstat-monitor
EOF
  cat > "$TIMER_UNIT" <<EOF
[Unit]
Description=Run vnstat-monitor every ${minutes} minutes

[Timer]
OnUnitActiveSec=${minutes}min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now vnstat-monitor.timer >/dev/null 2>&1
  echo "已安装 systemd timer: 每 ${minutes} 分钟执行一次"
  echo "  ${TIMER_UNIT}"
}

vnstat_timer_cmd() {  # $1=子命令 $2=可选参数
  local sub="${1:-}" arg2="${2:-}" minutes
  case "$sub" in
    help|-h|--help)
      sed -n '4,13p' "$0"
      ;;
    setup)
      # 交互式设置：询问频率 → 持久化 → 装 timer
      minutes="$(read_interval)"
      printf "触发频率（分钟，1-1440，当前 %s，回车默认 %s）: " "$minutes" "$minutes"
      # 兼容管道安装（curl | sudo bash 时 stdin 被占用）：优先 /dev/tty
      if [[ -t 0 ]]; then
        read -r ans
      elif [[ -r /dev/tty ]] 2>/dev/null; then
        read -r ans < /dev/tty
      else
        ans=""
      fi
      if [[ -n "$ans" ]]; then
        valid_interval "$ans" || { echo "Error: 无效频率: $ans（需 1-1440 整数）" >&2; exit 1; }
        minutes="$ans"
      fi
      persist_interval "$minutes"
      write_timer "$minutes"
      echo "设置完成。可用 'sudo vnstat-monitor timer-status' 查看状态；"
      echo "不再需要时 'sudo vnstat-monitor uninstall-timer' 移除。"
      ;;
    install-timer)
      # 用配置频率（或参数覆盖）装 timer
      if [[ -n "$arg2" ]]; then
        valid_interval "$arg2" || { echo "Error: 无效频率: $arg2" >&2; exit 1; }
        minutes="$arg2"
        persist_interval "$minutes"
      else
        minutes="$(read_interval)"
      fi
      write_timer "$minutes"
      ;;
    set-interval)
      # 修改频率并重载 timer（持久化）
      valid_interval "$arg2" || { echo "用法: sudo vnstat-monitor set-interval <分钟>（1-1440 整数）" >&2; exit 1; }
      persist_interval "$arg2"
      write_timer "$arg2"
      ;;
    timer-status)
      if systemctl is-active vnstat-monitor.timer >/dev/null 2>&1; then
        echo "timer: active"
        systemctl show vnstat-monitor.timer -p NextElapseUSecRealtime -p OnUnitActiveSec -p Persistent 2>/dev/null
      else
        echo "timer: 未安装/未激活（运行 'sudo vnstat-monitor setup' 安装）"
      fi
      ;;
    uninstall-timer)
      systemctl stop vnstat-monitor.timer 2>/dev/null
      systemctl disable vnstat-monitor.timer 2>/dev/null
      rm -f "$TIMER_SERVICE" "$TIMER_UNIT"
      systemctl daemon-reload
      echo "已移除 systemd timer 与 service（配置保留）"
      ;;
    *)
      echo "未知子命令: $sub" >&2
      sed -n '4,13p' "$0" >&2
      exit 1
      ;;
  esac
}
