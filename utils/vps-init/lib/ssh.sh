#!/usr/bin/env bash
# vps-init 模块：SSH 安全（密钥认证 / 随机高位端口 / 禁用密码登录）
#
# 顺序铁律（防失联）：
#   1. 公钥注入（root + 目标普通用户）并校验非空
#   2. 生成随机高位端口写 drop-in
#   3. 仅当至少一个用户的 authorized_keys 非空 → 禁用密码登录
#   4. sshd -t 校验 → restart sshd（不断已有连接）→ 打印验证指引
# 全部变更前备份 drop-in

ssh_main() {
  # ---------- 0. 目标用户清单（root + VPS_INIT_USER/上次 user 步骤创建的用户） ----------
  local target_users=("root")
  if [[ -n "${VPS_INIT_USER:-}" ]] && id "${VPS_INIT_USER}" >/dev/null 2>&1; then
    target_users+=("${VPS_INIT_USER}")
  elif [[ -f "${VPS_INIT_STATE_DIR}/user" ]]; then
    local saved_user
    saved_user="$(cat "${VPS_INIT_STATE_DIR}/user" 2>/dev/null)"
    if [[ -n "$saved_user" ]] && id "$saved_user" >/dev/null 2>&1; then
      target_users+=("$saved_user")
    fi
  fi

  # ---------- 1. 公钥获取与注入 ----------
  local pubkey=""
  if [[ -n "${VPS_INIT_SSH_PUBKEY:-}" ]]; then
    pubkey="${VPS_INIT_SSH_PUBKEY}"
    # env 值可能是文件路径
    if [[ -f "$pubkey" ]]; then
      pubkey="$(tr -d '\r\n' < "$pubkey")"
    fi
  elif [[ -n "$1" && -f "$1" ]]; then
    pubkey="$(tr -d '\r\n' < "$1")"
  else
    read_input "粘贴 SSH 公钥（ssh-ed25519 AAAA... 或 ssh-rsa AAAA...；也可传 --pubkey <文件>，已有配置可回车跳过）: " pubkey || pubkey=""
  fi

  # 无公钥时的幂等回退：已有 authorized_keys 视为已配置，跳过注入
  local user homedir sshdir authorized
  local has_existing_keys=0
  for user in "${target_users[@]}"; do
    homedir="$(getent passwd "$user" | cut -d: -f6)"
    [[ -s "${homedir}/.ssh/authorized_keys" ]] && has_existing_keys=1
  done

  if [[ -z "$pubkey" ]]; then
    if [[ "$has_existing_keys" -eq 0 ]]; then
      log_err "未提供公钥且无已有的 authorized_keys 配置（VPS_INIT_SSH_PUBKEY 或 --pubkey 必填）"
      return 1
    fi
    log_info "authorized_keys 已存在，跳过公钥注入（如需更换请手动更新）"
  else
    # 校验：以 ssh- 开头（允许注释后缀）
    if ! [[ "$pubkey" =~ ^ssh-(ed25519|rsa|ecdsa|dss)[[:space:]]+ ]]; then
      log_err "公钥格式不合法（应以 ssh-ed25519 / ssh-rsa 等开头）"
      return 1
    fi
    for user in "${target_users[@]}"; do
      homedir="$(getent passwd "$user" | cut -d: -f6)"
      sshdir="${homedir}/.ssh"
      authorized="${sshdir}/authorized_keys"
      mkdir -p "$sshdir"
      chmod 700 "$sshdir"
      touch "$authorized"
      chmod 600 "$authorized"
      if grep -qF "$pubkey" "$authorized" 2>/dev/null; then
        log_info "${user}: 公钥已存在，跳过"
      else
        echo "$pubkey" >> "$authorized"
        log_info "${user}: 公钥已注入 ${authorized}"
      fi
      chown -R "$user":"$(id -gn "$user")" "$sshdir" 2>/dev/null || true
    done
  fi

  # 密钥就位校验（禁密码前置条件；已有配置场景直接通过）
  local key_ready=0
  for user in "${target_users[@]}"; do
    homedir="$(getent passwd "$user" | cut -d: -f6)"
    if [[ -s "${homedir}/.ssh/authorized_keys" ]]; then key_ready=1; fi
  done
  if [[ "$key_ready" -ne 1 ]]; then
    log_err "所有目标用户的 authorized_keys 均为空——拒绝禁用密码登录（防失联）"
    return 1
  fi

  # ---------- 2. 随机高位端口（幂等：drop-in 已有端口则保留，重跑不换） ----------
  local ssh_port="${VPS_INIT_SSH_PORT:-}"
  if [[ -z "$ssh_port" && -f "${VPS_INIT_DROPIN}" ]]; then
    ssh_port="$(get_ssh_port)"
    [[ "$ssh_port" == "22" ]] && ssh_port=""   # 无 drop-in 端口时回落值不算数
  fi
  if [[ -z "$ssh_port" ]]; then
    ssh_port="$(random_port)"
  fi
  if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1024 || ssh_port > 65535 )); then
    log_err "SSH 端口非法: ${ssh_port}（需 1024-65535）"
    return 1
  fi

  # ---------- 3. 写 drop-in（含禁密码） ----------
  mkdir -p "${VPS_INIT_CONF_D}"
  if [[ -f "${VPS_INIT_DROPIN}" ]]; then
    backup_file "${VPS_INIT_DROPIN}"
  fi
  cat > "${VPS_INIT_DROPIN}" <<EOF
# Managed by vps-init — 请勿手改（vps-init ssh 重新生成）
Port ${ssh_port}
PasswordAuthentication no
PubkeyAuthentication yes
EOF
  log_info "已写入 ${VPS_INIT_DROPIN}: Port ${ssh_port} / PasswordAuthentication no / PubkeyAuthentication yes"

  # ---------- 4. 生效 ----------
  if ! sshd -t; then
    log_err "sshd -t 校验失败——配置未生效，已保留备份 ${VPS_INIT_DROPIN}.bak.*"
    return 1
  fi
  systemctl restart ssh sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || {
    log_err "SSH 服务重启失败"; return 1; }
  log_info "SSH 服务已重启（已有连接不受影响）"

  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  log_warn "========================================================"
  log_warn "SSH 已变更：端口 ${ssh_port}，密码登录已禁用（仅密钥）"
  log_warn "保持当前会话不要关闭！开新窗口验证："
  log_warn "    ssh -p ${ssh_port} root@${ip:-<服务器IP>}"
  log_warn "    ssh -p ${ssh_port} ${VPS_INIT_USER:-<用户>}@${ip:-<服务器IP>}"
  log_warn "验证成功后再关闭本窗口。密码登录已禁用，旧端口不再可用。"
  log_warn "========================================================"

  state_done ssh
  log_info "SSH 安全配置完成"
}

# 禁用 root 登录（user.sh 可选调用；写独立 drop-in 避免与主 drop-in 冲突）
ssh_set_permit_root_login() {  # $1=yes|no
  local val="$1"
  mkdir -p "${VPS_INIT_CONF_D}"
  cat > "${VPS_INIT_CONF_D}/50-vps-init-root.conf" <<EOF
# Managed by vps-init
PermitRootLogin ${val}
EOF
  if ! sshd -t; then
    log_err "sshd -t 校验失败（PermitRootLogin ${val}）"
    rm -f "${VPS_INIT_CONF_D}/50-vps-init-root.conf"
    return 1
  fi
  systemctl restart ssh sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  log_info "PermitRootLogin 已设置为 ${val}"
}
