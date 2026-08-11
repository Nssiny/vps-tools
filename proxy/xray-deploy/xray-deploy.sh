#!/usr/bin/env bash
# ============================================================
# xray-deploy.sh — Xray 一键部署/管理（vps-tools 生态）
#
# 功能:
#   - 交互式菜单（无参运行）或子命令模式
#   - 自动安装依赖（apt-get / apk / dnf / yum）
#   - 自动识别架构（amd64 / arm64 / armv7l）
#   - 自动写入自启（systemd / OpenRC）
#   - 节点信息持久化，随时 info 查看
#   - 协议可扩展（注册表驱动），默认 VLESS-TCP-XTLS-Vision-REALITY
#   - geosite/geoip 使用 MetaCubeX/meta-rules-dat，每周自动更新
#   - 回落域名半自动筛选（测试 + 排序 + 确认）
#   - 生成 mihomo / sing-box 客户端节点信息
#   - 服务端 routing（block 广告/BT/私网/国内，google 直连）
#
# 用法:
#   xray-deploy.sh                  # 交互菜单
#   xray-deploy.sh install          # 安装/更新 Xray（首次部署向导）
#   xray-deploy.sh info             # 查看节点信息（非 root 可跑）
#   xray-deploy.sh update-geo       # 更新 geosite/geoip
#   xray-deploy.sh upgrade          # 升级 Xray 二进制
#   xray-deploy.sh status           # 服务状态
#   xray-deploy.sh restart          # 重启服务
#   xray-deploy.sh protocol list    # 协议列表
#   xray-deploy.sh protocol add     # 新增协议
#   xray-deploy.sh protocol edit    # 修改协议
#   xray-deploy.sh protocol remove  # 删除协议
#   xray-deploy.sh uninstall        # 卸载
#
# 环境变量:
#   GH_PROXY   GitHub 下载镜像前缀（可选，如 https://ghproxy.com/）
#
# 安装路径:
#   二进制   /usr/local/bin/xray-deploy/（含 xray + geo 数据）
#   配置     /etc/xray-deploy/config.json + state.json（600）
#   服务     systemd: /etc/systemd/system/xray-deploy.service
#             OpenRC: /etc/init.d/xray-deploy
#   定时     /etc/cron.weekly/xray-geo-update
# ============================================================

set -euo pipefail

# ============ 路径常量 ============
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 注意：/usr/local/bin/xray-deploy 是 vps-tools 生成的命令入口（wrapper），
# 二进制/geo 数据放 /usr/local/lib/xray-deploy/，避免与命令冲突
INSTALL_DIR="${XRAY_INSTALL_DIR:-/usr/local/lib/xray-deploy}"
CONFIG_DIR="/etc/xray-deploy"
BIN_PATH="${INSTALL_DIR}/xray"
STATE_FILE="${CONFIG_DIR}/state.json"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_NAME="xray-deploy"
GEO_SOURCE="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download"
GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

# ============ 日志 ============
# 注意：log_info/log_warn 必须输出到 stderr！
# 否则会被 $(select_fallback_domain) 等命令替换捕获，污染返回值（实测 bug：SNI 字段存了多行日志）
log_info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }
log_err()  { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

die() { log_err "$*"; exit 1; }

# ============ 交互输入 ============
# 管道方式（curl | sudo bash -s --）下 stdin 被 curl 占用，改从 /dev/tty 读取。
# 返回 1 = 无交互终端（纯 CI/脚本场景）。
read_input() {  # $1=提示 $2=变量名
  if [[ -t 0 ]]; then
    read -r -p "$1" "$2"
  elif [[ -r /dev/tty ]]; then
    read -r -p "$1" "$2" < /dev/tty
  else
    printf -v "$2" ""    # set -u 下确保变量已定义，不崩溃
    return 1
  fi
}

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "需要 root 权限，请用: sudo $0 $*"
}

# ============ 依赖安装 ============
detect_pkg_mgr() {
  if command -v apk >/dev/null 2>&1; then echo "apk"
  elif command -v apt-get >/dev/null 2>&1; then echo "apt-get"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  else echo "none"; fi
}

