#!/usr/bin/env bash
# vps-init 模块：UFW 防火墙（默认 deny incoming，仅放行必要端口）
#
# 顺序铁律（防失联）：
#   1. 放行实际 SSH 端口（从 sshd 配置读取，不重新生成）
#   2. 用户指定额外端口（http/https/自定义）
#   3. ufw enable（ufw 默认允许 established，现有会话不断）

ufw_main() {
  command -v ufw >/dev/null 2>&1 || install_pkgs ufw

  local ssh_port
  ssh_port="$(get_ssh_port)"
  log_info "SSH 实际端口: ${ssh_port}"

  # ---------- 默认策略 ----------
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  log_info "默认策略: deny incoming / allow outgoing"

  # ---------- 放行 SSH ----------
  ufw allow "${ssh_port}/tcp" >/dev/null
  log_info "已放行 SSH: ${ssh_port}/tcp"

  # ---------- 额外端口 ----------
  local extra="${VPS_INIT_EXTRA_PORTS:-}"
  if [[ -z "$extra" ]]; then
    read_input "额外放行端口（逗号分隔，如 80,443 或 53/udp；留空跳过）: " extra || extra=""
  fi
  if [[ -n "$extra" ]]; then
    local p
    IFS=',' read -r -a ports <<< "$extra"
    for p in "${ports[@]}"; do
      p="$(echo "$p" | tr -d ' ')"
      [[ -z "$p" ]] && continue
      if ufw allow "$p" >/dev/null 2>&1; then
        log_info "已放行: ${p}"
      else
        log_warn "放行失败（格式？）: ${p}（示例: 80, 443, 53/udp）"
      fi
    done
  fi

  # ---------- 开启（无 TTY 用 --force，防 cloud-init/管道场景卡死） ----------
  if ufw status | grep -q 'Status: active'; then
    log_info "UFW 已激活，跳过 enable"
  else
    log_info "开启 UFW（默认 deny incoming）..."
    ufw --force enable >/dev/null
  fi

  echo "" >&2
  ufw status verbose >&2 || true
  echo "" >&2
  log_warn "确认规则中包含 ${ssh_port}/tcp（SSH）——否则新连接将被拒绝！"

  state_done ufw
  log_info "UFW 配置完成"
}
