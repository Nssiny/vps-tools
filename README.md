# vps-tools

个人 VPS 运维脚本集。全部脚本通过 `install.sh` 一键安装/更新/卸载，脚本内敏感信息一律使用 `${PLACEHOLDER}` 占位符，真实密钥只存在于各机器 `/etc/*.env` 配置文件中，不入库。

## 快速开始

### 方式一：一键安装 + 交互式管理（推荐）

SSH 登录 VPS 后直接运行，自动安装管理命令 `vps-tools` 并进入交互菜单（安装/更新/卸载/查看工具均可选择）：

```bash
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s --
```

```
===== vps-tools 管理 =====
  1) 安装工具（选择）
  2) 更新工具（选择）
  3) 卸载工具（选择）
  4) 查看工具
  5) 更新 vps-tools 自身
  0) 退出
请选择 [0-5]:
```

> 管道方式（curl | sudo bash）下 stdin 被 curl 占用，脚本会自动改从 `/dev/tty` 读取输入，**交互菜单依然可用**。

安装完成后，之后的管理直接运行：

```bash
sudo vps-tools          # 进入交互式管理菜单
sudo vnstat-monitor     # 直接调用工具（等价于 xray-deploy 等工具名）
sudo xray-deploy        # Xray 部署/管理入口
```

### 方式二：命令行指定工具（脚本/CI 场景）

```bash
# 安装/更新指定工具（重复执行即覆盖更新，配置保留）
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install vnstat-monitor
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install xray-deploy

# 卸载（脚本删除，配置保留防误删密钥）
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- uninstall vnstat-monitor

# 查看可用工具（list 不需要 root）
bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) list

# 本地已下载时
sudo bash install.sh install vnstat-monitor
```

> **关于 root**：`install/update/uninstall` 必须 root。管道方式 `curl | sudo bash -s --` 自动以 root 运行（普通用户登录的 VPS 也能用）；非 root 直接运行会提示并给出完整 sudo 命令。
> **关于交互**：无参数运行进入交互管理菜单；纯 CI/无终端环境请用方式二指定工具，避免卡在输入等待。

## 安装器行为

- 脚本下载到 `/usr/local/lib/vps-tools/<tool>/`，与系统文件隔离，卸载即删目录
- 每个工具自动生成命令入口 `/usr/local/bin/<tool>`，**直接以工具名调用**（如 `vnstat-monitor`、`xray-deploy`、`vps-tools`）
- 首次安装自动生成配置模板 `/etc/<tool>.env`（`chmod 600`，已存在不覆盖），**需手动填入真实密钥**
- 定时调度统一用 **systemd timer**（工具 `setup` 子命令管理，如 `vnstat-monitor setup`），不使用 crontab
- 重复 `install` = 覆盖更新，幂等

## 仓库结构（按功能域分类）

### 工具开发约定（新增工具必须遵守）

- **版本号**：脚本头部定义 `VERSION="x.y.z"`，发布新功能时递增
- **`-v`/`--version`/`-V`**：输出 `<工具名> <版本号>`（如 `vnstat-monitor 1.0.0`）
- **`-h`/`--help`**：输出用法说明（子命令清单 + 示例）
- **定时调度**：统一用 systemd timer（工具 `setup` 子命令管理），不使用 crontab
- **配置**：`/etc/<tool>.env`（600 权限，模板含 `${PLACEHOLDER}` 占位符，真实密钥本机填写）

```
vps-tools/
├── install.sh          # 一键安装/更新/卸载器（工具注册表在文件头 TOOLS）
├── README.md
├── monitor/            # 监控类（流量/资源/服务状态）
│   └── vnstat-monitor/
│       ├── vnstat-monitor.sh
│       └── vnstat-monitor.env.example
├── network/            # 网络类（路由/隧道/分流）
├── proxy/              # 代理类（xray/sing-box 等辅助脚本）
│   └── xray-deploy/
│       └── xray-deploy.sh
├── utils/              # 通用工具（DDNS/证书等）
└── backup/             # 备份类
```

新增脚本：按功能域放入对应目录 + 在 `install.sh` 的 `TOOLS` 注册表加一行（格式见文件头注释）。

## 工具清单