install_deps() {
  local missing=() pkg
  for c in curl unzip jq openssl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  local mgr
  mgr="$(detect_pkg_mgr)"
  [[ "$mgr" == "none" ]] && die "未找到包管理器（需要 apk/apt-get/dnf/yum 之一）"

  log_info "缺少依赖: ${missing[*]}，使用 ${mgr} 自动安装..."
  local sudo_cmd=""
  [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo_cmd="sudo"

  case "$mgr" in
    apk)
      $sudo_cmd apk add --no-cache curl unzip jq openssl ca-certificates
      ;;
    apt-get)
      $sudo_cmd apt-get update -y
      $sudo_cmd apt-get install -y curl unzip jq openssl ca-certificates
      ;;
    dnf|yum)
      $sudo_cmd "$mgr" install -y curl unzip jq openssl ca-certificates
      ;;
  esac

  # 装后复查
  local still_missing=()
  for c in "${missing[@]}"; do
    command -v "$c" >/dev/null 2>&1 || still_missing+=("$c")
  done
  [[ ${#still_missing[@]} -gt 0 ]] && die "依赖安装后仍缺失: ${still_missing[*]}，请手动安装"
  log_info "依赖就绪。"
}

# ============ 架构检测 ============
detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf)  echo "armv7l" ;;
    *) die "不支持的架构: $m（仅支持 amd64/arm64/armv7l）" ;;
  esac
}

# Xray 发布资产名 → 架构
xray_asset_suffix() {
  case "$(detect_arch)" in
    amd64)  echo "linux-64.zip" ;;
    arm64)  echo "linux-arm64-v8a.zip" ;;
    armv7l) echo "linux-arm32-v7a.zip" ;;
  esac
}

# ============ init 检测 ============
detect_init() {
  if [[ -d /run/systemd/system ]] || command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
  elif command -v rc-update >/dev/null 2>&1 || [[ -d /etc/init.d ]]; then
    echo "openrc"
  else
    echo "unknown"
  fi
}

# ============ 服务控制 ============
service_start() {
  local init
  init="$(detect_init)"
  case "$init" in
    systemd) systemctl daemon-reload && systemctl enable --now "${SERVICE_NAME}" ;;
    openrc)  rc-update add "${SERVICE_NAME}" default && rc-service "${SERVICE_NAME}" start ;;
    *) die "不支持的 init 系统（仅 systemd/OpenRC）" ;;
  esac
}

service_restart() {
  local init
  init="$(detect_init)"
  case "$init" in
    systemd) systemctl restart "${SERVICE_NAME}" ;;
    openrc)  rc-service "${SERVICE_NAME}" restart ;;
    *) die "不支持的 init 系统" ;;
  esac
}

service_stop() {
  local init
  init="$(detect_init)"
  case "$init" in
    systemd) systemctl stop "${SERVICE_NAME}" 2>/dev/null || true ;;
    openrc)  rc-service "${SERVICE_NAME}" stop 2>/dev/null || true ;;
  esac
}

service_status() {
  local init
  init="$(detect_init)"
  case "$init" in
    systemd) systemctl status "${SERVICE_NAME}" --no-pager || true ;;
    openrc)  rc-service "${SERVICE_NAME}" status || true ;;
  esac
}

# ============ 服务文件安装 ============
install_service_file() {
  local init
  init="$(detect_init)"
  case "$init" in
    systemd)
      cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xray (xray-deploy)
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} run -config ${CONFIG_FILE}
Environment=XRAY_LOCATION_ASSET=${INSTALL_DIR}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
      ;;
    openrc)
      cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
command="${BIN_PATH}"
command_args="run -config ${CONFIG_FILE}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
export XRAY_LOCATION_ASSET="${INSTALL_DIR}"
depend() {
  need net
}
EOF
      chmod +x "/etc/init.d/${SERVICE_NAME}"
      ;;
    *) die "不支持的 init 系统（仅 systemd/OpenRC）" ;;
  esac
  log_info "已写入自启服务（${init}）"
}

# ============ 端口检查 ============
port_in_use() {  # $1=port
  [[ -n "$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E ":${1}$" || true)" ]]
}

# ============ 回落域名候选（半自动） ============
# 格式: domain|country|tier|备注
# tier: 3=图书馆/大学/旅游局  4=社区测试过  5=大厂（默认跳过，不推荐）
# 2026-08-11 实测清理：cambridge.org=TLSv1.2、tum.de=无ALPN h2、mit.edu=http/1.1 → 移除
FALLBACK_CANDIDATES=(
  "www.ox.ac.uk|GB|3|牛津大学"
  "www.harvard.edu|US|3|哈佛大学"
  "www.stanford.edu|US|3|斯坦福大学"
  "www.ethz.ch|CH|3|苏黎世联邦理工"
  "www.loc.gov|US|3|美国国会图书馆"
  "www.bl.uk|GB|3|大英图书馆"
  "www.bnf.fr|FR|3|法国国家图书馆"
  "www.japan.travel|JP|3|日本旅游局"
  "www.visitbritain.com|GB|3|英国旅游局"
  "www.germany.travel|DE|3|德国旅游局"
  "www.france.fr|FR|3|法国官网"
  "www.australia.com|AU|3|澳大利亚旅游局"
  "www.tourismthailand.org|TH|3|泰国旅游局"
  "addons.mozilla.org|US|4|社区常用"
  "www.wikipedia.org|US|4|维基百科"
)

