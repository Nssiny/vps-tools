#!/usr/bin/env bash
# vps-init 模块：系统基础配置（时区 Asia/Shanghai + BBR + locale）
# 幂等：重复执行不重复追加/不报错

system_main() {
  # ---------- 时区 ----------
  log_info "配置时区 Asia/Shanghai"
  if [[ "$(cat /etc/timezone 2>/dev/null)" != "Asia/Shanghai" ]] \
     && ! timedatectl show -p Timezone --value 2>/dev/null | grep -q '^Asia/Shanghai$'; then
    timedatectl set-timezone Asia/Shanghai && log_info "时区已设置为 Asia/Shanghai"
  else
    log_info "时区已是 Asia/Shanghai，跳过"
  fi

  # ---------- locale ----------
  if command -v update-locale >/dev/null 2>&1; then
    if ! grep -q '^LANG=en_US.UTF-8' /etc/default/locale 2>/dev/null; then
      update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 && log_info "locale 已设置为 en_US.UTF-8"
    else
      log_info "locale 已是 en_US.UTF-8，跳过"
    fi
  fi

  # ---------- BBR ----------
  : "${VPS_INIT_BBR_CONF:=/etc/sysctl.d/99-vps-init-bbr.conf}"
  local BBR_CONF="$VPS_INIT_BBR_CONF"
  log_info "启用 BBR"
  local cur_qdisc cur_cc
  cur_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  cur_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if [[ "$cur_qdisc" == "fq" && "$cur_cc" == "bbr" ]]; then
    log_info "BBR 已生效（qdisc=${cur_qdisc} cc=${cur_cc}），跳过"
  else
    # 去重：文件不存在或内容不完整才写入
    if [[ ! -f "$BBR_CONF" ]] \
       || ! grep -q '^net.core.default_qdisc=fq$' "$BBR_CONF" \
       || ! grep -q '^net.ipv4.tcp_congestion_control=bbr$' "$BBR_CONF"; then
      printf '%s\n' \
        "net.core.default_qdisc=fq" \
        "net.ipv4.tcp_congestion_control=bbr" \
        > "$BBR_CONF"
      log_info "已写入 ${BBR_CONF}"
    fi
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1
    # 验证
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
      log_info "BBR 已启用"
    else
      log_warn "BBR 未生效（内核可能不支持，重启后重试）"
    fi
  fi

  state_done system
  log_info "系统基础配置完成"
}
