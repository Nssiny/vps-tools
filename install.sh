#!/usr/bin/env bash
#
# vps-tools 一键安装/更新/卸载器
#
# 用法:
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh)            # 安装全部工具
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) install    # 同上
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) install vnstat-monitor   # 安装指定工具
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) update vnstat-monitor    # 更新指定工具
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) uninstall vnstat-monitor # 卸载指定工具
#
# 特性:
#   - 脚本下载到 /usr/local/bin/<tool>/ 下，与系统文件隔离，卸载干净
#   - 配置模板首次安装时复制到 /etc/<tool>.env（已存在则不覆盖），真实密钥由用户填写
#   - 提示 cron 添加（不自动改 crontab，避免破坏现有条目）
#   - 幂等：重复 install = 覆盖更新

set -euo pipefail

# ============ 配置 ============
GH_USER="inybit"
GH_REPO="vps-tools"
GH_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}"

INSTALL_DIR="/usr/local/bin"          # 脚本安装根目录
CONFIG_DIR="/etc"                     # 配置目标目录

# ============ 工具注册表 ============
# 每行一个工具: name|script|env_template|env_target|cron_line
#   name        工具名（install/update/uninstall 参数）
#   script      install.sh 里要下载的脚本文件名（相对仓库根，按分类目录组织）
#   env_template 配置模板文件名（相对仓库根，可为空 = 无配置）
#   env_target  配置安装目标路径（env_template 为空时忽略）
#   cron_line   建议的 crontab 行（可为空 = 不提示；含特殊字符需注意转义）
#
# 分类目录约定（新增脚本按功能域归类）:
#   monitor/   监控类（流量/资源/服务状态）
#   network/   网络类（路由/隧道/分流）
#   proxy/     代理类（xray/sing-box 等辅助脚本）
#   utils/     通用工具（DDNS/证书/备份等）
#   backup/    备份类
TOOLS=(
  "vnstat-monitor|monitor/vnstat-monitor/vnstat-monitor.sh|monitor/vnstat-monitor/vnstat-monitor.env.example|${CONFIG_DIR}/vnstat-monitor.env|*/15 * * * * /usr/local/bin/vnstat-monitor/vnstat-monitor.sh >/dev/null 2>&1"
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
  local line="$1" name script env_tpl env_tgt cron
  name=$(tool_field "$line" 1)
  script=$(tool_field "$line" 2)
  env_tpl=$(tool_field "$line" 3)
  env_tgt=$(tool_field "$line" 4)
  cron=$(tool_field "$line" 5)

  local dest="${INSTALL_DIR}/${name}"
  mkdir -p "$dest"

  log_info "下载 ${name}: ${BASE_URL}/${script}"
  if ! curl -fsSL --max-time 60 "${BASE_URL}/${script}" -o "${dest}/$(basename "$script")"; then
    log_err "下载失败: ${script}（检查网络或仓库路径）"
    return 1
  fi
  chmod +x "${dest}/$(basename "$script")"
  log_info "已安装: ${dest}/$(basename "$script")"

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

  # cron 提示（必须 root crontab：脚本 source /etc/<tool>.env(600) 且写 /var/lib、改 /etc 配置、可能 shutdown）
  if [[ -n "$cron" ]]; then
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

  if [[ -f "$env_tgt" ]]; then
    log_warn "配置文件保留: ${env_tgt}（如需删除: rm $env_tgt）"
  fi

  log_info "请手动删除 crontab 中的 ${name} 条目（如有）。"
}

# ============ 主流程 ============
main() {
  local action="${1:-install}"
  local tool="${2:-}"

  case "$action" in
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
      else
        local l
        for l in "${TOOLS[@]}"; do install_tool "$l"; done
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