# 检测服务器国家（用于候选排序）
detect_server_country() {
  local c
  c="$(curl -s --max-time 10 https://ipinfo.io/country 2>/dev/null || true)"
  [[ "$c" =~ ^[A-Z]{2}$ ]] && { echo "$c"; return 0; }
  c="$(curl -s --max-time 10 "http://ip-api.com/line/?fields=countryCode" 2>/dev/null || true)"
  [[ "$c" =~ ^[A-Z]{2}$ ]] && echo "$c" || echo "US"
}

# 测试回落域名: 返回 0=通过；输出原因到 stdout
# 兼容 OpenSSL 1.1.1/3.x/3.5：3.x+ 的 s_client 输出 "New, TLSv1.3, Cipher is ..."，
# 3.5 输出 "Protocol: TLSv1.3"（单冒号）。X25519 不单独 grep——-groups X25519 参数
# 已限定客户端仅提供 X25519，TLSv1.3 握手成功即证明服务端支持（TLS1.3 无 Server Temp Key 行）。
# HTTP 检查放宽：REALITY 回落只需 TLS 层正常；301/302 同站跳转、403 WAF 均可用，
# 仅拒绝 4xx/5xx 服务错误与 000 连接失败（加 UA 降低 WAF 误杀）。
test_fallback_domain() {
  local domain="$1" out code
  # TLS1.3 + H2 + X25519(隐含) + 非 Cloudflare + 证书有效
  out="$(echo | timeout 12 openssl s_client -connect "${domain}:443" -tls1_3 -alpn h2 -groups X25519 -servername "$domain" 2>&1 || true)"
  grep -qE "New, TLSv1\.3|Protocol: TLSv1\.3|Protocol  : TLSv1\.3" <<<"$out" || { echo "TLSv1.3 不支持"; return 1; }
  grep -qE "ALPN protocol: h2" <<<"$out" || { echo "不支持 H2"; return 1; }
  grep -qi "cloudflare" <<<"$out" && { echo "Cloudflare CDN（不推荐）"; return 1; }
  grep -q "Verify return code: 0" <<<"$out" || { echo "证书校验失败"; return 1; }
  # 非跳转/非错误：接受 2xx/3xx；拒绝 000（连接失败）、4xx/5xx（服务错误）
  code="$(curl -sI --max-time 10 -o /dev/null -w '%{http_code}' -A 'Mozilla/5.0' "https://${domain}/" 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^[23] ]]; then
    :
  elif [[ "$code" == "000" ]]; then
    echo "连接失败（HTTP 000）"; return 1
  elif [[ "$code" =~ ^[45] ]]; then
    echo "HTTP ${code}（服务错误）"; return 1
  fi
  echo "ok"
  return 0
}