| 工具 | 分类 | 用途 | 依赖 |
|---|---|---|---|
| [vnstat-monitor](monitor/vnstat-monitor/) | monitor | vnStat + Telegram 流量监控：进度条/偏移校准/熔断关机/无限流量模式；原地更新消息防刷屏（2026-08-08 修复孤儿卡片：错误分类+原子写状态） | vnstat, jq, curl, gawk, iproute2 |
| [xray-deploy](proxy/xray-deploy/) | proxy | Xray 一键部署：交互菜单/子命令双模式；协议注册表可扩展（VLESS-TCP-XTLS-Vision-REALITY 默认 / VLESS-XHTTP-H2-TLS / Hysteria2 hy2）；回落域名半自动筛选；MetaCubeX geosite/geoip 每周自动更新；生成 mihomo/sing-box 客户端节点；服务端 routing 防国内访问 | curl, unzip, jq, openssl |

## 工具使用教程

### vnstat-monitor — vnStat 流量监控（Telegram 推送）

```bash
sudo vnstat-monitor            # 手动跑一次（首次会初始化 vnstat 数据库）
```

1. 安装后编辑配置，填入 Telegram Bot Token 与 Chat ID：
   ```bash
   sudo nano /etc/vnstat-monitor.env
   ```
   `VPS_NAME`（显示名）、`TG_BOT_TOKEN`、`TG_CHAT_ID` 为必填；`LIMIT_GB`（流量上限，超过触发提醒）、`AUTO_SHUTDOWN`（超过上限是否关机）、`INTERVAL_MINUTES`（触发频率，分钟，默认 15）按需配置。
2. 手动验证：`sudo vnstat-monitor`，应收到一条 Telegram 流量卡片。
3. **设置定时（systemd timer，替代 crontab）**——安装时若交互安装会自动调用，也可手动：
   ```bash
   sudo vnstat-monitor setup              # 交互式：设置频率 + 安装 timer
   # 或直接指定频率：
   sudo vnstat-monitor install-timer 30   # 每 30 分钟
   ```
4. 修改触发频率（配置持久化 + timer 自动重载）：
   ```bash
   sudo vnstat-monitor set-interval 30    # 改为每 30 分钟
   sudo vnstat-monitor timer-status       # 查看 timer 状态
   sudo vnstat-monitor uninstall-timer    # 移除定时（保留配置与脚本）
   ```
   > 旧版本用 crontab（`*/15 * * * * /usr/local/bin/vnstat-monitor`）的机器，`uninstall-timer` 之外还需手动删除 crontab 中对应行。

### xray-deploy — Xray 代理服务部署

```bash
sudo xray-deploy               # 交互菜单（推荐，所有操作都从这进）
```

常用子命令（等价的非交互形式）：

```bash
sudo xray-deploy install       # 首次部署向导：选回落域名 → 生成密钥 → 装 systemd/OpenRC 服务
xray-deploy info               # 查看节点信息（明文 + mihomo/sing-box 客户端配置片段，无需 root）
xray-deploy config show        # 查看服务端 config.json
sudo xray-deploy config edit   # 编辑 config.json（保存后自动 xray -test 校验并重载）
xray-deploy fallback-test      # 测试全部回落候选的握手延迟并排序（部署前选型/诊断用）
xray-deploy fallback-test www.example.com   # 测试指定域名是否可作回落
sudo xray-deploy update-geo    # 手动更新 geosite/geoip（如需自动更新，可自行配 systemd timer）
sudo xray-deploy upgrade       # 升级 Xray 二进制（失败自动回滚）
sudo xray-deploy protocol add/remove/edit/list   # 多协议管理（端口/SNI/UUID）
sudo xray-deploy status / restart / uninstall
```

部署流程：
1. `sudo xray-deploy` → 选 1 安装：按提示选端口（默认 443）、回落域名（自动测试+排序，可输自有域名）。
2. `xray-deploy info` 查看生成结果，把 mihomo / sing-box 片段填入客户端。
3. 节点信息持久化在 `/etc/xray-deploy/state.json`（600 权限，含私钥，**勿外泄**）。

> 回落域名测试在 VPS 上实时进行（TLS1.3 + H2 + X25519 + 非跳转 + 非 Cloudflare）；若全部失败会干净退出，不会产生半成品。

## 安全约定

- 仓库内禁止提交任何真实 Token / 密钥 / Cookie，一律 `${PLACEHOLDER}`
- 配置模板（`.env.example`）可入库；实际配置 `/etc/<tool>.env` 绝不入库
- 如需在 CI 等场景使用密钥，走 GitHub Actions Secrets，禁止写死进脚本

## 开发

新增工具三步：

1. 建目录 `mkdir <分类>/<tool>/`（分类见上方结构图），放脚本 + `*.env.example`
2. 在 `install.sh` 的 `TOOLS` 注册表追加一行（格式见文件头注释，路径带分类前缀）
3. 更新本 README 工具清单
