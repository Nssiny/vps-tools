#!/usr/bin/env bash
# ============================================================
# vps-init 公共函数库
# 被 vps-init.sh source；日志一律输出到 stderr（铁律：返回值靠 stdout 捕获时不污染）
# ============================================================

# 路径默认值（环境变量可覆盖——测试/非 root 场景；产品默认不变）
: "${VPS_INIT_ENV_FILE:=/etc/vps-init.env}"        # 配置文件（可缺省）
: "${VPS_INIT_STATE_DIR:=/etc/vps-init}"          # 步骤状态标记目录
: "${VPS_INIT_CONF_D:=/etc/ssh/sshd_config.d}"    # sshd drop-in 目录
VPS_INIT_DROPIN="${VPS_INIT_CONF_D}/50-vps-init.conf"
: "${VPS_INIT_F2B_JAIL:=/etc/fail2ban/jail.local}"  # fail2ban jail.local 路径

# ---------- 颜色日志（stderr） ----------
log_info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }
log_err()  { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# ---------- root 检测 ----------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    log_err "需要 root 权限（写入 /etc/ssh、/etc/fail2ban、/etc/ufw 等）。"
    log_err "请以 root 运行: sudo ${0##*/} $*"
    exit 1
  fi
}

# ---------- 配置加载（/etc/vps-init.env，可缺省） ----------
# shellcheck disable=SC1090
load_env() {
  [[ -f "${VPS_INIT_ENV_FILE}" ]] && . "${VPS_INIT_ENV_FILE}" 2>/dev/null || true
  : "${SSH_PORT_MIN:=20000}"
  : "${SSH_PORT_MAX:=60000}"
  : "${VPS_INIT_EXTRA_PORTS:=}"
  : "${VPS_INIT_SKIP_USER:=0}"
  : "${VPS_INIT_DISABLE_ROOT:=0}"
  : "${VPS_INIT_YES:=0}"
}

# ---------- 交互输入（stdin 被占用时从 /dev/tty 读；返回 1 = 无交互终端） ----------
read_input() {  # $1=提示 $2=变量名
  local _rc=0
  if [[ -t 0 ]]; then
    read -r -p "$1" "$2" || _rc=1
  elif [[ -r /dev/tty ]] 2>/dev/null; then
    read -r -p "$1" "$2" < /dev/tty || _rc=1
  else
    _rc=1
  fi
  if [[ $_rc -ne 0 ]]; then
    printf -v "$2" ""    # set -u 兜底
    return 1
  fi
}

# 确认提示（默认 N）；返回 0 = 确认
confirm() {  # $1=提示文本
  [[ "${VPS_INIT_YES}" == "1" ]] && return 0
  local ans=""
  read_input "$1 [y/N] " ans || return 1
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ---------- 包管理器探测 + 安装 ----------
DETECTED_PKG_MGR=""
detect_pkg_mgr() {
  if [[ -n "$DETECTED_PKG_MGR" ]]; then echo "$DETECTED_PKG_MGR"; return 0; fi
  local mgr=""
  command -v apk    >/dev/null 2>&1 && mgr="apk"
  command -v apt-get >/dev/null 2>&1 && mgr="apt-get"
  command -v dnf    >/dev/null 2>&1 && mgr="dnf"
  command -v yum    >/dev/null 2>&1 && mgr="yum"
  DETECTED_PKG_MGR="$mgr"
  echo "$mgr"
}

install_pkgs() {  # $1=包名 $2=复查命令名（默认=包名；如 fail2ban 包无同名命令）
  local mgr
  mgr="$(detect_pkg_mgr)"
  [[ -z "$mgr" ]] && { log_err "未识别包管理器（apk/apt/dnf/yum），请手动安装: $1"; return 1; }
  local pkg="$1" check="${2:-$1}"
  local cmd
  case "$mgr" in
    apk)     cmd="apk add" ;;
    apt-get) apt-get update -qq >/dev/null 2>&1 || true; cmd="apt-get install -y -qq" ;;
    dnf)     cmd="dnf install -y" ;;
    yum)     cmd="yum install -y" ;;
  esac
  log_info "安装依赖: $pkg"
  $cmd "$pkg" >/dev/null 2>&1 || { log_err "安装失败: $cmd $pkg（请手动安装后重试）"; return 1; }
  # 装后复查（用命令名，包名可能无同名命令）
  command -v "$check" >/dev/null 2>&1 || { log_err "复查失败: $check 仍未安装"; return 1; }
  return 0
}

# ---------- 随机高位端口（SSH_PORT_MIN~SSH_PORT_MAX） ----------
random_port() {
  local min="${SSH_PORT_MIN:-20000}" max="${SSH_PORT_MAX:-60000}"
  if (( min < 1024 )); then min=1024; fi
  if (( max > 65535 )); then max=65535; fi
  if (( min > max )); then min=20000; max=60000; fi
  echo $(( RANDOM % (max - min + 1) + min ))
}

# ---------- 实际 SSH 端口（drop-in 优先，fallback 22） ----------
get_ssh_port() {
  local port=""
  if [[ -f "${VPS_INIT_DROPIN}" ]]; then
    port="$(sed -n 's/^[[:space:]]*Port[[:space:]]\+\([0-9]\+\).*/\1/p' "${VPS_INIT_DROPIN}" | tail -1)"
  fi
  if [[ -z "$port" ]] && command -v sshd >/dev/null 2>&1; then
    port="$(sshd -T 2>/dev/null | sed -n 's/^port \([0-9]\+\)$/\1/p' | head -1)"
  fi
  echo "${port:-22}"
}

# ---------- sudo 组探测（Debian 系 sudo；RHEL 系 wheel） ----------
sudo_group() {
  if grep -q '^sudo:' /etc/group 2>/dev/null; then echo "sudo"; return 0; fi
  if grep -q '^wheel:' /etc/group 2>/dev/null; then echo "wheel"; return 0; fi
  echo ""
}

# ---------- 步骤状态（/etc/vps-init/done.<step>） ----------
state_dir() { mkdir -p "${VPS_INIT_STATE_DIR}"; }
state_done() { state_dir; touch "${VPS_INIT_STATE_DIR}/done.$1"; }
state_is_done() { [[ -f "${VPS_INIT_STATE_DIR}/done.$1" ]]; }
state_list_done() {
  local f
  [[ -d "${VPS_INIT_STATE_DIR}" ]] || return 0
  for f in "${VPS_INIT_STATE_DIR}"/done.*; do
    [[ -e "$f" ]] && echo "${f##*/done.}"
  done
}

# ---------- 备份文件（cp -a 加 .bak，同目录） ----------
backup_file() {  # $1=文件路径
  [[ -f "$1" ]] || return 0
  cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null && log_info "已备份: $1"
}