# 回落域名筛选向导（半自动：测试+排序+确认）
select_fallback_domain() {
  local country server_domain line dom c t note i result candidates=() sorted=()
  country="$(detect_server_country)"
  log_info "服务器国家: ${country}"

  # 1) 优先询问自有域名（偷自己，推荐度最高）
  read_input "如有自有域名可作回落（直接回车跳过）: " server_domain
  if [[ -n "$server_domain" ]]; then
    echo "$server_domain"
    return 0
  fi

  # 2) 候选排序：同国 tier3 > 同国 tier4 > 他国 tier3 > 他国 tier4（tier5 大厂默认排除）
  for line in "${FALLBACK_CANDIDATES[@]}"; do
    IFS='|' read -r dom c t note <<<"$line"
    [[ "$t" == "5" ]] && continue
    if [[ "$c" == "$country" ]]; then
      sorted+=("1|${t}|${dom}|${note}")
    else
      sorted+=("2|${t}|${dom}|${note}")
    fi
  done
  IFS=$'\n' sorted=($(sort -t'|' -k1,1 -k2,2 <<<"${sorted[*]}")); unset IFS

  # 3) 逐个测试，通过即展示；最多展示 6 个
  log_info "正在测试回落候选（TLS1.3+H2+X25519+非跳转+非Cloudflare）..."
  local tested=0 shown=0
  for line in "${sorted[@]}"; do
    [[ "$shown" -ge 6 ]] && break
    IFS='|' read -r _ _ dom note <<<"$line"
    result="$(test_fallback_domain "$dom")"
    tested=$((tested+1))
    if [[ "$result" == "ok" ]]; then
      shown=$((shown+1))
      candidates+=("$dom|$note")
      log_info "  [${shown}] ${dom}  (${note}) ✓"
    else
      log_warn "  ✗ ${dom} — ${result}"
    fi
  done

  [[ ${#candidates[@]} -eq 0 ]] && die "所有候选均未通过测试，请检查服务器网络或换用自有域名"

  # 用户确认（默认第一个）；注意此处输出到 stderr 的空行分隔符不可用 echo（会被 $(...) 捕获污染返回值）
  read_input "选择回落域名 [1-${#candidates[@]}，回车默认 1]: " i
  i="${i:-1}"
  [[ "$i" =~ ^[0-9]+$ ]] && [[ "$i" -ge 1 ]] && [[ "$i" -le "${#candidates[@]}" ]] || die "无效选择"
  IFS='|' read -r dom note <<<"${candidates[$((i-1))]}"
  echo "$dom"
}

# ============ 密钥生成 ============
gen_uuid() { "${BIN_PATH}" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
gen_short_id() { openssl rand -hex 8; }
gen_reality_keys() {  # 输出 "private_key public_key"
  # 兼容新旧格式：旧版 "Private key: xxx" / "Public key: xxx"；新版(26.x) "PrivateKey: xxx" / "Password (PublicKey): xxx"
  "${BIN_PATH}" x25519 2>/dev/null | awk '
    /PrivateKey:/{p=$2}
    /Private key:/{p=$3}
    /Password \(PublicKey\):/{q=$3}
    /Public key:/{q=$3}
    END{print p, q}'
}

# ============ Xray 下载/安装 ============
latest_xray_tag() {
  curl -fsSL --max-time 20 "${GITHUB_API}" | jq -r '.tag_name'
}

download_xray() {  # $1=tag；失败 return 1（由调用方决定回滚）
  local tag="$1" arch asset url
  arch="$(detect_arch)"
  asset="Xray-$(xray_asset_suffix)"
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
  [[ -n "${GH_PROXY:-}" ]] && url="${GH_PROXY}${url}"

  log_info "下载 Xray ${tag} (${arch}): ${url}"
  local tmp
  tmp="$(mktemp -d)"
  if ! curl -fL --max-time 300 -o "${tmp}/xray.zip" "$url"; then
    rm -rf "$tmp"; log_err "Xray 下载失败: ${url}"; return 1
  fi
  if ! unzip -o -j "${tmp}/xray.zip" "xray" -d "${INSTALL_DIR}" >/dev/null; then
    rm -rf "$tmp"; log_err "解压失败（zip 损坏?）"; return 1
  fi
  chmod +x "${BIN_PATH}"
  rm -rf "$tmp"
  log_info "Xray 已安装: ${BIN_PATH} ($("${BIN_PATH}" version | head -1))"
}

install_xray() {
  need_root
  mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}"
  install_deps
  local tag
  tag="$(latest_xray_tag)" || die "无法获取 Xray 最新版本（检查网络）"
  download_xray "$tag" || die "Xray 安装失败"
  [[ -x "${BIN_PATH}" ]] || die "Xray 二进制缺失"
}

# ============ geo 数据更新（MetaCubeX/meta-rules-dat） ============
update_geo() {
  local quiet="${1:-}"
  need_root
  mkdir -p "${INSTALL_DIR}"
  for f in geosite.dat geoip.dat; do
    local url="${GEO_SOURCE}/${f}"
    [[ -n "${GH_PROXY:-}" ]] && url="${GH_PROXY}${url}"
    [[ -z "$quiet" ]] && log_info "更新 ${f}: ${url}"
    curl -fL --max-time 120 -o "${INSTALL_DIR}/${f}" "$url" || die "${f} 下载失败"
  done
  [[ -z "$quiet" ]] && log_info "geo 数据已更新（MetaCubeX/meta-rules-dat）"
}

install_cron_weekly() {
  cat > "/etc/cron.weekly/xray-geo-update" <<EOF
#!/bin/sh
${SCRIPT_DIR}/xray-deploy.sh update-geo --quiet >/dev/null 2>&1 || exit 1
EOF
  chmod +x "/etc/cron.weekly/xray-geo-update"
  log_info "已写入每周定时更新: /etc/cron.weekly/xray-geo-update"
}

# ============ 协议注册表（可扩展） ============
# 新增协议步骤:
#   1. PROTO_REGISTRY 加一行: name|显示名|服务二进制
#   2. 实现 gen_inbound_<name> / gen_client_mihomo_<name> / gen_client_singbox_<name>
#   3. 在 state.json 的 protocols[] 里存该协议参数
PROTO_REGISTRY=(
  "vless-reality|VLESS-TCP-XTLS-Vision-REALITY|xray"
)

proto_exists() {  # $1=name
  local line
  for line in "${PROTO_REGISTRY[@]}"; do
    [[ "${line%%|*}" == "$1" ]] && return 0
  done
  return 1
}

proto_display() {  # $1=type
  local line
  for line in "${PROTO_REGISTRY[@]}"; do
    [[ "${line%%|*}" == "$1" ]] && { echo "${line#*|}"; return 0; }
  done
  echo "$1"
}

# ============ 客户端配置生成 ============
gen_client_mihomo_vless_reality() {  # $1=name $2=ip $3=port $4=uuid $5=pubkey $6=sni $7=shortid
  cat <<EOF
  - name: "xray-${1}"
    type: vless
    server: ${2}
    port: ${3}
    uuid: ${4}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${6}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${5}
      short-id: ${7}
EOF
}

gen_client_singbox_vless_reality() {  # 同 mihomo 参数顺序
  cat <<EOF
{
  "type": "vless",
  "tag": "xray-${1}",
  "server": "${2}",
  "server_port": ${3},
  "uuid": "${4}",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "${6}",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": { "enabled": true, "public_key": "${5}", "short_id": "${7}" }
  }
}
EOF
}

# 生成某协议的客户端片段（按类型分发）
gen_client_mihomo() {  # $1=type 其余参数透传
  local type="$1"; shift
  case "$type" in
    vless-reality) gen_client_mihomo_vless_reality "$@" ;;
    *) die "未实现的客户端生成: ${type}" ;;
  esac
}

