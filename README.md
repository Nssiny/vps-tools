# vps-tools

个人 VPS 运维脚本集。全部脚本通过 `install.sh` 一键安装/更新/卸载，脚本内敏感信息一律使用 `${PLACEHOLDER}` 占位符，真实密钥只存在于各机器 `/etc/*.env` 配置文件中，不入库。

## 快速开始

```bash
# 安装全部工具
bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh)

# 安装/更新指定工具
bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) install vnstat-monitor
bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) update vnstat-monitor

# 卸载
bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) uninstall vnstat-monitor

# 查看可用工具
bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) list
```

## 安装器行为

- 脚本下载到 `/usr/local/bin/<tool>/`，与系统文件隔离，卸载即删目录
- 首次安装自动生成配置模板 `/etc/<tool>.env`（`chmod 600`，已存在不覆盖），**需手动填入真实密钥**
- cron 条目只提示不自动写（避免破坏现有 crontab）
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
├── utils/              # 通用工具（DDNS/证书等）
└── backup/             # 备份类
```

新增脚本：按功能域放入对应目录 + 在 `install.sh` 的 `TOOLS` 注册表加一行（格式见文件头注释）。

## 工具清单

| 工具 | 分类 | 用途 | 依赖 |
|---|---|---|---|
| [vnstat-monitor](monitor/vnstat-monitor/) | monitor | vnStat + Telegram 流量监控：进度条/偏移校准/熔断关机/无限流量模式；原地更新消息防刷屏（2026-08-08 修复孤儿卡片：错误分类+原子写状态） | vnstat, jq, curl, gawk, iproute2 |

## 安全约定

- 仓库内禁止提交任何真实 Token / 密钥 / Cookie，一律 `${PLACEHOLDER}`
- 配置模板（`.env.example`）可入库；实际配置 `/etc/<tool>.env` 绝不入库
- 如需在 CI 等场景使用密钥，走 GitHub Actions Secrets，禁止写死进脚本

## 开发

新增工具三步：

1. 建目录 `mkdir <分类>/<tool>/`（分类见上方结构图），放脚本 + `*.env.example`
2. 在 `install.sh` 的 `TOOLS` 注册表追加一行（格式见文件头注释，路径带分类前缀）
3. 更新本 README 工具清单
