# lan-network-sharing

一个给 AI Agent 用的 Skill：在 Windows 上把本机网络**共享给同一局域网的其他设备**，并让对方的 App（不只是浏览器）也走这条链路。

内核是「gost 带认证 HTTP/SOCKS5 代理 + 防火墙限网段 + 计划任务自启」，配套客户端接入（toci / Clash Verge / Proxifier / 手机）、双向验证脚本与排障手册。

## 适用场景

- 把自己的网络共享给室友 / 另一台电脑 / 手机
- 用这台电脑当代理，让浏览器和 App 都走
- 已装 toci（campus-sni-proxy）想复用它内置的 Mihomo TUN
- 排查共享后的 407、`ERR_PROXY_CONNECTION_FAILED`、`协议探测失败: timed out`、安卓填不了代理密码、Portal MAC 绑定错误等问题

## 目录结构

```
SKILL.md                          # Skill 主入口：场景判定、硬性前提、三段流程
references/
  client-setup.md                 # Windows / iPhone / Android 各平台接入细节
  troubleshooting.md              # 按报错、按场景的排障速查
scripts/
  setup-share-server.ps1          # 服务端一键搭建（gost + 防火墙 + 计划任务 + 自测）
  setup-client-toci.ps1           # 客户端：改 toci 的 tun_config.json（SOCKS5 + DIRECT 规则）
  setup-client-clash.ps1          # 客户端：生成 Clash Verge 配置并开 TUN/系统代理
  verify-share.ps1                # 两端验证：端口、407/200 认证、TUN 接管（8 项）
```

## 快速开始

> 需要 Windows 服务端 + 管理员权限；客户端必须与服务端同网段。

### 1. 服务端（提供网络的那台机器）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1

# 自定义端口与账号
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1 -Port 18080 -SocksPort 18081 -User 自定义账号 -Password 自定义密码

# 开机就起（SYSTEM 身份，不等登录）/ 不注册自启
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1 -AtStartup
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1 -NoAutoStart
```

默认端口 `18080`（HTTP）/ `18081`（SOCKS5），默认账号 `shareuser`，密码自动生成；程序与日志默认放在 `D:\Doubao\tools\gost`（无 D 盘才回退 `%LOCALAPPDATA%\lan-share\gost`），可用 `-InstallDir` 指定。

脚本会下载 gost、生成账号密码、写启动脚本、添加仅限本网段的防火墙规则、注册自启计划任务，并自测一次。跑完输出的汇总表（IP / 端口 / 账号 / 密码 / 放行网段）拿给客户端用。

### 2. 客户端（同一时间只开一个 TUN）

| 客户端 | 适用场景 | 命令 |
|---|---|---|
| **toci（campus-sni-proxy）** | 机器上已有该校园网工具，复用其 Mihomo TUN | `scripts\setup-client-toci.ps1 -Server <IP> -Password <密码>` |
| Clash Verge Rev | 没装 toci，临时接管全局 | `scripts\setup-client-clash.ps1 -Server <IP> -Password <密码>` |
| 系统代理 | 只要浏览器能用 | 填 IP + 18080，首次访问输账号密码 |
| 手机 | iOS 原生可填认证；安卓需 v2rayNG / Clash Meta | 见 `references/client-setup.md` |

toci 关键点：协议选 **SOCKS5** 就配 **18081**，选 HTTP 才配 18080，端口与协议必须成对，否则报 `协议探测失败: timed out`。脚本改完 `tun_config.json` 后，仍需在 GUI 点「测试连通性与认证」→「保存配置并应用」，虚拟网卡 `SNI-Proxy-TUN` 才会出现。

### 3. 验证

```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify-share.ps1 -Server <IP> -Port 18080 -User <账号> -Password <密码>

# 连 TUN 接管一起测（toci 用 SNI-Proxy-TUN，Clash 用 Meta）
powershell -ExecutionPolicy Bypass -File scripts\verify-share.ps1 -Server <IP> -User <账号> -Password <密码> -CheckTun -TunName SNI-Proxy-TUN
```

判定标准（8 项全 PASS、退出码 0）：端口通 → 无凭据 407、带凭据 200 → TUN 网卡 Up 且存在公网路由（`0.0.0.0/5`、`128.0.0.0/1` 这类细分段也算）→ DNS 返回 `198.18.x` → 绕过系统代理仍能取到 200。

## 硬性前提

1. **单网口做不了 NAT 网关**。Windows ICS 需要两块网卡；只有一块物理网口时，唯一可行路径是「带认证的代理 + 客户端主动配置」。
2. **客户端必须与服务端同网段**。校园网/宿舍网的 AP 客户端隔离会让同 SSID 设备也互访不通。
3. **服务端必须开机**；默认 `AtLogOn` 模式还要求已登录（用 `-AtStartup` 可免登录）。
4. 上游按账号/设备数计费时，他人流量记在共享者账号上；校园网多设备共享可能违反使用协议，请自行权衡。

## 清理与回滚

```powershell
# 服务端
Stop-ScheduledTask -TaskName 'LAN Proxy (gost)'
Unregister-ScheduledTask -TaskName 'LAN Proxy (gost)' -Confirm:$false
Remove-NetFirewallRule -DisplayName 'LAN Proxy (gost)'
Remove-Item 'D:\Doubao\tools\gost' -Recurse -Force   # 自定义过 -InstallDir 就换成实际目录
```

- Clash Verge：恢复配置目录下 `.bak_*` 备份，删除 `profiles\pclan.yaml`，把 `profiles.yaml` 的 `current` 改回原订阅。
- toci：把 `tun_config.bak_*.json` 覆盖回 `tun_config.json` 再在 GUI 重新应用；或直接在「TUN / VPN」页关掉 TUN 开关。

## 安全与合规

- 代理必须带认证，且只对同网段放行；不要把账号密码发到群里或截图传播。
- 不支持、也不提供改 MAC、模拟认证客户端等绕过校园网计费或设备限制的做法。
- 共享结束后及时关闭计划任务，避免出口被长期借用。

## License

[MIT](LICENSE)
