#!/usr/bin/env bash
#
# vps-tools 一键安装/更新/卸载器
#
# 用法:
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh)            # 交互式管理菜单（安装/更新/卸载/查看）
#   vps-tools                                                                                       # 安装后同一入口（管理命令）
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) install    # 交互式选择安装（有终端）
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) install vnstat-monitor   # 安装指定工具
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) update vnstat-monitor    # 更新指定工具
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) uninstall vnstat-monitor # 卸载指定工具
#
# 特性:
#   - 脚本下载到 /usr/local/lib/vps-tools/<tool>/ 下，与系统文件隔离，卸载干净
#   - 每个工具自动生成命令入口 /usr/local/bin/<tool>，直接以工具名调用
#   - 配置模板首次安装时复制到 /etc/<tool>.env（已存在则不覆盖），真实密钥由用户填写
#   - 提示 cron 添加（不自动改 crontab，避免破坏现有条目）
#   - 幂等：重复 install = 覆盖更新
#   - 首次交互运行自动安装管理命令 /usr/local/bin/vps-tools，之后直接 vps-tools 进入菜单
#   - 管道方式（curl | sudo bash）也能交互：stdin 被占用时从 /dev/tty 读取输入

set -euo pipefail

# ============ 配置 ============
GH_USER="inybit"
GH_REPO="vps-tools"
GH_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}"

INSTALL_DIR="/usr/local/lib/vps-tools"   # 脚本库根目录（与命令入口分离）
CONFIG_DIR="/etc"                        # 配置目标目录
CMD_DIR="/usr/local/bin"                 # 命令入口目录
VPS_TOOLS_CMD="${CMD_DIR}/vps-tools"     # 管理命令入口

# ============ 工具注册表 ============
# 每行一个工具: name|script|env_template|env_target|cron_line|interactive_setup
#   name        工具名（install/update/uninstall 参数）
#   script      install.sh 里要下载的脚本文件名（相对仓库根，按分类目录组织）
#   env_template 配置模板文件名（相对仓库根，可为空 = 无配置）
#   env_target  配置安装目标路径（env_template 为空时忽略）
#   cron_line   建议的 crontab 行（可为空 = 不提示；含特殊字符需注意转义）
#   interactive_setup 安装后是否调用交互式 setup（1=是，工具脚本需支持 setup 子命令；
#                     通常配合 systemd timer 替代 crontab；无 TTY 时跳过并提示手动运行）
#
# 分类目录约定（新增脚本按功能域归类）:
#   monitor/   监控类（流量/资源/服务状态）
#   network/   网络类（路由/隧道/分流）
#   proxy/     代理类（xray/sing-box 等辅助脚本）
#   utils/     通用工具（DDNS/证书/备份等）
#   backup/    备份类
TOOLS=(
  "vnstat-monitor|monitor/vnstat-monitor/vnstat-monitor.sh|monitor/vnstat-monitor/vnstat-monitor.env.example|${CONFIG_DIR}/vnstat-monitor.env||1"
  "xray-deploy|proxy/xray-deploy/xray-deploy.sh|||0"
)

# ============ 辅助函数 ============
log_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m $*"; }
log_err()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# 解析工具注册表行
tool_field() {  # $1=行 $2=字段号(1-5)
  echo "$1" | cut -d'|' -f"$2"
}

find_tool() {  # $1=tool name → 输出注册表行
  local line
  for line in "${TOOLS[@]}"; do
    [[ "$(tool_field "$line" 1)" == "$1" ]] && { echo "$line"; return 0; }
  done
  return 1
}

list_tools() {
  log_info "可用工具:"
  local line
  for line in "${TOOLS[@]}"; do
    echo "  - $(tool_field "$line" 1)  ($(tool_field "$line" 2))"
  done
}

