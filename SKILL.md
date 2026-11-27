---
name: lan-network-sharing
description: 在 Windows 上把本机网络共享给同一局域网的设备（gost 带认证的 HTTP/SOCKS 代理 + 防火墙限网段 + 登录自启计划任务），并在客户端（Windows / iPhone / Android）用系统代理、toci（campus-sni-proxy，内置 Mihomo TUN）、Clash Verge TUN、Proxifier 或 VPN 客户端接入，使浏览器和 App 的流量都走这台机器。适用于：把我的网络共享给室友/另一台电脑/手机、用这台电脑当代理、让 App 也走代理、共享后只有浏览器能用、407 Proxy Authentication Required、ERR_PROXY_CONNECTION_FAILED、协议探测失败 timed out、安卓填不了代理密码、Portal 认证 MAC 绑定错误等场景。仅覆盖 Windows 服务端与同网段客户端，不做 NAT 网关、不改 MAC、不绕过校园网认证。
---

# 局域网网络共享与代理接入

把一台 Windows 机器的网络出口借给同网段的其他设备，并让对方的 App（不只是浏览器）也走这条链路。整个流程分三段：服务端搭建 → 客户端接入 → 双向验证；出问题先读 `references/troubleshooting.md`。

## 先判定场景

| 用户诉求 | 走哪段 |
|---|---|
| 把网络共享给别人 / 给室友供网 / 用这台机当代理 | 服务端 |
| 别人能上网了，但 App 用不了 | 客户端（TUN 环节） |
| 已装 toci / campus-sni-proxy，想让它当客户端 | 客户端（toci 环节） |
| 弹 407、打不开网页、部分网站失败、协议探测失败、Portal 报 MAC 绑定错误 | 排障 |

## 硬性前提（必须先确认，否则做出来的东西用不了）

1. **单网口做不了 NAT 网关**。Windows 的 ICS（连接共享）强制要求两块网卡（WAN 侧 + LAN 侧）。只有一块物理网口时，唯一可行的是“带认证的代理 + 客户端主动配置”。要“插网线就上网、所有 App 天然走”，只有加 USB 网卡、或用路由器/随身 Wi‑Fi。
2. **客户端必须与服务端同网段**。校园网/宿舍网常见 AP 客户端隔离，同 SSID 也可能互访不通——先按“验证”段测端口连通，再谈认证。
3. 服务端必须**开机且已登录**。关机、注销、睡眠都会断，代理进程和 ICS 都不存在。
4. 上游若按账号/设备数计费，他人流量记在共享者账号上；校园网多设备共享可能违反使用协议，需提示用户自行权衡。

## 服务端：在提供网络的那台 Windows 上

运行 `scripts/setup-share-server.ps1`（需管理员）。它会一次性完成：下载 gost → 生成账号密码 → 写启动脚本 → 加防火墙规则（仅限本机所在网段）→ 注册登录自启计划任务 → 启动并自测。

```powershell
# 默认端口 18080(HTTP) / 18081(SOCKS5)，账号 shareuser，密码自动生成
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1

# 指定端口与账号
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1 -Port 18080 -SocksPort 18081 -User 自定义账号 -Password 自定义密码

# 改成开机就起（不等用户登录，SYSTEM 身份）
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1 -AtStartup

# 不注册开机自启
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1 -NoAutoStart
```

跑完会输出一张汇总：本机 IP、HTTP/SOCKS 端口、账号、密码、计划任务名、防火墙规则名、仅放行的网段。把这张表抄给客户端使用。

**安装位置**：程序目录默认在 **D 盘** `D:\Doubao\tools\gost`（机器没有 D 盘才回退 `%LOCALAPPDATA%\lan-share\gost`，并给出警告）。不要往 C 盘塞下载包和日志；换位置用 `-InstallDir 'D:\某目录\gost'`。

关键设计（不要擅自改动）：
- 监听 `0.0.0.0`，但**必须带认证**，否则同网段任何人都能借用出口。
- 防火墙规则把来源限制在服务端当前网段（如 `192.168.1.0/24`），跨网段直接连不上，比加认证更可靠。
- 自启走计划任务 + 启动脚本从 `pass.txt` 读密码，避免密码出现在命令行和任务参数里。三种模式：默认 `AtLogOn`（登录后起）；`-AtStartup`（开机就起，SYSTEM 身份，不用登录）；`-NoAutoStart`（不注册，手动跑 `run-proxy.cmd`）。
- 启动入口用 **cmd（`run-proxy.cmd`）**，不要用 powershell 包一层：部分机器上以 SYSTEM 身份运行时 powershell 写 D 盘日志会被系统拒绝，日志里只剩“拒绝访问”，任务结果 `0xFFFFFFFF`，表现为“任务在跑但 gost 没起”。cmd + `start /b` 没这个问题。
- 程序、日志、密码文件全部留在 D 盘目录里，卸载时删一个目录就干净了。

