[DEFAULT]
# 忽略的 IP（白名单，建议加上你的常用固定 IP）
ignoreip = 127.0.0.1/8 ::1

# 封禁时长 1 天；10 分钟内 5 次失败则封禁
bantime  = 1d
findtime = 10m
maxretry = 5

# backend 由 vps-init 探测（Debian 12/13 = systemd，有 auth.log = auto）
backend = __F2B_BACKEND__

# 递增封禁：多次解封后再攻击，封禁时间翻倍，上限 5 周
bantime.increment = true
bantime.maxtime = 5w

# 封禁动作（由 vps-init 探测：已装 ufw 用 ufw，否则 nftables）
banaction = __F2B_BANACTION__

# --------------------------------------------------
# SSH 防御规则
# --------------------------------------------------
[sshd]
enabled = true

# 当前 SSH 端口（由 vps-init 注入）
port = __SSH_PORT__

# 探测模式：normal(标准), ddos, extra, aggressive(严格/推荐)
mode = aggressive