# ============ 核心操作 ============
install_tool() {  # $1=tool line
  local line="$1" name script env_tpl env_tgt cron setup_flag
  name=$(tool_field "$line" 1)
  script=$(tool_field "$line" 2)
  env_tpl=$(tool_field "$line" 3)
  env_tgt=$(tool_field "$line" 4)
  cron=$(tool_field "$line" 5)
  setup_flag=$(tool_field "$line" 6)

  local dest="${INSTALL_DIR}/${name}"
  mkdir -p "$dest"

  log_info "下载 ${name}: ${BASE_URL}/${script}"
  if ! curl -fsSL --max-time 60 "${BASE_URL}/${script}" -o "${dest}/$(basename "$script")"; then
    log_err "下载失败: ${script}（检查网络或仓库路径）"
    # 清理失败产生的空目录，避免残留坏状态
    if [[ -d "$dest" ]] && [[ -z "$(ls -A "$dest" 2>/dev/null)" ]]; then
      rmdir "$dest" 2>/dev/null || true
    fi
    return 1
  fi
  chmod +x "${dest}/$(basename "$script")"
  log_info "已安装脚本: ${dest}/$(basename "$script")"

  # 命令入口（工具名直接调用）：wrapper → 脚本库
  mkdir -p "${CMD_DIR}"   # 命令目录可能不存在（干净系统 /usr/local/bin 也需确保）
  cat > "${CMD_DIR}/${name}" <<EOF
#!/usr/bin/env bash
exec "${dest}/$(basename "$script")" "\$@"
EOF
  chmod +x "${CMD_DIR}/${name}"
  log_info "已生成命令: ${CMD_DIR}/${name}（直接运行 ${name} 调用）"

  # 配置模板
  if [[ -n "$env_tpl" && -n "$env_tgt" ]]; then
    if [[ -f "$env_tgt" ]]; then
      log_warn "配置已存在，跳过: ${env_tgt}（如需重配请手动删除后重装）"
    else
      mkdir -p "$(dirname "$env_tgt")"
      if curl -fsSL --max-time 60 "${BASE_URL}/${env_tpl}" -o "$env_tgt"; then
        chmod 600 "$env_tgt"
        log_info "已生成配置模板: ${env_tgt} —— 请编辑填入真实密钥!"
      else
        log_warn "配置模板下载失败: ${env_tpl}"
      fi
    fi
  fi

  # 交互式 setup（替代 cron 提示）：工具自带 setup 子命令（如 systemd timer 管理）
  if [[ "$setup_flag" == "1" ]]; then
    if [[ -t 0 ]] || [[ -r /dev/tty ]] 2>/dev/null; then
      log_info "${name} 支持交互式配置（触发频率等）。调用: ${CMD_DIR}/${name} setup"
      echo "    如当前为管道安装（stdin 被占用），可稍后手动运行: sudo ${name} setup"
      "${CMD_DIR}/${name}" setup
    else
      log_warn "无交互终端，跳过交互式配置。稍后手动运行: sudo ${name} setup"
    fi
  elif [[ -n "$cron" ]]; then
    # cron 提示（必须 root crontab：脚本 source /etc/<tool>.env(600) 且写 /var/lib、改 /etc 配置、可能 shutdown）
    log_info "建议添加 cron —— 用 root crontab（sudo crontab -e），普通用户 crontab 读不到 /etc 配置且无写权限:"
    echo "    $cron"
  fi

  log_info "${name} 安装完成。"
}

uninstall_tool() {  # $1=tool line
  local line="$1" name env_tgt
  name=$(tool_field "$line" 1)
  env_tgt=$(tool_field "$line" 4)

  if [[ -d "${INSTALL_DIR}/${name}" ]]; then
    rm -rf "${INSTALL_DIR}/${name}"
    log_info "已删除脚本目录: ${INSTALL_DIR}/${name}"
  else
    log_warn "未找到脚本目录: ${INSTALL_DIR}/${name}"
  fi
  # 命令入口
  if [[ -f "${CMD_DIR}/${name}" ]]; then
    rm -f "${CMD_DIR}/${name}"
    log_info "已删除命令: ${CMD_DIR}/${name}"
  fi

  if [[ -f "$env_tgt" ]]; then
    log_warn "配置文件保留: ${env_tgt}（如需删除: rm $env_tgt）"
  fi

  log_info "请手动删除 crontab 中的 ${name} 条目（如有）。"
}

# ============ 交互输入 ============
# 管道方式（curl | sudo bash -s --）下 stdin 被 curl 占用，改从 /dev/tty 读取。
# 返回 1 = 无交互终端（纯 CI/脚本场景）。
read_input() {  # $1=提示 $2=变量名；返回 1 = 无交互终端
  local _rc=0
  if [[ -t 0 ]]; then
    read -r -p "$1" "$2" || _rc=1
  elif [[ -r /dev/tty ]] 2>/dev/null; then
    read -r -p "$1" "$2" < /dev/tty || _rc=1
  else
    _rc=1
  fi
  if [[ $_rc -ne 0 ]]; then
    printf -v "$2" ""    # set -u 下确保变量已定义，不崩溃
    return 1
  fi
}

# 安装/更新 vps-tools 管理命令（自身）
install_self() {
  [[ $EUID -eq 0 ]] || return 1
  mkdir -p "$(dirname "${VPS_TOOLS_CMD}")"   # curl 写文件前先建目录（防 curl 23）
  if curl -fsSL --max-time 60 "${BASE_URL}/install.sh" -o "${VPS_TOOLS_CMD}"; then
    chmod +x "${VPS_TOOLS_CMD}"
    log_info "已安装管理命令: ${VPS_TOOLS_CMD}（直接运行 vps-tools 进入管理）"
    return 0
  fi
  log_warn "安装 ${VPS_TOOLS_CMD} 失败（不影响工具安装）"
  return 1
}

