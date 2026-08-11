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

- 脚本下载到 `/usr/local/bin/<tool>/`，与系统文件隔离，卸载即删目录
- 首次安装自动生成配置模板 `/etc/<tool>.env`（`chmod 600`，已存在不覆盖），**需手动填入真实密钥**
- cron 条目只提示不自动写；**必须用 root crontab（`sudo crontab -e`）**——脚本要 source `/etc/<tool>.env`（600 权限）、写 `/var/lib`、改 `/etc` 配置、可能触发关机，普通用户 crontab 无权限
- 重复 `install` = 覆盖更新，幂等

## 仓库结构（按功能域分类）

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
| [xray-deploy](proxy/xray-deploy/) | proxy | Xray 一键部署：交互菜单/子命令双模式；VLESS-TCP-XTLS-Vision-REALITY 默认协议（协议注册表可扩展）；回落域名半自动筛选；MetaCubeX geosite/geoip 每周自动更新；生成 mihomo/sing-box 客户端节点；服务端 routing 防国内访问 | curl, unzip, jq, openssl |

## 安全约定

- 仓库内禁止提交任何真实 Token / 密钥 / Cookie，一律 `${PLACEHOLDER}`
- 配置模板（`.env.example`）可入库；实际配置 `/etc/<tool>.env` 绝不入库
- 如需在 CI 等场景使用密钥，走 GitHub Actions Secrets，禁止写死进脚本

## 开发

新增工具三步：

1. 建目录 `mkdir <分类>/<tool>/`（分类见上方结构图），放脚本 + `*.env.example`
2. 在 `install.sh` 的 `TOOLS` 注册表追加一行（格式见文件头注释，路径带分类前缀）
3. 更新本 README 工具清单
