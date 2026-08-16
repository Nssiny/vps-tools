#!/usr/bin/env bash
# vps-init 模块：创建普通用户 + sudo（纵深防御；VPS_INIT_SKIP_USER=1 可跳过 root-only）

user_main() {
  if [[ "${VPS_INIT_SKIP_USER:-0}" == "1" ]]; then
    log_warn "VPS_INIT_SKIP_USER=1，跳过创建普通用户（root-only 模式）"
    log_warn "风险提示：日常操作全在 root 下，无操作审计、误操作无缓冲"
    state_done user
    return 0
  fi

  local username="${VPS_INIT_USER:-}"
  local pass="${VPS_INIT_USER_PASS:-}"

  # ---------- 输入用户名 ----------
  while [[ -z "$username" ]]; do
    read_input "要创建的普通用户名（留空跳过）: " username || { log_warn "无交互终端，跳过"; state_done user; return 0; }
    if [[ -z "$username" ]]; then
      log_warn "未创建普通用户（root-only）"
      state_done user
      return 0
    fi
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      log_err "用户名不合法（小写字母/数字/_-，首字符字母或下划线）: ${username}"
      username=""
    elif id "$username" >/dev/null 2>&1; then
      log_info "用户 ${username} 已存在，跳过创建"
      break
    fi
  done

  # ---------- 输入密码 ----------
  if [[ -z "$pass" ]]; then
    local pass1=""
    read_input "设置 ${username} 的密码（sudo 提权用）: " pass || { log_err "无交互终端，无法设置密码"; return 1; }
    if [[ -z "$pass" ]]; then
      log_err "密码不能为空（sudo 提权需要）"
      return 1
    fi
    read_input "再次输入确认: " pass1 || pass1=""
    if [[ "$pass" != "$pass1" ]]; then
      log_err "两次密码不一致"
      return 1
    fi
  fi

  # ---------- 创建用户 + sudo ----------
  local sgroup
  sgroup="$(sudo_group)"
  if [[ -z "$sgroup" ]]; then
    log_err "未找到 sudo/wheel 组，无法授权 sudo"
    return 1
  fi

  if ! id "$username" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$username" || { log_err "创建用户失败"; return 1; }
    log_info "已创建用户: ${username} (home=/home/${username}, shell=/bin/bash)"
  fi
  usermod -aG "$sgroup" "$username"
  echo "${username}:${pass}" | chpasswd
  log_info "已加入 ${sgroup} 组并设置密码（sudo 提权需要）"

  # ---------- 可选：禁用 root 登录 ----------
  if [[ "${VPS_INIT_DISABLE_ROOT:-0}" == "1" ]]; then
    ssh_set_permit_root_login no
    log_info "已禁用 root 登录（PermitRootLogin no）—— 确认普通用户密钥可登录前请勿断开当前会话"
  else
    log_info "保留 root 登录（PermitRootLogin 未改动）；如需禁用: vps-init ssh --disable-root"
  fi

  state_done user
  # 持久化用户名：ssh 步骤据此给该用户注入密钥（向导/单步场景通用）
  state_dir
  printf '%s\n' "$username" > "${VPS_INIT_STATE_DIR}/user"
  log_info "普通用户配置完成: ${username}"
}
