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
#   - 协议可扩展（注册表驱动），默认 VLESS-TCP-XTLS-Vision-REALITY，可选 VLESS-XHTTP-H2-TLS（真实证书落地）
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
#   geo 更新 手动: xray-deploy update-geo（或自行配 systemd timer）
# ============================================================

set -euo pipefail

VERSION="1.5.5"   # 发布新功能时递增（配合 vps-tools 工具约定：新增工具必须支持 -v/-h）

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
# $1=port $2=proto（tcp|udp，默认 tcp）
# TCP/UDP 端口独立：reality(TCP 443) 与 hy2(UDP 443) 可共存，互不冲突
port_in_use() {
  local port="$1" proto="${2:-tcp}" out
  if [[ "$proto" == "udp" ]]; then
    out="$(ss -uln 2>/dev/null | awk '{print $4}' | grep -E ":${port}$" || true)"
  else
    out="$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E ":${port}$" || true)"
  fi
  [[ -n "$out" ]]
}

# ufw 放行检查/添加：$1=port $2=proto（tcp|udp）
# ufw 规则无协议后缀（如 "443"）时 TCP+UDP 均放行，无需重复添加
ensure_firewall() {
  local port="$1" proto="${2:-tcp}" rule
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -qi "Status: active" || return 0
  rule="$(ufw status 2>/dev/null | grep -E "^${port}(/|  )" || true)"
  if [[ -n "$rule" ]]; then
    # 已有规则（无协议后缀=双栈放行；或已含目标协议）
    log_info "防火墙已放行 ${port}（${proto}）"
  else
    log_info "防火墙放行 ${port}/${proto} ..."
    ufw allow "${port}/${proto}" >/dev/null 2>&1 || log_warn "ufw allow ${port}/${proto} 失败（可能已由其他规则覆盖）"
  fi
}