gen_client_singbox() {  # $1=type 其余参数透传
  local type="$1"; shift
  case "$type" in
    vless-reality) gen_client_singbox_vless_reality "$@" ;;
    *) die "未实现的客户端生成: ${type}" ;;
  esac
}

# ============ 服务端配置聚合 ============
# state.json 的 protocols[] 存参数对象；这里按协议类型推导 inbound
# 新增协议时在此加一个分支（与 PROTO_REGISTRY 对应）
protocol_to_inbound() {  # $1=协议参数 JSON → 输出 inbound JSON（数组元素）
  local json="$1" type
  type="$(jq -r '.type' <<<"$json")"
  case "$type" in
    vless-reality)
      jq '{
        tag: .name, listen: "0.0.0.0", port: .port, protocol: "vless",
        settings: { clients: [{ id: .uuid, flow: "xtls-rprx-vision" }], decryption: "none" },
        streamSettings: {
          network: "tcp", security: "reality",
          realitySettings: {
            show: false, dest: (.sni + ":443"), xver: 0,
            serverNames: [.sni], privateKey: .private_key, shortIds: [.short_id]
          }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }' <<<"$json"
      ;;
    *) die "未实现的 inbound 生成: ${type}" ;;
  esac
}

build_config() {  # 从 state.json 聚合 inbounds + routing
  local inbounds p
  inbounds="$(jq -c '.protocols[]' "$STATE_FILE" | while read -r p; do
    protocol_to_inbound "$p"
  done | jq -s -c .)"
  [[ -n "$inbounds" ]] || die "state.json 无任何协议"

  jq -n \
    --argjson inbounds "$inbounds" '
    {
      log: { loglevel: "warning" },
      routing: {
        domainStrategy: "IPIfNonMatch",
        rules: [
          { type: "field", outboundTag: "block", domain: ["geosite:category-ads-all"] },
          { type: "field", outboundTag: "block", protocol: ["bittorrent"] },
          { type: "field", outboundTag: "block", ip: ["geoip:private"] },
          { type: "field", outboundTag: "direct", domain: ["geosite:google"] },
          { type: "field", outboundTag: "block", domain: ["geosite:cn"] },
          { type: "field", outboundTag: "block", ip: ["geoip:cn"] }
        ]
      },
      outbounds: [
        { protocol: "freedom", tag: "direct" },
        { protocol: "blackhole", tag: "block" }
      ],
      inbounds: $inbounds
    }' > "${CONFIG_FILE}.tmp"

  # 校验通过才生效（原子替换）
  if "${BIN_PATH}" run -test -config "${CONFIG_FILE}.tmp" >/dev/null 2>&1; then
    mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    log_info "配置生成并校验通过: ${CONFIG_FILE}"
  else
    rm -f "${CONFIG_FILE}.tmp"
    die "配置校验失败（xray -test），已保留线上配置不变"
  fi
}

# ============ state.json 管理 ============
state_init() {  # 首次创建
  [[ -f "$STATE_FILE" ]] && return 0
  cat > "$STATE_FILE" <<EOF
{
  "schema_version": 1,
  "server_ip": "",
  "installed_at": "$(date -Is)",
  "protocols": []
}
EOF
  chmod 600 "$STATE_FILE"
}

