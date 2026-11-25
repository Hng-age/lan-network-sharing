# 排障速查

先跑 `scripts/verify-share.ps1`，按失败项对号入座。

## 按报错

| 现象 / 报错 | 原因 | 处理 |
|---|---|---|
| `407 Proxy Authentication Required` 反复弹 | 认证没过：密码错、没填、或安卓原生代理不支持认证 | Windows 重填并勾记住凭据；安卓改用 v2rayNG / Clash Meta |
| `ERR_PROXY_CONNECTION_FAILED` | 连不上代理端口：服务端关机/注销、gost 进程没起、防火墙挡 | 服务端跑 `Get-Process gost`、`Get-NetTCPConnection -LocalPort 18080`；查计划任务状态 |
| `ERR_TUNNEL_CONNECTION_FAILED` | 代理连上了但目标站点连不通 | 关代理在服务端直接访问该网址；也不通就是线路/封锁问题，代理救不了 |
| 页面转圈 / `ERR_CONNECTION_TIMED_OUT` | 目标走 UDP/QUIC 或非 80/443 端口，HTTP 代理不支持 | 关浏览器 QUIC/HTTP3；改用 SOCKS5 + TUN |
| 浏览器正常、App 用不了 | App 不读系统代理 | Windows 开 Clash TUN 或 Proxifier；手机用 VPN 模式客户端 |
| 安卓填了代理却一直 407 | 安卓 Wi‑Fi 代理无认证字段 | 必须用 v2rayNG / Clash Meta 作为节点，不支持“裸填端口” |
| `failed to persist singleton instance record: current-user file DACL is not protected` | Clash Verge 单实例文件的安全描述符写不进去（受限环境、权限异常、强杀残留） | 关闭客户端 → 删配置目录 `singleton-instance*` → 从开始菜单手动启动；或换正常用户会话执行 |
| Clash 启动了但没 `Meta` 网卡 | TUN 开关没开、服务模式未安装、没管理员权限 | 设置里“服务模式”安装后开 TUN；确认 `enable_tun_mode: true` |
| 开启后上网正常但所有流量只走一个节点，服务端一关全断 | 单节点配置无兜底 | 进 Clash 切回原订阅，或把规则组改成 fallback（含 DIRECT） |
| 重启后“有网卡但打不开网页” | 系统代理残留 `127.0.0.1:7897` 而客户端没启动 | 开客户端自启；或 `ProxyEnable=0` 关闭系统代理 |
| 内网站点/教务系统打不开 | 被强行塞进代理 | 代理绕过列表加 `192.168.*,10.*,127.0.0.1,*.edu.cn` |
| `协议探测失败: timed out`（toci 界面上） | 协议与端口错配：SOCKS5 填了 HTTP 端口，或 HTTP 填了 SOCKS5 端口；也可能服务端没开/跨网段 | SOCKS5 配 18081、HTTP 配 18080；先 `Test-NetConnection IP -Port 18081` 确认端口通 |
| toci 点了“保存配置并应用”但没 `SNI-Proxy-TUN` 网卡 | 线路没选中、延迟测试没过、或需要管理员权限建虚拟网卡 | 先“测试连通性与认证”看到 ms 延迟再应用；用管理员身份启动 toci |
| toci 应用后网页全挂 | 与 Clash 的 `Meta` TUN 同时存在，抢路由/系统代理 | 只留一个 TUN：关掉 Clash Verge 的 TUN（或退出 Verge 并停 `clash_verge_service`） |

## 按场景

### 端口连不上（verify 第一项就 FAIL）
1. 两端是否同一网段：服务端 `Get-NetIPAddress`，客户端同样看。
2. 校园网/宿舍网 AP 隔离：同 SSID 下设备也可能互访不通，换有线或让服务端连同一 AP。
3. 服务端防火墙规则是否只放行了别的网段：`Get-NetFirewallRule -DisplayName 'LAN Proxy (gost)'`。
4. 服务端是否真的在跑：`Get-Process gost`、`Get-Content ...\proxy.log -Tail 20`。

### Portal 认证报“用户MAC地址绑定错误”
与本 Skill 无关，是校园网按终端 MAC 绑定账号：
1. 关掉设备“随机硬件地址 / 私有 Wi‑Fi 地址 / 随机 MAC”。
2. 仍报错说明后台绑的是另一块网卡或另一台设备，去 Portal“终端信息”或学校自助服务解绑重绑。
3. 不要用改 MAC 工具硬凑，容易被判违规。

### 认证成功但网页慢/部分失败
- HTTP 代理只承载 TCP；语音、游戏、部分直播走 UDP，必然失败或直连。
- 大量并发下载会把共享者账号的带宽吃满，也会触发校园网多设备检测。

## 安全回滚

- 服务端：停用并删除计划任务、防火墙规则，删程序目录（默认 `D:\Doubao\tools\gost`）。
- 客户端（Clash）：用脚本生成的 `.bak_时间戳` 目录覆盖回 `profiles.yaml` / `verge.yaml` / `config.yaml`，删除 `profiles\pclan.yaml`。
- 客户端（toci）：`tun_config.bak_时间戳.json` 覆盖回 `tun_config.json` 并在 GUI 重新应用；或直接关掉 TUN 开关，`SNI-Proxy-TUN` 网卡随之消失。