# ============ 交互式工具选择 ============
pick_tools_menu() {  # $1=动作 install|update|uninstall
  local action="$1" i=1 line sel mark
  echo "可用工具（输入编号多选，逗号分隔；0=全部；q=返回；* = 已安装）:"
  for line in "${TOOLS[@]}"; do
    mark=" "
    [[ -d "${INSTALL_DIR}/$(tool_field "$line" 1)" ]] && mark="*"
    echo "  $i) $(tool_field "$line" 1)  ($(tool_field "$line" 2)) ${mark}"
    i=$((i+1))
  done
  read_input "选择: " sel || { log_warn "无交互终端，已取消"; return 1; }
  local -a picks=() p
  case "${sel,,}" in
    ""|q) return 0 ;;
    0)
      for line in "${TOOLS[@]}"; do
        case "$action" in
          install|update) install_tool "$line" ;;
          uninstall)      uninstall_tool "$line" ;;
        esac
      done
      ;;
    *)
      IFS=', ' read -r -a picks <<<"$sel"
      for p in "${picks[@]}"; do
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#TOOLS[@]} )); then
          line="${TOOLS[$((p-1))]}"
          case "$action" in
            install|update) install_tool "$line" ;;
            uninstall)      uninstall_tool "$line" ;;
          esac
        else
          log_err "无效选择: $p"
        fi
      done
      ;;
  esac
}

interactive_menu() {
  # root 时确保 vps-tools 管理命令就位（管道方式首次运行也生效）
  if [[ $EUID -eq 0 ]] && [[ ! -x "${VPS_TOOLS_CMD}" ]]; then
    install_self || true   # 非 root / 下载失败不阻塞菜单
  fi
  while true; do
    echo
    echo "===== vps-tools 管理 ====="
    echo "  1) 安装工具（选择）"
    echo "  2) 更新工具（选择）"
    echo "  3) 卸载工具（选择）"
    echo "  4) 查看工具"
    echo "  5) 更新 vps-tools 自身"
    echo "  0) 退出"
    read_input "请选择 [0-5]: " choice || { log_warn "无交互终端，已退出"; break; }
    case "${choice:-0}" in
      1) pick_tools_menu install ;;
      2) pick_tools_menu update ;;
      3) pick_tools_menu uninstall ;;
      4) list_tools ;;
      5) install_self ;;
      0) break ;;
      *) log_warn "无效选择" ;;
    esac
  done
}

# ============ 主流程 ============
main() {
  local action="${1:-menu}"
  local tool="${2:-}"

  case "$action" in
    menu)
      interactive_menu
      ;;
    install|update)
      # root 检测：非 root 明确提示（管道方式无法自动 sudo 重执行，统一引导）
      if [[ $EUID -ne 0 ]]; then
        log_err "需要 root 权限（安装目标 ${INSTALL_DIR} 和 ${CONFIG_DIR} 需 root 写入）。"
        log_err "推荐管道方式（自动以 root 运行）："
        echo "    curl -sSL https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/install.sh | sudo bash -s -- ${action}${tool:+ ${tool}}"
        log_err "或本地执行：sudo bash install.sh ${action}${tool:+ ${tool}}"
        exit 1
      fi
      if [[ -n "$tool" ]]; then
        local line
        if line=$(find_tool "$tool"); then
          install_tool "$line"
        else
          log_err "未知工具: ${tool}"; list_tools; return 1
        fi
      elif [[ "$action" == "install" ]] && ( [[ -t 0 ]] || [[ -r /dev/tty ]] ); then
        # 无参 + 可交互 → 交互式选择（不静默装全部）
        pick_tools_menu install
      else
        log_err "未指定工具且无交互终端。用法: ${0##*/} ${action} <tool>"
        list_tools
        return 1
      fi
      ;;
    uninstall)
      if [[ -z "$tool" ]]; then
        log_err "用法: $0 uninstall <tool>"; list_tools; return 1
      fi
      local line
      if line=$(find_tool "$tool"); then
        uninstall_tool "$line"
      else
        log_err "未知工具: ${tool}"; list_tools; return 1
      fi
      ;;
    list)
      list_tools
      ;;
    *)
      log_err "未知动作: ${action}（install / update / uninstall / list）"
      list_tools
      return 1
      ;;
  esac
}

main "$@"