state_get() { jq -r "$1" "$STATE_FILE"; }
state_set() {  # 传 jq 参数（含 filter），如: state_set --arg x v '.f = $x'
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

detect_server_ip() {
  curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null || \
  curl -s --max-time 10 http://ip-api.com/line/?fields=query 2>/dev/null || \
  echo "127.0.0.1"
}

# ============ 协议向导 ============
proto_wizard_vless_reality() {  # $1=name → 输出 JSON 参数对象
  local name="$1" port uuid keys priv pub sni sid
  read -r -p "端口 [默认 443]: " port
  port="${port:-443}"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
  port_in_use "$port" && die "端口 ${port} 已被占用"
  sni="$(select_fallback_domain)" || die "回落域名选择失败"
  uuid="$(gen_uuid)"
  keys="$(gen_reality_keys)"
  priv="${keys%% *}"; pub="${keys##* }"
  sid="$(gen_short_id)"
  jq -n --arg name "$name" --argjson port "$port" --arg uuid "$uuid" \
    --arg priv "$priv" --arg pub "$pub" --arg sni "$sni" --arg sid "$sid" '
    {
      name: $name, type: "vless-reality",
      port: $port, uuid: $uuid,
      private_key: $priv, public_key: $pub,
      sni: $sni, short_id: $sid
    }'
}

proto_add() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装，先运行: xray-deploy.sh install"
  local name type
  echo "可选协议类型:"
  local i=1 line
  for line in "${PROTO_REGISTRY[@]}"; do
    echo "  $i) ${line#*|}"
    i=$((i+1))
  done
  read -r -p "选择协议类型 [1-$((i-1))]: " t
  t="${t:-1}"
  [[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" -ge 1 ]] && [[ "$t" -le "$((i-1))" ]] || die "无效选择"
  type="${PROTO_REGISTRY[$((t-1))]%%|*}"

  read -r -p "协议名称 [默认 ${type}-01]: " name
  name="${name:-${type}-01}"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || die "名称只允许字母数字_-"

  local params
  case "$type" in
    vless-reality) params="$(proto_wizard_vless_reality "$name")" || die "协议参数生成失败" ;;
    *) die "未实现的协议向导: ${type}" ;;
  esac

  # 追加到 state（参数对象），inbound 由 build_config 推导
  state_set --argjson p "$params" '.protocols += [$p]'
  rebuild_and_reload
  log_info "协议 ${name}（${type}）已添加"
}

proto_remove() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装"
  local name
  proto_list_names
  read -r -p "输入要删除的协议名称: " name
  [[ -n "$name" ]] || die "名称不能为空"
  local count
  count="$(jq --arg n "$name" '[.protocols[] | select(.name==$n)] | length' "$STATE_FILE")"
  [[ "$count" -eq 1 ]] || die "协议 ${name} 不存在"
  read -r -p "确认删除协议 ${name}？[y/N]: " yn
  [[ "${yn,,}" == "y" ]] || { log_info "已取消"; return 0; }
  state_set --arg n "$name" '.protocols = [.protocols[] | select(.name != $n)]'
  rebuild_and_reload
  log_info "协议 ${name} 已删除"
}

proto_edit() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装"
  local name
  proto_list_names
  read -r -p "输入要修改的协议名称: " name
  [[ -n "$name" ]] || die "名称不能为空"
  local idx type
  idx="$(jq --arg n "$name" '[.protocols[] | select(.name==$n)] | length' "$STATE_FILE")"
  [[ "$idx" -eq 1 ]] || die "协议 ${name} 不存在"
  type="$(jq -r --arg n "$name" '.protocols[] | select(.name==$n) | .type' "$STATE_FILE")"
  echo "修改 ${name}（${type}）:"
  echo "  1) 端口"
  echo "  2) 回落域名(SNI)"
  echo "  3) 重新生成 UUID"
  read -r -p "选择 [1-3]: " sel
  case "${sel:-1}" in
    1)
      local port
      read -r -p "新端口: " port
      [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
      port_in_use "$port" && die "端口 ${port} 已被占用"
      state_set --arg n "$name" --argjson port "$port" \
        '.protocols = [.protocols[] | if .name==$n then .port=$port else . end]'
      ;;
    2)
      local sni
      sni="$(select_fallback_domain)" || die "回落域名选择失败"
      state_set --arg n "$name" --arg sni "$sni" \
        '.protocols = [.protocols[] | if .name==$n then .sni=$sni else . end]'
      ;;
    3)
      local uuid
      uuid="$(gen_uuid)"
      state_set --arg n "$name" --arg uuid "$uuid" \
        '.protocols = [.protocols[] | if .name==$n then .uuid=$uuid else . end]'
      ;;
    *) die "无效选择" ;;
  esac
  rebuild_and_reload
  log_info "协议 ${name} 已更新"
}