# ============ 回落域名候选（半自动） ============
# 格式: domain|country|tier|备注
# tier: 3=图书馆/大学/旅游局  4=社区测试过  5=大厂（默认跳过，不推荐）
# 2026-08-11 实测清理：cambridge.org=TLSv1.2、tum.de=无ALPN h2、mit.edu=http/1.1 → 移除
FALLBACK_CANDIDATES=(
  # 2026-08-17 扩充：每地区 ≥10（本机初筛通过；lovelive/waseda/gov.hk/ntu 为历史实测保留）
  # DE
  "www.germany.travel|DE|3|德国旅游局"
  "www.tu-dresden.de|DE|3|德累斯顿工大"
  "www.kit.edu|DE|3|卡尔斯鲁厄理工"
  "www.tu-berlin.de|DE|3|柏林工大"
  "www.uni-bonn.de|DE|3|波恩大学"
  "www.uni-freiburg.de|DE|3|弗赖堡大学"
  "www.uni-goettingen.de|DE|3|哥廷根大学"
  "www.deutschland.de|DE|3|德国官方门户"
  "www.bundesregierung.de|DE|3|联邦政府"
  "www.berlin.de|DE|3|柏林市"
  "www.tagesschau.de|DE|3|德国电视一台新闻"
  "www.dw.com|DE|3|德国之声"
  # GB
  "www.cam.ac.uk|GB|3|剑桥大学"
  "www.ed.ac.uk|GB|3|爱丁堡大学"
  "www.lse.ac.uk|GB|3|伦敦政经"
  "www.manchester.ac.uk|GB|3|曼彻斯特大学"
  "www.birmingham.ac.uk|GB|3|伯明翰大学"
  "www.kcl.ac.uk|GB|3|伦敦国王学院"
  "www.leeds.ac.uk|GB|3|利兹大学"
  "www.nottingham.ac.uk|GB|3|诺丁汉大学"
  "www.gov.uk|GB|3|英国政府"
  "www.nationalgallery.org.uk|GB|3|国家美术馆"
  "www.visitscotland.com|GB|3|苏格兰旅游局"
  # US
  "www.harvard.edu|US|3|哈佛大学"
  "www.stanford.edu|US|3|斯坦福大学"
  "www.caltech.edu|US|3|加州理工"
  "www.upenn.edu|US|3|宾夕法尼亚大学"
  "www.brown.edu|US|3|布朗大学"
  "www.ucla.edu|US|3|加州大学洛杉矶"
  "www.washington.edu|US|3|华盛顿大学"
  "www.nasa.gov|US|3|NASA"
  "www.usa.gov|US|3|美国政府门户"
  "www.archives.gov|US|3|国家档案馆"
  "www.npr.org|US|3|NPR"
  "www.wikipedia.org|US|4|维基百科"
  # CH
  "www.ethz.ch|CH|3|苏黎世联邦理工"
  "www.epfl.ch|CH|3|洛桑联邦理工"
  "www.uzh.ch|CH|3|苏黎世大学"
  "www.unibas.ch|CH|3|巴塞尔大学"
  "www.unibe.ch|CH|3|伯尔尼大学"
  "www.unisg.ch|CH|3|圣加仑大学"
  "www.unilu.ch|CH|3|卢塞恩大学"
  "www.zhaw.ch|CH|3|苏黎世应用科学大学"
  "www.parlament.ch|CH|3|瑞士议会"
  "www.swissinfo.ch|CH|3|瑞士资讯"
  "www.zuerich.com|CH|3|苏黎世旅游"
  # FR
  "www.bnf.fr|FR|3|法国国家图书馆"
  "www.france.fr|FR|3|法国官网"
  "www.culture.gouv.fr|FR|3|文化部"
  "www.elysee.fr|FR|3|爱丽舍宫"
  "www.inria.fr|FR|3|法国信息研究院"
  "www.louvre.fr|FR|3|卢浮宫"
  "www.polytechnique.edu|FR|3|巴黎综合理工"
  "www.sorbonne-universite.fr|FR|3|索邦大学"
  "www.cnrs.fr|FR|3|法国国家科研中心"
  "www.univ-nantes.fr|FR|3|南特大学"
  "www.univ-toulouse.fr|FR|3|图卢兹大学"
  # JP
  "www.japan.travel|JP|3|日本旅游局"
  "www.waseda.jp|JP|4|早稻田大学（实测 2026-08-12）"
  "www.keio.ac.jp|JP|3|庆应义塾大学"
  "www.kyoto-u.ac.jp|JP|3|京都大学"
  "www.ndl.go.jp|JP|3|国立国会图书馆"
  "www.nhk.or.jp|JP|3|NHK"
  "www.osaka-u.ac.jp|JP|3|大阪大学"
  "www.sophia.ac.jp|JP|3|上智大学"
  "www.titech.ac.jp|JP|3|东京工业大学"
  "www.tsukuba.ac.jp|JP|3|筑波大学"
  "www.kantei.go.jp|JP|3|首相官邸"
  "www.lovelive-anime.jp|JP|4|实测可用（2026-08-12）"
  # HK
  "www.gov.hk|HK|4|香港政府（实测 2026-08-12）"
  "www.info.gov.hk|HK|3|香港政府资讯"
  "www.hko.gov.hk|HK|3|香港天文台"
  "www.immd.gov.hk|HK|3|香港入境处"
  "www.police.gov.hk|HK|3|香港警务处"
  "www.hkpl.gov.hk|HK|3|香港公共图书馆"
  "www.hkma.gov.hk|HK|3|香港金管局"
  "www.ust.hk|HK|3|香港科技大学"
  "www.cityu.edu.hk|HK|3|香港城市大学"
  "www.hkbu.edu.hk|HK|3|香港浸会大学"
  "www.hyd.gov.hk|HK|3|香港渠务署"
  "www.tourism.gov.hk|HK|3|香港旅游事务署"
  # SG
  "www.ntu.edu.sg|SG|4|新加坡南洋理工（实测 2026-08-12）"
  "www.nus.edu.sg|SG|3|新加坡国立大学"
  "www.smu.edu.sg|SG|3|新加坡管理大学"
  "www.sutd.edu.sg|SG|3|新加坡科技设计大学"
  "www.gov.sg|SG|3|新加坡政府"
  "www.moe.gov.sg|SG|3|新加坡教育部"
  "www.mfa.gov.sg|SG|3|新加坡外交部"
  "www.nlb.gov.sg|SG|3|新加坡国家图书馆"
  "www.nparks.gov.sg|SG|3|新加坡公园局"
  "www.stb.gov.sg|SG|3|新加坡旅游局"
  "www.iras.gov.sg|SG|3|新加坡税务局"
  "www.cpf.gov.sg|SG|3|新加坡公积金局"
  # AU
  "www.australia.com|AU|3|澳大利亚旅游局"
  "www.adelaide.edu.au|AU|3|阿德莱德大学"
  "www.australia.gov.au|AU|3|澳大利亚政府"
  "www.bom.gov.au|AU|3|澳大利亚气象局"
  "www.nla.gov.au|AU|3|澳大利亚国家图书馆"
  "www.queensland.com|AU|3|昆士兰旅游"
  "www.rmit.edu.au|AU|3|RMIT"
  "www.sydney.com|AU|3|悉尼旅游"
  "www.sydney.edu.au|AU|3|悉尼大学"
  "www.unsw.edu.au|AU|3|新南威尔士大学"
  "www.uwa.edu.au|AU|3|西澳大学"
  "www.abc.net.au|AU|3|ABC"
  # TH
  "www.chula.ac.th|TH|3|朱拉隆功大学"
  "www.kmitl.ac.th|TH|3|国王理工"
  "www.mfa.go.th|TH|3|泰国外交部"
  "www.mots.go.th|TH|3|泰国旅游体育部"
  "www.kku.ac.th|TH|3|孔敬大学"
  "www.nu.ac.th|TH|3|那黎宣大学"
  "www.royalthaipolice.go.th|TH|3|泰国皇家警察"
  "www.boi.go.th|TH|3|泰国投资促进委员会"
  "www.ditp.go.th|TH|3|泰国国际贸易促进厅"
  "www.nstda.or.th|TH|3|泰国国家科技发展署"
  "www.tmd.go.th|TH|3|泰国气象局"
  "www.thairath.co.th|TH|3|泰叻报"
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

# 测量 TLS 握手延迟（ms）：3 次采样取中位数，抗单次抖动
measure_handshake_ms() {
  local domain="$1" i t0 t1
  local -a samples=()
  for i in 1 2 3; do
    t0="$(date +%s%N)"
    # || true：openssl 超时/失败不影响采样（set -e 下命令替换失败会杀死脚本）
    echo | timeout 6 openssl s_client -connect "${domain}:443" -tls1_3 -servername "$domain" >/dev/null 2>&1 || true
    t1="$(date +%s%N)"
    samples+=("$(( (t1 - t0) / 1000000 ))")
  done
  # 中位数（排序取中间）
  local sorted
  IFS=$'\n' sorted=($(printf '%s\n' "${samples[@]}" | sort -n)); unset IFS
  echo "${sorted[1]}"
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

  # 2) 候选过滤：只取服务器所在地（country）的域名（tier5 大厂排除）
  # 2026-08-12 用户要求：候选表只取该地区的域名（不再混入他国备选）
  for line in "${FALLBACK_CANDIDATES[@]}"; do
    IFS='|' read -r dom c t note <<<"$line"
    [[ "$t" == "5" ]] && continue
    [[ "$c" == "$country" ]] || continue
    sorted+=("${t}|${dom}|${note}")
  done
  if [[ ${#sorted[@]} -eq 0 ]]; then
    die "候选表中无 ${country} 地区域名，请使用自有域名回落（或补充 FALLBACK_CANDIDATES）"
  fi
  IFS=$'\n' sorted=($(sort -t'|' -k1,1 <<<"${sorted[*]}")); unset IFS

  # 3) 逐个测试，通过即测握手延迟；最多收 6 个
  log_info "正在测试回落候选（TLS1.3+H2+X25519+非跳转+非Cloudflare）..."
  local tested=0 shown=0 delay
  for line in "${sorted[@]}"; do
    [[ "$shown" -ge 6 ]] && break
    IFS='|' read -r _ dom note <<<"$line"
    result="$(test_fallback_domain "$dom")" || true   # 防 set -e：失败(return 1)会终止脚本
    tested=$((tested+1))
    if [[ "$result" == "ok" ]]; then
      delay="$(measure_handshake_ms "$dom")" || true
      shown=$((shown+1))
      candidates+=("$dom|$note|$delay")
    else
      log_warn "  ✗ ${dom} — ${result}"
    fi
  done

  [[ ${#candidates[@]} -eq 0 ]] && die "所有候选均未通过测试，请检查服务器网络或换用自有域名"

  # 4) 按握手延迟升序排序（默认选最低延迟），并列时保持原顺序
  IFS=$'\n' candidates=($(printf '%s\n' "${candidates[@]}" | sort -t'|' -k3,3n)); unset IFS

  # 5) 展示排序结果
  log_info "候选按握手延迟排序（默认选最低）:"
  for ((i=0; i<${#candidates[@]}; i++)); do
    IFS='|' read -r dom note delay <<<"${candidates[$i]}"
    log_info "  [$((i+1))] ${dom}  (${note}) ✓ ${delay}ms"
  done

  # 6) 用户确认（默认第一个 = 延迟最低）；注意此处输出到 stderr 的空行分隔符不可用 echo（会被 $(...) 捕获污染返回值）
  read_input "选择回落域名 [1-${#candidates[@]}，回车默认 1（最低延迟）]: " i
  i="${i:-1}"
  [[ "$i" =~ ^[0-9]+$ ]] && [[ "$i" -ge 1 ]] && [[ "$i" -le "${#candidates[@]}" ]] || die "无效选择"
  IFS='|' read -r dom note delay <<<"${candidates[$((i-1))]}"
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

# BRUTAL 带宽归一化：纯数字自动补 mbps 单位（xray 无单位时按 B/s 解析，60 → 60B/s < 64KB/s 校验失败）
# 例：60 → "60 mbps"；"60 mbps"/"100Mbps" → 原样保留（交给 xray 校验）
normalize_bandwidth() {
  local v="$1"
  [[ -z "$v" ]] && { echo ""; return; }
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v mbps"
  else
    echo "$v"
  fi
}

# ============ TLS 证书（h2 等标准 TLS 协议用） ============
CERT_DIR="${CONFIG_DIR}/certs"

# 输出 "cert_file key_file"；$1=域名
# 三种来源：已有证书路径 / acme.sh 自动签发（HTTP-01，需 80 空闲）/ 自签（测试用）
obtain_cert() {
  local domain="$1" mode cert_file key_file
  log_info "TLS 证书来源（${domain}）:"
  log_info "  1) 已有证书文件路径"
  log_info "  2) acme.sh 自动签发 Let's Encrypt（HTTP-01 验证，需 80 端口空闲）"
  log_info "  3) 自签证书（测试用，客户端需 skip-cert-verify）"
  read_input "选择 [1-3，默认 1]: " mode
  mode="${mode:-1}"
  case "$mode" in
    1)
      read_input "证书文件 fullchain.pem 路径: " cert_file
      read_input "私钥 privkey.pem 路径: " key_file
      [[ -n "$cert_file" ]] && [[ -f "$cert_file" ]] || die "证书文件不存在: ${cert_file}"
      [[ -n "$key_file" ]] && [[ -f "$key_file" ]] || die "私钥文件不存在: ${key_file}"
      echo "$cert_file $key_file"
      ;;
    2)
      obtain_cert_acme "$domain"
      ;;
    3)
      obtain_cert_selfsigned "$domain"
      ;;
    *) die "无效选择" ;;
  esac
}

obtain_cert_selfsigned() {  # $1=domain；输出 "cert_file key_file"（存 CERT_DIR/<domain>/）
  local domain="$1" dir="${CERT_DIR}/${domain}"
  mkdir -p "$dir"
  log_info "生成自签证书: ${domain}（有效期 365 天）"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "${dir}/privkey.pem" -out "${dir}/fullchain.pem" -days 365 \
    -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1 \
    || openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${dir}/privkey.pem" -out "${dir}/fullchain.pem" -days 365 \
      -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1 \
    || die "自签证书生成失败"
  echo "${dir}/fullchain.pem ${dir}/privkey.pem"
}

obtain_cert_acme() {  # $1=domain；输出 "cert_file key_file"
  local domain="$1" dir="${CERT_DIR}/${domain}" acme_cmd
  mkdir -p "$dir"
  if ! command -v acme.sh >/dev/null 2>&1 && [[ ! -x /root/.acme.sh/acme.sh ]]; then
    log_info "安装 acme.sh ..."
    curl -fsSL --max-time 60 https://get.acme.sh | sh -s -- --no-profile >/dev/null 2>&1 \
      || die "acme.sh 安装失败（手动安装: curl https://get.acme.sh | sh）"
  fi
  acme_cmd="acme.sh"; command -v acme.sh >/dev/null 2>&1 || acme_cmd="/root/.acme.sh/acme.sh"
  # 先尝试 standalone（HTTP-01，80 端口）；失败回退自签并提示（不阻断部署）
  if port_in_use 80; then
    log_warn "80 端口被占用，无法 HTTP-01 验证——将改用自签证书（客户端需 skip-cert-verify）"
    obtain_cert_selfsigned "$domain"
    return 0
  fi
  log_info "签发 Let's Encrypt 证书（HTTP-01）: ${domain}"
  if "$acme_cmd" --issue --standalone -d "$domain" --httpport 80 --server letsencrypt >/dev/null 2>&1 \
     && "$acme_cmd" --install-cert -d "$domain" \
        --fullchain-file "${dir}/fullchain.pem" --key-file "${dir}/privkey.pem" >/dev/null 2>&1; then
    echo "${dir}/fullchain.pem ${dir}/privkey.pem"
  else
    log_warn "Let's Encrypt 签发失败（域名未解析到本机？80 不可达？）——改用自签证书（客户端需 skip-cert-verify）"
    obtain_cert_selfsigned "$domain"
  fi
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

# ============ 协议注册表（可扩展） ============
# 新增协议步骤:
#   1. PROTO_REGISTRY 加一行: name|显示名|服务二进制
#   2. 实现 gen_inbound_<name> / gen_client_mihomo_<name> / gen_client_singbox_<name>
#   3. 在 state.json 的 protocols[] 里存该协议参数
PROTO_REGISTRY=(
  "vless-reality|VLESS-TCP-XTLS-Vision-REALITY|xray"
  "vless-xhttp|VLESS-XHTTP-H2-TLS|xray"
  "hysteria2|Hysteria2 (hy2)|xray"
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

gen_client_mihomo_vless_xhttp() {  # $1=name $2=ip $3=port $4=uuid $5=pubkey(忽略) $6=sni(忽略) $7=shortid(忽略) $8=domain $9=path
  cat <<EOF
  - name: "xray-${1}"
    type: vless
    server: ${2}
    port: ${3}
    uuid: ${4}
    network: xhttp
    udp: true
    tls: true
    servername: ${8}
    xhttp-opts:
      path: ${9}
      mode: stream-up
EOF
}

gen_client_singbox_vless_xhttp() {  # $1=name $2=ip $3=port $4=uuid $5=pubkey(忽略) $6=sni(忽略) $7=shortid(忽略) $8=domain $9=path
  # 注意：sing-box 上游不支持 XHTTP（Xray 26.x h2 迁移后的形态），需 sing-box-extended/lx fork
  cat <<EOF
# sing-box 上游不支持 XHTTP（stream-up），请使用 sing-box-extended 或 sing-box-lx：
{
  "type": "vless",
  "tag": "xray-${1}",
  "server": "${2}",
  "server_port": ${3},
  "uuid": "${4}",
  "tls": {
    "enabled": true,
    "server_name": "${8}"
  },
  "transport": {
    "type": "xhttp",
    "host": "${8}",
    "path": "${9}",
    "mode": "stream-up"
  }
}
EOF
}

gen_client_mihomo_hysteria2() {  # $1=name $2=ip $3=port $4=password $5=domain $6=brutal_up $7=brutal_down
  cat <<EOF
  - name: "xray-${1}"
    type: hysteria2
    server: ${2}
    port: ${3}
    password: ${4}
    sni: ${5:-${2}}
    skip-cert-verify: true
    alpn:
      - h3
EOF
  if [[ -n "${6:-}" && -n "${7:-}" ]]; then
    cat <<EOF
    up: ${6}
    down: ${7}
EOF
  fi
}

gen_client_singbox_hysteria2() {  # $1=name $2=ip $3=port $4=password $5=domain $6=brutal_up $7=brutal_down
  # BRUTAL 带宽字符串（如 "100 mbps"）→ sing-box 需数字（up_mbps/down_mbps）
  local up_num down_num
  up_num="$(echo "${6:-}" | grep -oE '^[0-9]+' || true)"
  down_num="$(echo "${7:-}" | grep -oE '^[0-9]+' || true)"
  cat <<EOF
{
  "type": "hysteria2",
  "tag": "xray-${1}",
  "server": "${2}",
  "server_port": ${3},
  "password": "${4}",
  "tls": {
    "enabled": true,
    "server_name": "${5:-${2}}",
    "insecure": true,
    "alpn": ["h3"]
  }
EOF
  if [[ -n "$up_num" && -n "$down_num" ]]; then
    cat <<EOF
  ,"up_mbps": ${up_num},
  "down_mbps": ${down_num}
EOF
  fi
  cat <<EOF
}
EOF
}

# 生成某协议的客户端片段（按类型分发）
gen_client_mihomo() {  # $1=type 其余参数透传
  local type="$1"; shift
  case "$type" in
    vless-reality) gen_client_mihomo_vless_reality "$@" ;;
    vless-xhttp|vless-h2) gen_client_mihomo_vless_xhttp "$@" ;;
    hysteria2) gen_client_mihomo_hysteria2 "$@" ;;
    *) die "未实现的客户端生成: ${type}" ;;
  esac
}

gen_client_singbox() {  # $1=type 其余参数透传
  local type="$1"; shift
  case "$type" in
    vless-reality) gen_client_singbox_vless_reality "$@" ;;
    vless-xhttp|vless-h2) gen_client_singbox_vless_xhttp "$@" ;;
    hysteria2) gen_client_singbox_hysteria2 "$@" ;;
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
            serverNames: [.sni], privateKey: .private_key, shortIds: (.short_ids // [.short_id])
          }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }' <<<"$json"
      ;;
    vless-xhttp|vless-h2)
      # VLESS + HTTP/2 (h2) + TLS：真实证书落地（域名需解析到本机）
      # Xray 26.x 起 h2 transport 已迁移至 XHTTP（method=xhttp），stream-up 模式即 HTTP/2 传输
      jq '{
        tag: .name, listen: "0.0.0.0", port: .port, protocol: "vless",
        settings: { clients: [{ id: .uuid }], decryption: "none" },
        streamSettings: {
          method: "xhttp", security: "tls",
          tlsSettings: {
            serverName: .domain,
            certificates: [{ certificateFile: .cert_file, keyFile: .key_file }]
          },
          xhttpSettings: { mode: "stream-up", path: .path, host: .domain }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }' <<<"$json"
      ;;
    hysteria2)
      # Hysteria 2：QUIC/UDP，官方默认端口 443（模拟 HTTP/3 流量）
      # Xray 协议名 hysteria + version 2
      # 坑（2026-08-16 真机实测）：inbound auth 必须在 settings.clients[].auth，
      # hysteriaSettings.auth 仅 outbound 有效（写那里 xray -test 通过但握手失败）
      # Xray 26.x 客户端已移除 allowInsecure → 自签证书需 pinnedPeerCertSha256（mihomo/sing-box 仍用 skip-cert-verify/insecure）
      # BRUTAL 拥塞控制（可选）：finalmask.quicParams.congestion=force-brutal + brutalUp/Down；
      # 服务端启用后客户端必须配套设置带宽（mihomo up/down、sing-box up_mbps/down_mbps），否则连接失败
      jq '{
        tag: .name, listen: "0.0.0.0", port: .port, protocol: "hysteria",
        settings: { version: 2, clients: [{ auth: .password }] },
        streamSettings: (
          {
            network: "hysteria", security: "tls",
            tlsSettings: {
              serverName: (.domain // ""), alpn: ["h3"],
              certificates: [{ certificateFile: .cert_file, keyFile: .key_file }]
            },
            hysteriaSettings: ({ version: 2 }
              + (if .masquerade then { masquerade: { type: "proxy", url: .masquerade } } else {} end))
          }
          + (if (.brutal_up != null and .brutal_down != null) then
              { finalmask: { quicParams: {
                  congestion: "force-brutal",
                  brutalUp: .brutal_up,
                  brutalDown: .brutal_down
                } } }
            else {} end)
        )
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
  # 注意：xray 26.x 按扩展名判断格式，.tmp 后缀会报 "Failed to get format"，必须显式 -format=json
  if "${BIN_PATH}" run -test -format=json -config "${CONFIG_FILE}.tmp" >/dev/null 2>&1; then
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
      sni: $sni, short_id: $sid, short_ids: [$sid]
    }'
}

