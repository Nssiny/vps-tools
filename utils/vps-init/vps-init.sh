#!/usr/bin/env bash
#
# vps-init — 一键初始化 VPS（DD 重装 / 时区 / BBR / 普通用户 / SSH 安全 / Fail2Ban / UFW）
#
# 用法:
#   vps-init                交互向导：按序执行 system → user → ssh → ufw → fail2ban（每步确认）
#   vps-init dd             一键 DD 重装（全自动续跑：cloud-init 首启自动初始化）
#   vps-init system         单步：时区 + BBR
#   vps-init user           单步：创建普通用户 + sudo
#   vps-init ssh            单步：SSH 密钥/随机高位端口/禁密码
#   vps-init ufw            单步：UFW 防火墙
#   vps-init fail2ban       单步：Fail2Ban
#   vps-init status         查看已执行步骤
#   vps-init -v / -h        版本 / 帮助
#
# 配置: /etc/vps-init.env（可缺省；向导交互输入，非交互/预填用环境变量）
# 状态: /etc/vps-init/done.<step>（幂等：已完成的步骤跳过）

VPS_INIT_VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/system.sh
. "${SCRIPT_DIR}/lib/system.sh"
# shellcheck source=lib/user.sh
. "${SCRIPT_DIR}/lib/user.sh"
# shellcheck source=lib/ssh.sh
. "${SCRIPT_DIR}/lib/ssh.sh"
# shellcheck source=lib/ufw.sh
. "${SCRIPT_DIR}/lib/ufw.sh"
# shellcheck source=lib/fail2ban.sh
. "${SCRIPT_DIR}/lib/fail2ban.sh"
# shellcheck source=lib/dd.sh
. "${SCRIPT_DIR}/lib/dd.sh"

# ============ 向导（无参默认） ============
wizard() {
  require_root
  load_env
  log_info "vps-init ${VPS_INIT_VERSION} — 一键初始化 VPS"
  log_info "将按序执行: 系统配置 → 普通用户 → SSH 安全 → 防火墙 → Fail2Ban（已完成的自动跳过）"
  echo "" >&2

  local steps=(system user ssh ufw fail2ban)
  local step
  for step in "${steps[@]}"; do
    if state_is_done "$step"; then
      log_info "[跳过] ${step}（已完成）"
      continue
    fi
    echo "" >&2
    if ! confirm "执行 ${step} 步骤?"; then
      log_warn "跳过 ${step}（未执行）"
      continue
    fi
    case "$step" in
      system)    system_main ;;
      user)      user_main ;;
      ssh)       ssh_main ;;
      ufw)       ufw_main ;;
      fail2ban)  fail2ban_main ;;
    esac
  done

  echo "" >&2
  log_info "向导完成。已执行: $(state_list_done | tr '\n' ' ')"
  log_warn "建议：开新窗口验证 SSH 密钥登录后，再关闭当前会话。"
}

# ============ 状态 ============
status_main() {
  local done_list
  done_list="$(state_list_done)"
  if [[ -z "$done_list" ]]; then
    log_info "尚未执行任何步骤"
  else
    log_info "已完成步骤: ${done_list//$'\n'/ }"
  fi
  log_info "SSH 端口: $(get_ssh_port)"
  log_info "时区: $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)"
  if command -v sysctl >/dev/null 2>&1; then
    log_info "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  fi
  if command -v ufw >/dev/null 2>&1; then
    log_info "UFW: $(ufw status 2>/dev/null | head -1)"
  fi
}

# ============ 帮助 ============
usage() {
  cat <<EOF
vps-init ${VPS_INIT_VERSION} — 一键初始化 VPS

用法:
  vps-init                    交互向导（system → user → ssh → ufw → fail2ban）
  vps-init dd                 一键 DD 重装（全自动续跑，cloud-init 首启自动初始化）
  vps-init system             单步: 时区 Asia/Shanghai + BBR
  vps-init user               单步: 创建普通用户 + sudo
  vps-init ssh                单步: SSH 密钥/随机高位端口/禁密码登录
  vps-init ufw                单步: UFW（deny incoming，放行必要端口）
  vps-init fail2ban           单步: Fail2Ban（SSH 防暴力破解）
  vps-init status             查看已执行步骤/SSH端口/时区/BBR/UFW
  vps-init -v, --version      显示版本号
  vps-init -h, --help         显示本帮助

DD 子命令参数（可选预填）:
  vps-init dd --distro debian --version 13 --port 52322 --user admin --pubkey /path/id_ed25519.pub

配置（/etc/vps-init.env，可缺省）:
  VPS_INIT_USER / VPS_INIT_USER_PASS / VPS_INIT_SSH_PUBKEY / VPS_INIT_SSH_PORT
  SSH_PORT_MIN=20000 / SSH_PORT_MAX=60000 / VPS_INIT_EXTRA_PORTS=80,443
  VPS_INIT_SKIP_USER=0 / VPS_INIT_DISABLE_ROOT=0 / VPS_INIT_YES=0

示例:
  sudo vps-init              # 新购 VPS 初始化（交互）
  sudo vps-init dd           # 一键 DD + 全自动续跑
EOF
}

# ============ 主流程（分发必须在函数定义之后） ============
main() {
  local action="${1:-wizard}"
  case "$action" in
    wizard)
      wizard
      ;;
    dd)
      require_root; load_env
      dd_main "${@:2}"
      ;;
    system)
      require_root; load_env; system_main
      ;;
    user)
      require_root; load_env; user_main
      ;;
    ssh)
      require_root; load_env
      ssh_main "${@:2}"
      ;;
    ufw)
      require_root; load_env; ufw_main
      ;;
    fail2ban)
      require_root; load_env; fail2ban_main
      ;;
    status)
      status_main
      ;;
    -v|--version|-V)
      echo "vps-init ${VPS_INIT_VERSION}"
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      return 1
      ;;
  esac
}

main "$@"