proto_list_names() {
  log_info "现有协议:"
  jq -r '.protocols[] | "  \(.name)  (\(.type))  端口 \(.port)  SNI \(.sni)"' "$STATE_FILE"
}

# 重建配置并重载服务（增删改后调用）
rebuild_and_reload() {
  build_config
  service_restart
}

# ============ 安装向导 ============
cmd_install() {
  need_root
  if [[ -f "$STATE_FILE" ]] && [[ "$(jq '.protocols | length' "$STATE_FILE")" -gt 0 ]]; then
    log_warn "检测到已有部署，将仅升级二进制并重载配置（如需重新部署请先 uninstall）"
    cmd_upgrade
    return 0
  fi

  install_xray
  update_geo
  state_init
  state_set --arg ip "$(detect_server_ip)" '.server_ip = $ip'

  # 默认协议：VLESS-TCP-XTLS-Vision-REALITY
  log_info "默认部署协议: VLESS-TCP-XTLS-Vision-REALITY"
  local name="vless-reality-01"
  local params
  params="$(proto_wizard_vless_reality "$name")" || die "协议参数生成失败"
  state_set --argjson p "$params" '.protocols = [$p]'

  install_service_file
  rebuild_and_reload
  service_start
  install_cron_weekly
  log_info "安装完成！运行 'xray-deploy.sh info' 查看节点信息"
}

# ============ 升级 ============
cmd_upgrade() {
  need_root
  [[ -x "$BIN_PATH" ]] || die "Xray 未安装，先运行 install"
  local cur latest
  cur="$("${BIN_PATH}" version | head -1 | awk '{print $2}')"
  latest="$(latest_xray_tag)" || die "无法获取最新版本"
  # xray version 输出无 v 前缀，tag 带 v 前缀
  cur="${cur#v}"; latest="${latest#v}"
  [[ "$cur" == "$latest" ]] && { log_info "已是最新版本 ${cur}"; return 0; }
  log_info "升级 ${cur} → ${latest}"
  # 备份旧二进制，失败回滚
  cp "${BIN_PATH}" "${BIN_PATH}.bak"
  if download_xray "v${latest}"; then
    service_restart
    rm -f "${BIN_PATH}.bak"
    log_info "升级完成: ${latest}"
  else
    mv "${BIN_PATH}.bak" "${BIN_PATH}"
    die "升级失败，已回滚到 ${cur}"
  fi
}

# ============ info ============
cmd_info() {
  [[ -f "$STATE_FILE" ]] || die "尚未安装（state.json 不存在）"
  local ip
  ip="$(state_get '.server_ip')"
  echo "=============================================="
  echo " Xray 节点信息（$(state_get '.installed_at')）"
  echo "=============================================="
  echo "服务器 IP: ${ip}"
  echo
  local i name type port uuid pub sni sid
  for i in $(jq -r '.protocols | keys[]' "$STATE_FILE"); do
    name="$(jq -r ".protocols[$i].name" "$STATE_FILE")"
    type="$(jq -r ".protocols[$i].type" "$STATE_FILE")"
    port="$(jq -r ".protocols[$i].port" "$STATE_FILE")"
    uuid="$(jq -r ".protocols[$i].uuid" "$STATE_FILE")"
    pub="$(jq -r ".protocols[$i].public_key" "$STATE_FILE")"
    sni="$(jq -r ".protocols[$i].sni" "$STATE_FILE")"
    sid="$(jq -r ".protocols[$i].short_id" "$STATE_FILE")"
    echo "----------------------------------------------"
    echo "协议: ${name}  (${type})"
    echo "地址: ${ip}:${port}  SNI: ${sni}"
    echo "UUID: ${uuid}"
    echo
    echo "--- mihomo (Clash Meta) proxies 片段 ---"
    gen_client_mihomo "$type" "$name" "$ip" "$port" "$uuid" "$pub" "$sni" "$sid"
    echo
    echo "--- sing-box outbounds 片段 ---"
    gen_client_singbox "$type" "$name" "$ip" "$port" "$uuid" "$pub" "$sni" "$sid"
    echo
  done
  echo "----------------------------------------------"
  echo "服务端 routing（优先级从高到低）:"
  echo "  block: geosite:category-ads-all"
  echo "  block: bittorrent"
  echo "  block: geoip:private"
  echo "  direct: geosite:google"
  echo "  block: geosite:cn"
  echo "  block: geoip:cn"
  echo "=============================================="
}

