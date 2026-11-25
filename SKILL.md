---
name: lan-network-sharing
description: 在 Windows 上把本机网络共享给同一局域网的设备（gost 带认证的 HTTP/SOCKS 代理 + 防火墙限网段 + 登录自启计划任务），并在客户端（Windows / iPhone / Android）用系统代理、Clash Verge TUN、Proxifier 或 VPN 客户端接入，使浏览器和 App 的流量都走这台机器。适用于：把我的网络共享给室友/另一台电脑/手机、用这台电脑当代理、让 App 也走代理、共享后只有浏览器能用、407 Proxy Authentication Required、ERR_PROXY_CONNECTION_FAILED、安卓填不了代理密码、Portal 认证 MAC 绑定错误等场景。仅覆盖 Windows 服务端与同网段客户端，不做 NAT 网关、不改 MAC、不绕过校园网认证。
---

# 局域网网络共享与代理接入

把一台 Windows 机器的网络出口借给同网段的其他设备，并让对方的 App（不只是浏览器）也走这条链路。整个流程分三段：服务端搭建 → 客户端接入 → 双向验证；出问题先读 `references/troubleshooting.md`。

## 先判定场景

| 用户诉求 | 走哪段 |
|---|---|
| 把网络共享给别人 / 给室友供网 / 用这台机当代理 | 服务端 |
| 别人能上网了，但 App 用不了 | 客户端（TUN 环节） |
| 弹 407、打不开网页、部分网站失败、Portal 报 MAC 绑定错误 | 排障 |

## 硬性前提（必须先确认，否则做出来的东西用不了）

1. **单网口做不了 NAT 网关**。Windows 的 ICS（连接共享）强制要求两块网卡（WAN 侧 + LAN 侧）。只有一块物理网口时，唯一可行的是“带认证的代理 + 客户端主动配置”。要“插网线就上网、所有 App 天然走”，只有加 USB 网卡、或用路由器/随身 Wi‑Fi。
2. **客户端必须与服务端同网段**。校园网/宿舍网常见 AP 客户端隔离，同 SSID 也可能互访不通——先按“验证”段测端口连通，再谈认证。
3. 服务端必须**开机且已登录**。关机、注销、睡眠都会断，代理进程和 ICS 都不存在。
4. 上游若按账号/设备数计费，他人流量记在共享者账号上；校园网多设备共享可能违反使用协议，需提示用户自行权衡。

## 服务端：在提供网络的那台 Windows 上

运行 `scripts/setup-share-server.ps1`（需管理员）。它会一次性完成：下载 gost → 生成账号密码 → 写启动脚本 → 加防火墙规则（仅限本机所在网段）→ 注册登录自启计划任务 → 启动并自测。

```powershell
# 默认端口 18080(HTTP) / 18081(SOCKS5)，账号 b404，密码自动生成
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1

# 指定端口与账号
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1 -Port 18080 -SocksPort 18081 -User b404 -Password 自定义密码
```

跑完会输出一张汇总：本机 IP、HTTP/SOCKS 端口、账号、密码、计划任务名、防火墙规则名、仅放行的网段。把这张表抄给客户端使用。

关键设计（不要擅自改动）：
- 监听 `0.0.0.0`，但**必须带认证**，否则同网段任何人都能借用出口。
- 防火墙规则把来源限制在服务端当前网段（如 `192.168.112.0/24`），跨网段直接连不上，比加认证更可靠。
- 自启走计划任务 `AtLogOn` + 启动脚本从 `pass.txt` 读密码，避免密码出现在命令行和任务参数里。

## 客户端：让浏览器和 App 都走代理

### 1. 浏览器/系统级（只覆盖读系统代理的程序）
填服务器与端口后，首次访问会弹“代理服务器需要身份验证”，输账号密码并勾选记住。Windows 设置页没有密码字段，不要在那里找。

### 2. Windows 上要让 App 走（关键）
- 推荐：`scripts/setup-client-clash.ps1` —— 自动在 Clash Verge 里生成一份“共享代理”配置（SOCKS5 优先、带 UDP）、切为当前配置、打开 TUN 与系统代理、备份原配置。
- 备选：Proxifier（只接管 TCP，按进程控制，收费）。
- 二者不能同时开，会抢流量。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-client-clash.ps1 -Server 192.168.112.32 -Port 18080 -SocksPort 18081 -User b404 -Password 密码
```

注意：脚本最后启动 Clash Verge 这一步**必须在正常用户环境执行**，受限环境里它会因为写不了单实例文件的安全描述符而报 `DACL is not protected`。若遇到该报错，关掉客户端、删掉配置目录下的 `singleton-instance*` 文件，再让用户从开始菜单手动启动一次即可。

### 3. 手机
- iPhone/iPad 原生支持：Wi‑Fi → 配置代理 → 手动 → 填服务器/端口 → 打开“认证”填账号密码。
- 安卓原生 Wi‑Fi 代理**没有认证字段**，带认证的代理填了也只会 407。必须装 v2rayNG / Clash Meta for Android，把服务端当作 `HTTP` 或 `SOCKS5` 节点（填账号密码），开 VPN/全局模式。

平台细节、Proxifier 与客户端节点的完整字段见 `references/client-setup.md`。

## 验证（两端各测一次，别靠“感觉能上网”）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify-share.ps1 -Server 192.168.112.32 -Port 18080 -User b404 -Password 密码
```

判定标准：
- 端口探测通 → 网络层可达（不通就是跨网段/AP 隔离/服务端没开）。
- 无凭据应返回 407、带凭据应 200 → 认证生效。
- 加 `-CheckTun`：`Meta` 网卡 Up、默认路由指向 198.18.0.2、DNS 返回 fake-ip、出口 IP 正常 → App 流量确实被接管。

## 排障

按报错对号入座，见 `references/troubleshooting.md`（407 / ERR_PROXY_CONNECTION_FAILED / ERR_TUNNEL_CONNECTION_FAILED / 部分网站失败 / App 不走代理 / 安卓无法认证 / Portal MAC 绑定错误 / 重启后没网）。

## 清理与回滚

```powershell
# 服务端
Stop-ScheduledTask -TaskName 'LAN Proxy (gost)'
Unregister-ScheduledTask -TaskName 'LAN Proxy (gost)' -Confirm:$false
Remove-NetFirewallRule -DisplayName 'LAN Proxy (gost)'
Remove-Item "$env:LOCALAPPDATA\lan-share" -Recurse -Force
```

客户端（Clash Verge）：恢复配置目录下 `.bak_*` 备份里的 `profiles.yaml` / `verge.yaml`，删除 `profiles\pclan.yaml`，并把 `profiles.yaml` 里的 `current` 改回原订阅。

## 安全与合规红线

- 代理必须带认证，且只对同网段放行；不要把账号密码发到群里或截图传播。
- 不要用改 MAC、模拟认证客户端等方式绕过校园网计费或设备限制——这类做法不予提供。
- 共享结束后提醒用户关闭计划任务，避免长期被他人借用出口。

## 环境差异备忘

- 脚本是 PowerShell 7 写法，在 Windows 客户端上运行；云主机（Linux）环境只能改文档、不能执行。
- 目标机器若没有无线网卡，`移动热点` 一律不可用，不要建议“开热点”。
- Clash Verge 配置目录固定为 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev`，安装目录需从注册表 `Uninstall` 项读取，不要写死 `C:\Program Files`。
