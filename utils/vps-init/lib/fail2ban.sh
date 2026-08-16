#!/usr/bin/env bash
# vps-init 模块：Fail2Ban（SSH 暴力破解防御）
#
# Debian 12/13 关键点：journald 管理日志（无 /var/log/auth.log）→ backend=systemd
# banaction 探测：已装 ufw → ufw；否则 nftables
# 模板渲染：templates/jail.local.tpl + sed 占位符替换

fail2ban_main() {
  # Debian/Ubuntu 包名 fail2ban 提供命令 fail2ban-server（无同名命令）
  command -v fail2ban-server >/dev/null 2>&1 || install_pkgs fail2ban fail2ban-server

  local ssh_port backend banaction tpl
  ssh_port="$(get_ssh_port)"

  # ---------- backend 探测 ----------
  if [[ -f /var/log/auth.log ]]; then
    backend="auto"
  else
    backend="systemd"    # Debian 12/13 默认 journald
  fi
  log_info "Fail2Ban backend: ${backend}（检测 /var/log/auth.log）"

  # ---------- banaction 探测 ----------
  if command -v ufw >/dev/null 2>&1; then
    banaction="ufw"
  else
    banaction="nftables"
  fi
  log_info "Fail2Ban banaction: ${banaction}"

  # ---------- 渲染 jail.local ----------
  tpl="$(dirname "${BASH_SOURCE[0]}")/../templates/jail.local.tpl"
  if [[ ! -f "$tpl" ]]; then
    log_err "模板缺失: ${tpl}（安装不完整，检查 extra_files 注册表）"
    return 1
  fi
  if [[ -f "${VPS_INIT_F2B_JAIL}" ]]; then
    backup_file "${VPS_INIT_F2B_JAIL}"
  fi
  sed -e "s|__F2B_BACKEND__|${backend}|g" \
      -e "s|__F2B_BANACTION__|${banaction}|g" \
      -e "s|__SSH_PORT__|${ssh_port}|g" \
      "$tpl" > "${VPS_INIT_F2B_JAIL}"
  log_info "已写入 ${VPS_INIT_F2B_JAIL}（port=${ssh_port}）"

  # ---------- 启动 ----------
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || { log_err "fail2ban 启动失败（journalctl -u fail2ban 查看）"; return 1; }
  sleep 1

  if fail2ban-client status sshd >/dev/null 2>&1; then
    log_info "Fail2Ban [sshd] 已激活（bantime=1d / maxretry=5 / 递增封禁至 5w）"
  else
    log_warn "fail2ban-client status sshd 未返回——检查 jail.local 配置"
  fi

  state_done fail2ban
  log_info "Fail2Ban 配置完成"
}