## 还原型机器（C 盘每次开机恢复原样）

机房、云桌面、考试机常带 C 盘还原策略，于是**计划任务、防火墙规则、Run 注册项全都会跟着 C 盘一起被抹掉**：表现为“重启后手机连不上、gost 没起”，但 D 盘里的程序和密码都还在。这种情况下不存在真正意义上的“开机自动启动”，只能把重建动作做成一次双击：

1. 首次部署照旧（程序、`pass.txt`、日志全在 D 盘）。
2. 在 D 盘目录放 `启动共享代理.cmd`，内容就是 `powershell -ExecutionPolicy Bypass -File 恢复共享代理.ps1`；再用 `scripts/recovery-start.ps1` 生成它：检测防火墙规则与计划任务 → 缺失则按 `cmd.exe /c run-proxy.cmd`（`AtStartup` / SYSTEM）重建 → 拉起 gost → 自检 407/200 → 弹窗显示当前 IP 与账号密码。
3. 还原到底在什么时机触发要实测，别凭猜：在 C 盘几个典型位置（`C:\` 根、`C:\Windows`、`C:\Windows\System32\Tasks`、用户目录、`C:\ProgramData`、`C:\Program Files` 某软件目录）各放一个带时间戳的标记文件，再挂 4 种自启（计划任务 / HKLM Run / HKCU Run / 启动文件夹），重启或关机再开机后看哪些还在、哪些命中文件被写出来。常见结论是“普通重启不还原、关机再开机才还原”，此时只要不真正关机就一直有效。
4. 还原生效后第一次开机必然要双击一次，弹窗里的 IP 才是准的（DHCP 可能换地址），手机端按新 IP 改。

## 客户端：让浏览器和 App 都走代理

先选一个客户端，**同一时间只能开一个 TUN**，否则互相抢路由，表现为“能连上但打不开网页”。

| 客户端 | 适用场景 | 代价 |
|---|---|---|
| **toci（campus-sni-proxy 3.x）** | 机器上已经有这个校园网工具，想复用它内置的 Mihomo TUN | 需在 GUI 里点一次“保存配置并应用” |
| Clash Verge Rev | 没装 toci，临时接管全局 | 必须装服务模式才能开 TUN |
| Proxifier | 只让某几个 exe 走代理 | 收费，仅 TCP |
| 手机 | iOS 原生可填认证；安卓需 v2rayNG / Clash Meta | 安卓 Wi‑Fi 代理不支持认证 |

### 1. 浏览器/系统级（只覆盖读系统代理的程序）
填服务器与端口后，首次访问会弹“代理服务器需要身份验证”，输账号密码并勾选记住。Windows 设置页没有密码字段，不要在那里找。

### 2. toci（推荐：已装就用它）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-client-toci.ps1 -Server 192.168.1.10 -Password 密码
```

脚本会自动定位 toci 目录（参数 `-TociDir` → 桌面快捷方式 `toci.lnk` → 默认路径），备份 `tun_config.json`，把 `id=default` 的线路改成 `socks5 + 18081 + 账号密码`，补齐 `edu.cn / local / gost.exe` 三条 DIRECT 规则，写回后自检端口连通，并打印 GUI 里还要点哪两步。

字段对应（手工在 GUI 填时照这个来）：

| GUI 字段 | 值 |
|---|---|
| 代理协议 | **SOCKS5（支持 UDP）**，不要选 HTTP |
| 服务器 IP / 端口 | 服务端 IP / **18081** |
| 用户名 / 密码 | 服务端账号 / 密码 |
| TUN 栈 | gVisor |
| 绕过局域网与私有网段 | 勾 |
| 启用 Fake-IP DNS 劫持 | 勾 |
| 开启 UDP 转发 | 勾 |

**最常见的坑**：协议选 SOCKS5 却把端口填成 18080（HTTP 端口不做 SOCKS 握手），会直接报 `协议探测失败: timed out`；反过来协议选 HTTP 配 18081 同理。端口和协议必须成对。

脚本改完文件后，GUI 不会自动读到，**必须在「代理配置」页点“测试连通性与认证”（显示延迟即通）→ 点“保存配置并应用”**，虚拟网卡 `SNI-Proxy-TUN` 才会出现。

toci 的 TUN 用细分路由（`0.0.0.0/5`、`128.0.0.0/1` 等）接管公网，顶层 `0.0.0.0/0` 仍留在物理网卡属正常，别据此判断“没生效”。