proto_wizard_vless_xhttp() {  # $1=name → 输出 JSON 参数对象
  local name="$1" port domain path uuid certs cert_file key_file
  read -r -p "端口 [默认 8443]（443 被 REALITY 占用时用独立端口）: " port
  port="${port:-8443}"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
  port_in_use "$port" && die "端口 ${port} 已被占用"
  read -r -p "域名（必须已解析到本机）: " domain
  [[ -n "$domain" ]] || die "域名不能为空"
  read -r -p "HTTP/2 path [默认 /xray]: " path
  path="${path:-/xray}"
  [[ "$path" == /* ]] || die "path 必须以 / 开头"
  certs="$(obtain_cert "$domain")" || die "证书获取失败"
  cert_file="${certs%% *}"; key_file="${certs##* }"
  uuid="$(gen_uuid)"
  jq -n --arg name "$name" --argjson port "$port" --arg uuid "$uuid" \
    --arg domain "$domain" --arg path "$path" \
    --arg cert_file "$cert_file" --arg key_file "$key_file" '
    {
      name: $name, type: "vless-xhttp",
      port: $port, uuid: $uuid,
      domain: $domain, path: $path,
      cert_file: $cert_file, key_file: $key_file
    }'
}

proto_wizard_hysteria2() {  # $1=name → 输出 JSON 参数对象
  local name="$1" port domain password certs cert_file key_file masq yn conflict brutal_up brutal_down
  # 端口冲突处理：hy2 走 UDP，TCP 同端口被占（如 reality 443）不冲突可共存；
  # UDP 端口真被占（其他 hy2/服务）才提示卸载或取消
  read -r -p "端口 [默认 443/UDP]（hy2 官方建议 443，模拟 HTTP/3；TCP 同端口被 REALITY 占用可共存）: " port
  port="${port:-443}"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
  if port_in_use "$port" udp; then
    conflict="$(jq -r --argjson p "$port" '.protocols[] | select(.port==$p) | .name' "$STATE_FILE" 2>/dev/null | head -1 || true)"
    if [[ -n "$conflict" ]]; then
      log_warn "端口 ${port}/UDP 已被协议 ${conflict} 占用"
      read_input "是否卸载协议 ${conflict} 后继续？[y/N]: " yn
      if [[ "${yn,,}" == "y" ]]; then
        state_set --arg n "$conflict" '.protocols = [.protocols[] | select(.name != $n)]'
        rebuild_and_reload
        log_info "已卸载 ${conflict}"
      else
        die "端口 ${port} 冲突，安装取消（可换端口重试）"
      fi
    else
      log_warn "端口 ${port}/UDP 被非 xray-deploy 服务占用"
      read_input "是否继续？[y/N]: " yn
      [[ "${yn,,}" == "y" ]] || die "安装取消"
    fi
  else
    log_info "UDP ${port} 空闲（TCP 同端口占用不影响，TCP/UDP 独立）"
  fi
  ensure_firewall "$port" udp
  read -r -p "SNI/域名（自签证书时客户端 insecure，可填域名或回车用 IP）: " domain
  domain="${domain:-}"
  read -r -p "密码 [回车自动生成]: " password
  if [[ -z "$password" ]]; then
    password="$(openssl rand -base64 18 | tr -d '=+/' | head -c 24)"
  fi
  certs="$(obtain_cert "${domain:-localhost}")" || die "证书获取失败"
  cert_file="${certs%% *}"; key_file="${certs##* }"
  read -r -p "masquerade 伪装 URL（可选，如 https://www.bing.com，回车跳过）: " masq
  masq="${masq:-}"
  # BRUTAL 拥塞控制：服务端 + 客户端必须配套设置 up/down（客户端不设会连接失败）
  read -r -p "BRUTAL 上行带宽（如 100 mbps，回车不启用）: " brutal_up
  brutal_up="$(normalize_bandwidth "${brutal_up:-}")"
  read -r -p "BRUTAL 下行带宽（如 100 mbps，回车不启用）: " brutal_down
  brutal_down="$(normalize_bandwidth "${brutal_down:-}")"
  if [[ -n "$brutal_up" || -n "$brutal_down" ]]; then
    [[ -n "$brutal_up" && -n "$brutal_down" ]] || die "BRUTAL 需同时设置上行与下行带宽"
    log_warn "BRUTAL 启用：客户端（mihomo up/down、sing-box up_mbps/down_mbps）必须同步设置，否则连接失败"
  fi
  jq -n --arg name "$name" --argjson port "$port" --arg password "$password" \
    --arg domain "$domain" --arg cert_file "$cert_file" --arg key_file "$key_file" \
    --arg masq "$masq" --arg brutal_up "$brutal_up" --arg brutal_down "$brutal_down" '
    {
      name: $name, type: "hysteria2",
      port: $port, password: $password,
      domain: $domain,
      cert_file: $cert_file, key_file: $key_file
    }
    + (if ($masq != "") then { masquerade: $masq } else {} end)
    + (if ($brutal_up != "" and $brutal_down != "") then { brutal_up: $brutal_up, brutal_down: $brutal_down } else {} end)'
}

proto_add() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装，先运行: xray-deploy.sh install"
  local name type
  echo "可选协议类型:"
  local i=1 line disp
  for line in "${PROTO_REGISTRY[@]}"; do
    IFS='|' read -r _ disp _ <<<"$line"
    echo "  $i) $disp"
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
    vless-xhttp|vless-h2) params="$(proto_wizard_vless_xhttp "$name")" || die "协议参数生成失败" ;;
    hysteria2) params="$(proto_wizard_hysteria2 "$name")" || die "协议参数生成失败" ;;
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
  read -r -p "输入要删除的协议名称或序号: " name
  name="$(resolve_proto_name "$name")" || return 1
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
  read -r -p "输入要修改的协议名称或序号: " name
  name="$(resolve_proto_name "$name")" || return 1
  local idx type
  idx="$(jq --arg n "$name" '[.protocols[] | select(.name==$n)] | length' "$STATE_FILE")"
  [[ "$idx" -eq 1 ]] || die "协议 ${name} 不存在"
  type="$(jq -r --arg n "$name" '.protocols[] | select(.name==$n) | .type' "$STATE_FILE")"
  echo "修改 ${name}（${type}）:"
  echo "  1) 端口"
  if [[ "$type" == "vless-xhttp" || "$type" == "vless-h2" ]]; then
    echo "  2) 域名（需同步更新证书/客户端）"
  elif [[ "$type" == "hysteria2" ]]; then
    echo "  2) SNI/域名（重签证书）"
  else
    echo "  2) 回落域名(SNI)"
  fi
  if [[ "$type" == "hysteria2" ]]; then
    echo "  3) 重新生成密码"
    echo "  4) BRUTAL 带宽（回车清空禁用）"
    echo "  5) masquerade 伪装 URL（回车清空禁用）"
  else
    echo "  3) 重新生成 UUID"
  fi
  read -r -p "选择 [1-5]: " sel
  case "${sel:-1}" in
    1)
      local port
      read -r -p "新端口: " port
      [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
      if [[ "$type" == "hysteria2" ]]; then
        port_in_use "$port" udp && die "端口 ${port}/UDP 已被占用"
        ensure_firewall "$port" udp
      else
        port_in_use "$port" && die "端口 ${port} 已被占用"
      fi
      state_set --arg n "$name" --argjson port "$port" \
        '.protocols = [.protocols[] | if .name==$n then .port=$port else . end]'
      ;;
    2)
      if [[ "$type" == "vless-xhttp" || "$type" == "vless-h2" ]]; then
        local domain certs cert_file key_file
        read -r -p "新域名: " domain
        [[ -n "$domain" ]] || die "域名不能为空"
        certs="$(obtain_cert "$domain")" || die "证书获取失败"
        cert_file="${certs%% *}"; key_file="${certs##* }"
        state_set --arg n "$name" --arg domain "$domain" --arg cert_file "$cert_file" --arg key_file "$key_file" \
          '.protocols = [.protocols[] | if .name==$n then (.domain=$domain | .cert_file=$cert_file | .key_file=$key_file) else . end]'
      elif [[ "$type" == "hysteria2" ]]; then
        local domain certs cert_file key_file
        read -r -p "新 SNI/域名: " domain
        certs="$(obtain_cert "${domain:-localhost}")" || die "证书获取失败"
        cert_file="${certs%% *}"; key_file="${certs##* }"
        state_set --arg n "$name" --arg domain "$domain" --arg cert_file "$cert_file" --arg key_file "$key_file" \
          '.protocols = [.protocols[] | if .name==$n then (.domain=$domain | .cert_file=$cert_file | .key_file=$key_file) else . end]'
      else
        local sni
        sni="$(select_fallback_domain)" || die "回落域名选择失败"
        state_set --arg n "$name" --arg sni "$sni" \
          '.protocols = [.protocols[] | if .name==$n then .sni=$sni else . end]'
      fi
      ;;
    3)
      if [[ "$type" == "hysteria2" ]]; then
        local password
        password="$(openssl rand -base64 18 | tr -d '=+/' | head -c 24)"
        state_set --arg n "$name" --arg password "$password" \
          '.protocols = [.protocols[] | if .name==$n then .password=$password else . end]'
      else
        local uuid
        uuid="$(gen_uuid)"
        state_set --arg n "$name" --arg uuid "$uuid" \
          '.protocols = [.protocols[] | if .name==$n then .uuid=$uuid else . end]'
      fi
      ;;
    4)
      [[ "$type" == "hysteria2" ]] || die "无效选择"
      local brutal_up brutal_down
      read -r -p "BRUTAL 上行带宽（如 100 mbps，回车禁用 BRUTAL）: " brutal_up
      brutal_up="$(normalize_bandwidth "${brutal_up:-}")"
      read -r -p "BRUTAL 下行带宽（如 100 mbps，回车禁用 BRUTAL）: " brutal_down
      brutal_down="$(normalize_bandwidth "${brutal_down:-}")"
      if [[ -n "$brutal_up" || -n "$brutal_down" ]]; then
        [[ -n "$brutal_up" && -n "$brutal_down" ]] || die "BRUTAL 需同时设置上行与下行带宽"
        log_warn "BRUTAL 启用：客户端（mihomo up/down、sing-box up_mbps/down_mbps）必须同步设置，否则连接失败"
        state_set --arg n "$name" --arg brutal_up "$brutal_up" --arg brutal_down "$brutal_down" \
          '.protocols = [.protocols[] | if .name==$n then (.brutal_up=$brutal_up | .brutal_down=$brutal_down) else . end]'
      else
        state_set --arg n "$name" \
          '.protocols = [.protocols[] | if .name==$n then del(.brutal_up, .brutal_down) else . end]'
        log_info "BRUTAL 已禁用（客户端需移除 up/down 或 up_mbps/down_mbps）"
      fi
      ;;
    5)
      [[ "$type" == "hysteria2" ]] || die "无效选择"
      local masq
      read -r -p "masquerade 伪装 URL（如 https://www.bing.com，回车清空禁用）: " masq
      masq="${masq:-}"
      if [[ -n "$masq" ]]; then
        state_set --arg n "$name" --arg masq "$masq" \
          '.protocols = [.protocols[] | if .name==$n then .masquerade=$masq else . end]'
        log_info "masquerade 已设置: ${masq}"
      else
        state_set --arg n "$name" \
          '.protocols = [.protocols[] | if .name==$n then del(.masquerade) else . end]'
        log_info "masquerade 已清空"
      fi
      ;;
    *) die "无效选择" ;;
  esac
  rebuild_and_reload
  log_info "协议 ${name} 已更新"
}

proto_list_names() {
  log_info "现有协议:"
  jq -r '.protocols | to_entries[] | "  [\(.key+1)] \(.value.name)  (\(.value.type))  端口 \(.value.port)\(if .value.type == "hysteria2" then "/UDP" else "" end)  \(if (.value.type == "vless-xhttp" or .value.type == "vless-h2") then "域名 " + .value.domain elif .value.type == "hysteria2" then "SNI " + (.value.domain // "-") else "SNI " + .value.sni end)"' "$STATE_FILE"
}

# 解析协议选择：支持序号（[1]）或名称；输出协议 name；找不到 die
resolve_proto_name() {  # $1=输入
  local input="$1" name
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    name="$(jq -r --argjson i "$((input-1))" '.protocols[$i].name // ""' "$STATE_FILE")"
    [[ -n "$name" ]] || die "序号 ${input} 无效"
    echo "$name"
  else
    [[ -n "$input" ]] || die "名称不能为空"
    local count
    count="$(jq --arg n "$input" '[.protocols[] | select(.name==$n)] | length' "$STATE_FILE")"
    [[ "$count" -eq 1 ]] || die "协议 ${input} 不存在"
    echo "$input"
  fi
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

  # 选择部署协议（回车默认 1 = VLESS-TCP-XTLS-Vision-REALITY）
  echo "可选部署协议:"
  local i=1 line disp
  for line in "${PROTO_REGISTRY[@]}"; do
    IFS='|' read -r _ disp _ <<<"$line"
    echo "  $i) $disp"
    i=$((i+1))
  done
  read -r -p "选择部署协议 [1-$((i-1))，回车默认 1（VLESS-TCP-XTLS-Vision-REALITY）]: " t
  t="${t:-1}"
  [[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" -ge 1 ]] && [[ "$t" -le "$((i-1))" ]] || die "无效选择"
  local type="${PROTO_REGISTRY[$((t-1))]%%|*}"

  local name="${type}-01"
  local params
  case "$type" in
    vless-reality) params="$(proto_wizard_vless_reality "$name")" || die "协议参数生成失败" ;;
    vless-xhttp)   params="$(proto_wizard_vless_xhttp "$name")" || die "协议参数生成失败" ;;
    hysteria2)     params="$(proto_wizard_hysteria2 "$name")" || die "协议参数生成失败" ;;
    *) die "未知协议类型: $type" ;;
  esac
  state_set --argjson p "$params" '.protocols = [$p]'

  install_service_file
  rebuild_and_reload
  service_start
  log_info "安装完成！运行 'xray-deploy.sh info' 查看节点信息"
  log_info "geo 数据更新: 运行 'xray-deploy update-geo'（手动，或自行配 systemd timer）"
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
  local i name type port uuid pub sni sid domain path cert_file password brutal_up brutal_down
  for i in $(jq -r '.protocols | keys[]' "$STATE_FILE"); do
    name="$(jq -r ".protocols[$i].name" "$STATE_FILE")"
    type="$(jq -r ".protocols[$i].type" "$STATE_FILE")"
    port="$(jq -r ".protocols[$i].port" "$STATE_FILE")"
    uuid="$(jq -r ".protocols[$i].uuid // \"\"" "$STATE_FILE")"
    pub="$(jq -r ".protocols[$i].public_key // \"\"" "$STATE_FILE")"
    sni="$(jq -r ".protocols[$i].sni // \"\"" "$STATE_FILE")"
    sid="$(jq -r ".protocols[$i].short_id // \"\"" "$STATE_FILE")"
    domain="$(jq -r ".protocols[$i].domain // \"\"" "$STATE_FILE")"
    path="$(jq -r ".protocols[$i].path // \"\"" "$STATE_FILE")"
    cert_file="$(jq -r ".protocols[$i].cert_file // \"\"" "$STATE_FILE")"
    password="$(jq -r ".protocols[$i].password // \"\"" "$STATE_FILE")"
    brutal_up="$(jq -r ".protocols[$i].brutal_up // \"\"" "$STATE_FILE")"
    brutal_down="$(jq -r ".protocols[$i].brutal_down // \"\"" "$STATE_FILE")"
    echo "----------------------------------------------"
    echo "协议: ${name}  (${type})"
    echo "地址: ${ip}:${port}"
    if [[ "$type" == "hysteria2" ]]; then
      echo "传输: UDP/QUIC (Hysteria2)"
      echo "密码: ${password}"
      [[ -n "$domain" ]] && echo "SNI: ${domain}"
      echo "证书: ${cert_file}"
      [[ -n "$brutal_up" && -n "$brutal_down" ]] && echo "BRUTAL: up=${brutal_up} down=${brutal_down}"
    else
      echo "UUID: ${uuid}"
    fi
    if [[ "$type" == "vless-reality" ]]; then
      echo "SNI: ${sni}"
    elif [[ "$type" == "vless-xhttp" || "$type" == "vless-h2" ]]; then
      echo "域名: ${domain}  path: ${path}"
      echo "证书: ${cert_file}"
    fi
    echo
    echo "--- mihomo (Clash Meta) proxies 片段 ---"
    if [[ "$type" == "hysteria2" ]]; then
      gen_client_mihomo_hysteria2 "$name" "$ip" "$port" "$password" "$domain" "$brutal_up" "$brutal_down"
    else
      gen_client_mihomo "$type" "$name" "$ip" "$port" "$uuid" "$pub" "$sni" "$sid" "$domain" "$path"
    fi
    echo
    echo "--- sing-box outbounds 片段 ---"
    if [[ "$type" == "hysteria2" ]]; then
      gen_client_singbox_hysteria2 "$name" "$ip" "$port" "$password" "$domain" "$brutal_up" "$brutal_down"
    else
      gen_client_singbox "$type" "$name" "$ip" "$port" "$uuid" "$pub" "$sni" "$sid" "$domain" "$path"
    fi
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
      if "${BIN_PATH}" run -test -format=json -config "$CONFIG_FILE" >/dev/null 2>&1; then
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

# ============ 回落域名测试（独立功能） ============
# 测试候选回落域名的握手延迟并排序，供部署前选型/诊断用（不影响部署状态）
cmd_fallback_test() {  # $1=可选域名（测单个）；无参 = 测全部候选
  local target="${1:-}" dom c t note i result delay
  local -a pass_list=() fail_list=()

  log_info "回落域名握手延迟测试（TLS1.3+H2+X25519+非跳转+非Cloudflare）..."

  if [[ -n "$target" ]]; then
    # 单域名模式：直接测试指定域名
    # || true：函数失败(return 1)时命令替换会触发 set -e，必须显式吞掉
    result="$(test_fallback_domain "$target")" || true
    if [[ "$result" == "ok" ]]; then
      delay="$(measure_handshake_ms "$target")" || true
      pass_list+=("$target|自定义|$delay")
      log_info "  ✓ ${target} — ${delay}ms"
    else
      fail_list+=("$target")
      log_warn "  ✗ ${target} — ${result}"
    fi
  else
    # 全部候选模式：逐个测试并立即显示结果（避免长耗时无反馈）
    for line in "${FALLBACK_CANDIDATES[@]}"; do
      IFS='|' read -r dom c t note <<<"$line"
      log_info "  → ${dom}  (${note}) 测试中..."
      result="$(test_fallback_domain "$dom")" || true
      if [[ "$result" == "ok" ]]; then
        delay="$(measure_handshake_ms "$dom")" || true
        pass_list+=("$dom|$note|$delay")
        log_info "  ✓ ${dom}  (${note}) — ${delay}ms"
      else
        fail_list+=("$dom")
        log_warn "  ✗ ${dom} — ${result}"
      fi
    done
  fi

  # 按延迟排序展示通过的
  if [[ ${#pass_list[@]} -gt 0 ]]; then
    IFS=$'\n' pass_list=($(printf '%s\n' "${pass_list[@]}" | sort -t'|' -k3,3n)); unset IFS
    log_info "通过候选按握手延迟排序（最低在前）:"
    for ((i=0; i<${#pass_list[@]}; i++)); do
      IFS='|' read -r dom note delay <<<"${pass_list[$i]}"
      log_info "  [$((i+1))] ${dom}  (${note}) ✓ ${delay}ms"
    done
  else
    log_err "无候选通过测试"
  fi

  [[ ${#pass_list[@]} -gt 0 ]]
}

# ============ 子命令分发 ============
CMD="${1:-menu}"
case "$CMD" in
  -v|--version|-V)  echo "xray-deploy ${VERSION}"; exit 0 ;;
  -h|--help)        cat <<EOF
xray-deploy ${VERSION} — Xray 一键部署/管理（vps-tools 生态）

用法:
  xray-deploy                      交互式管理菜单
  sudo xray-deploy install         首次部署向导（选协议 → 参数 → 服务；默认 VLESS-TCP-XTLS-Vision-REALITY）
  xray-deploy info                 查看节点信息（明文 + 客户端配置片段）
  xray-deploy config show|edit     查看/编辑服务端配置（edit 后自动 -test 校验并重载）
  xray-deploy fallback-test [域名] 测试回落域名握手延迟并排序（无参=全部候选）
  sudo xray-deploy update-geo      更新 geosite/geoip（或自行配 systemd timer）
  sudo xray-deploy upgrade         升级 Xray 二进制（失败自动回滚）
  sudo xray-deploy status|restart|uninstall
  sudo xray-deploy protocol add|remove|edit|list   多协议管理（vless-reality / vless-xhttp / hysteria2）
  xray-deploy -v, --version        显示版本号
  xray-deploy -h, --help           显示本帮助

协议说明:
  vless-reality  VLESS-TCP-XTLS-Vision-REALITY（默认，无需证书，回落伪装）
  vless-xhttp    VLESS-XHTTP-H2-TLS（真实证书落地，域名需解析到本机；证书可已有路径/acme.sh 自动签发/自签）
                 Xray 26.x 起 h2 transport 迁移至 XHTTP stream-up（HTTP/2）；mihomo 需 v1.19.23+，sing-box 需 extended/lx fork
                 （旧名 vless-h2 兼容，1.3.0 起统一为 vless-xhttp）
  hysteria2      Hysteria2 (hy2)（QUIC/UDP，官方默认端口 443 模拟 HTTP/3；自签证书+客户端 insecure，无需 CF token）
                 TCP/UDP 端口独立：与 REALITY 的 TCP 443 可共存；UDP 端口被占时向导会提示是否卸载冲突协议
EOF
      exit 0 ;;
  install)       cmd_install ;;
  info)          cmd_info ;;
  config)        cmd_config "${2:-show}" ;;
  fallback-test) cmd_fallback_test "${2:-}" ;;
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
  *) die "未知命令: $CMD（支持 install/info/config/fallback-test/update-geo/upgrade/status/restart/uninstall/protocol）" ;;
esac

# ============ 交互菜单 ============
if [[ "$CMD" == "menu" ]]; then
  while true; do
    echo
    echo "===== Xray 部署管理 ====="
    echo "  1) 安装/更新 Xray（首次部署向导）"
    echo "  2) 协议管理（新增/删除/修改）"
    echo "  3) 查看节点信息 (info)"
    echo "  4) 回落域名测试 (fallback-test)"
    echo "  5) 更新 geo 数据 (geosite/geoip)"
    echo "  6) 升级 Xray 版本"
    echo "  7) 查看/编辑配置 (config)"
    echo "  8) 服务状态"
    echo "  9) 重启服务"
    echo "  10) 卸载"
    echo "  0) 退出"
    read_input "请选择 [0-10]: " choice || { log_warn "无交互终端，已退出"; break; }
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
      4)
        echo "  1) 测试全部候选  2) 测试指定域名"
        read_input "选择 [1-2]: " fc || { log_warn "无交互终端"; continue; }
        case "${fc:-1}" in
          1) cmd_fallback_test ;;
          2)
            read_input "输入要测试的域名: " fdom || { log_warn "无交互终端"; continue; }
            cmd_fallback_test "$fdom"
            ;;
          *) log_warn "无效选择" ;;
        esac
        ;;
      5) update_geo ;;
      6) cmd_upgrade ;;
      7)
        echo "  1) 查看配置  2) 编辑配置"
        read_input "选择 [1-2]: " cc || { log_warn "无交互终端"; continue; }
        case "${cc:-1}" in
          1) cmd_config show ;;
          2) cmd_config edit ;;
          *) log_warn "无效选择" ;;
        esac
        ;;
      8) need_root; service_status ;;
      9) need_root; service_restart ;;
      10) cmd_uninstall ;;
      0) break ;;
      *) log_warn "无效选择" ;;
    esac
  done
fi

exit 0
