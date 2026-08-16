#!/usr/bin/env bash
#
# vps-bench — VPS 节点测速（第三方脚本封装）
#
# 用法:
#   vps-bench                 交互选择测速脚本
#   vps-bench nodequality     NodeQuality 测速
#   vps-bench tcpquality      TcpQuality 测速
#   vps-bench -v / -h         版本 / 帮助
#
# ⚠️ 第三方脚本以 curl | sudo bash 方式执行，存在供应链风险：
#    执行前会显示来源 URL，交互模式需确认。

VPS_BENCH_VERSION="1.0.0"

NODEQUALITY_URL="https://run.NodeQuality.com"
TCPQUALITY_URL="https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }

# 交互确认（无 TTY 直接执行，不阻塞管道场景）
confirm() {
  local ans=""
  if [[ -t 0 ]] || [[ -r /dev/tty ]] 2>/dev/null; then
    if [[ -t 0 ]]; then read -r -p "$1 [y/N] " ans; else read -r -p "$1 [y/N] " ans < /dev/tty; fi
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
  else
    return 0
  fi
}

run_script() {  # $1=名称 $2=URL $3=执行命令
  log_warn "将执行第三方测速脚本（供应链风险自负）:"
  log_warn "  来源: $2"
  confirm "确认执行?" || { log_info "已取消"; return 1; }
  log_info "开始 $1 测速..."
  bash -c "$3"
}

run_nodequality() {
  run_script "NodeQuality" "$NODEQUALITY_URL" "bash <(curl -sL $NODEQUALITY_URL)"
}

run_tcpquality() {
  run_script "TcpQuality" "$TCPQUALITY_URL" "curl -fsSL $TCPQUALITY_URL | sudo bash -s"
}

usage() {
  cat <<EOF
vps-bench ${VPS_BENCH_VERSION} — VPS 节点测速

用法:
  vps-bench                 交互选择测速脚本
  vps-bench nodequality     NodeQuality 测速（bash <(curl ...)）
  vps-bench tcpquality      TcpQuality 测速（curl | sudo bash -s）
  vps-bench -v, --version   显示版本号
  vps-bench -h, --help      显示本帮助

注意: 第三方脚本以管道方式执行，请确认来源可信。
EOF
}

main() {
  local action="${1:-menu}"
  case "$action" in
    menu)
      echo "选择测速脚本:"
      echo "  1) NodeQuality"
      echo "  2) TcpQuality"
      echo "  0) 退出"
      local sel=""
      if [[ -t 0 ]]; then read -r -p "选择 [0-2]: " sel; elif [[ -r /dev/tty ]] 2>/dev/null; then read -r -p "选择 [0-2]: " sel < /dev/tty; fi
      case "$sel" in
        1) run_nodequality ;;
        2) run_tcpquality ;;
        *) log_info "退出" ;;
      esac
      ;;
    nodequality|NodeQuality) run_nodequality ;;
    tcpquality|TcpQuality)   run_tcpquality ;;
    -v|--version|-V) echo "vps-bench ${VPS_BENCH_VERSION}" ;;
    -h|--help) usage ;;
    *) usage; return 1 ;;
  esac
}

main "$@"