### 3. Clash Verge Rev（备选）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-client-clash.ps1 -Server 192.168.1.10 -Port 18080 -SocksPort 18081 -User shareuser -Password 密码
```

会自动生成一份“共享代理”配置（SOCKS5 优先、带 UDP）、切为当前配置、打开 TUN，并备份原配置。

注意：脚本最后启动 Clash Verge 这一步**必须在正常用户环境执行**，受限环境里它会因为写不了单实例文件的安全描述符而报 `DACL is not protected`。若遇到该报错，关掉客户端、删掉配置目录下的 `singleton-instance*` 文件，再让用户从开始菜单手动启动一次即可。

### 4. 手机
- iPhone/iPad 原生支持：Wi‑Fi → 配置代理 → 手动 → 填服务器/端口 → 打开“认证”填账号密码。
- 安卓原生 Wi‑Fi 代理**没有认证字段**，带认证的代理填了也只会 407。必须装 v2rayNG / Clash Meta for Android，把服务端当作 `HTTP` 或 `SOCKS5` 节点（填账号密码），开 VPN/全局模式。

平台细节、Proxifier 与客户端节点的完整字段见 `references/client-setup.md`。

## 验证（两端各测一次，别靠“感觉能上网”）

```powershell
# 只测链路与认证
powershell -ExecutionPolicy Bypass -File scripts\verify-share.ps1 -Server 192.168.1.10 -Port 18080 -User shareuser -Password 密码

# 连 TUN 接管一起测（toci 用 SNI-Proxy-TUN，Clash 用 Meta）
powershell -ExecutionPolicy Bypass -File scripts\verify-share.ps1 -Server 192.168.1.10 -User shareuser -Password 密码 -CheckTun -TunName SNI-Proxy-TUN
```

判定标准（脚本 8 项应全 PASS、退出码 0）：
- 端口探测通 → 网络层可达（不通就是跨网段/AP 隔离/服务端没开）。
- 无凭据应返回 407、带凭据应 200 → 认证生效。
- `-CheckTun`：客户端 TUN 网卡 Up、**该网卡上存在公网路由**（`0.0.0.0/5`、`128.0.0.0/1` 这类细分段也算）、DNS 返回 `198.18.x`、绕过系统代理仍能取到 200 → App 流量确实被接管。
- 只看顶层 `0.0.0.0/0` 会误判：toci 不改默认路由，靠细分路由覆盖公网。

## 排障

按报错对号入座，见 `references/troubleshooting.md`（407 / ERR_PROXY_CONNECTION_FAILED / ERR_TUNNEL_CONNECTION_FAILED / 部分网站失败 / App 不走代理 / 安卓无法认证 / Portal MAC 绑定错误 / 重启后没网）。

## 清理与回滚

```powershell
# 服务端
Stop-ScheduledTask -TaskName 'LAN Proxy (gost)'
Unregister-ScheduledTask -TaskName 'LAN Proxy (gost)' -Confirm:$false
Remove-NetFirewallRule -DisplayName 'LAN Proxy (gost)'
Remove-Item 'D:\Doubao\tools\gost' -Recurse -Force   # 自定义过 -InstallDir 就换成实际目录
```

客户端（Clash Verge）：恢复配置目录下 `.bak_*` 备份里的 `profiles.yaml` / `verge.yaml`，删除 `profiles\pclan.yaml`，并把 `profiles.yaml` 里的 `current` 改回原订阅。

客户端（toci）：把脚本生成的 `tun_config.bak_*.json` 覆盖回 `tun_config.json`，再在 GUI 里重新“保存配置并应用”；或在「TUN / VPN」页关掉 TUN 开关，虚拟网卡 `SNI-Proxy-TUN` 随即消失。

## 安全与合规红线

- 代理必须带认证，且只对同网段放行；不要把账号密码发到群里或截图传播。
- 不要用改 MAC、模拟认证客户端等方式绕过校园网计费或设备限制——这类做法不予提供。
- 共享结束后提醒用户关闭计划任务，避免长期被他人借用出口。

## 环境差异备忘

- 脚本是 PowerShell 7 写法，在 Windows 客户端上运行；云主机（Linux）环境只能改文档、不能执行。
- 目标机器若没有无线网卡，`移动热点` 一律不可用，不要建议“开热点”。
- Clash Verge 配置目录固定为 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev`，安装目录需从注册表 `Uninstall` 项读取，不要写死 `C:\Program Files`。
- toci 目录不要写死路径：先从桌面 `toci.lnk` 解析（`(New-Object -ComObject WScript.Shell).CreateShortcut(...).TargetPath`），再退回常见位置；它的数据布局是 `tun_config.json` + `rules.json` + `state\{tun_mihomo.yaml,tun.pid}`，改完配置只改 JSON 不够，GUI 需重新应用一次才会重建 `state\tun_mihomo.yaml`。
- 所有 `.ps1` 必须存成 **UTF-8 BOM**，否则 Windows PowerShell 5.1 读中文会当语法错误。