# ============ 卸载 ============
cmd_uninstall() {
  need_root
  read -r -p "确认卸载 Xray 部署（删除二进制/配置/服务/定时）？[y/N]: " yn
  [[ "${yn,,}" == "y" ]] || { log_info "已取消"; return 0; }
  service_stop
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service" "/etc/init.d/${SERVICE_NAME}"
  rm -f "/etc/cron.weekly/xray-geo-update"
  rm -rf "${INSTALL_DIR}" "${CONFIG_DIR}"
  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload; fi
  log_info "已卸载（state.json 一并删除，包含密钥）"
}

# ============ 配置查看/编辑 ============
cmd_config() {  # $1=show|edit
  local action="${1:-show}"
  case "$action" in
    show)
      [[ -f "$CONFIG_FILE" ]] || die "尚未生成配置（先 install）"
      echo "=== ${CONFIG_FILE} ==="
      cat "$CONFIG_FILE"
      ;;
    edit)
      need_root
      [[ -f "$CONFIG_FILE" ]] || die "尚未生成配置（先 install）"
      if command -v nano >/dev/null 2>&1; then
        nano "$CONFIG_FILE"
      elif command -v vim >/dev/null 2>&1; then
        vim "$CONFIG_FILE"
      else
        vi "$CONFIG_FILE"
      fi
      # 编辑后校验 + 重载
      if "${BIN_PATH}" run -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
        service_restart
        log_info "配置校验通过并已重载服务"
      else
        log_err "配置校验失败——请手动修正（服务仍运行旧配置）"
        return 1
      fi
      ;;
    *) die "config 用法: show|edit" ;;
  esac
}

# ============ 子命令分发 ============
CMD="${1:-menu}"
case "$CMD" in
  install)       cmd_install ;;
  info)          cmd_info ;;
  config)        cmd_config "${2:-show}" ;;
  update-geo)    update_geo "${2:-}" ;;
  upgrade)       cmd_upgrade ;;
  status)        need_root; service_status ;;
  restart)       need_root; service_restart ;;
  uninstall)     cmd_uninstall ;;
  protocol)
    case "${2:-list}" in
      add)    proto_add ;;
      remove) proto_remove ;;
      edit)   proto_edit ;;
      list)   [[ -f "$STATE_FILE" ]] && proto_list_names || die "尚未安装" ;;
      *)      die "protocol 用法: add|remove|edit|list" ;;
    esac
    ;;
  menu) : ;;  # 走交互菜单
  *) die "未知命令: $CMD（支持 install/info/config/update-geo/upgrade/status/restart/uninstall/protocol）" ;;
esac

# ============ 交互菜单 ============
if [[ "$CMD" == "menu" ]]; then
  while true; do
    echo
    echo "===== Xray 部署管理 ====="
    echo "  1) 安装/更新 Xray（首次部署向导）"
    echo "  2) 协议管理（新增/删除/修改）"
    echo "  3) 查看节点信息 (info)"
    echo "  4) 更新 geo 数据 (geosite/geoip)"
    echo "  5) 升级 Xray 版本"
    echo "  6) 查看/编辑配置 (config)"
    echo "  7) 服务状态"
    echo "  8) 重启服务"
    echo "  9) 卸载"
    echo "  0) 退出"
    read_input "请选择 [0-9]: " choice || { log_warn "无交互终端，已退出"; break; }
    case "${choice:-0}" in
      1) cmd_install ;;
      2)
        echo "  1) 新增协议  2) 删除协议  3) 修改协议  4) 列表"
        read_input "选择 [1-4]: " pc || { log_warn "无交互终端"; continue; }
        case "${pc:-4}" in
          1) proto_add ;;
          2) proto_remove ;;
          3) proto_edit ;;
          *) [[ -f "$STATE_FILE" ]] && proto_list_names || echo "尚未安装" ;;
        esac
        ;;
      3) cmd_info ;;
      4) update_geo ;;
      5) cmd_upgrade ;;
      6)
        echo "  1) 查看配置  2) 编辑配置"
        read_input "选择 [1-2]: " cc || { log_warn "无交互终端"; continue; }
        case "${cc:-1}" in
          1) cmd_config show ;;
          2) cmd_config edit ;;
          *) log_warn "无效选择" ;;
        esac
        ;;
      7) need_root; service_status ;;
      8) need_root; service_restart ;;
      9) cmd_uninstall ;;
      0) break ;;
      *) log_warn "无效选择" ;;
    esac
  done
fi

exit 0
