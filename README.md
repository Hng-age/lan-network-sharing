# lan-network-sharing

一个给 AI Agent 用的 Skill：在 Windows 上把本机网络**共享给同一局域网的其他设备**，并让对方的 App（不只是浏览器）也走这条链路。

内核是一套「gost 带认证 HTTP/SOCKS5 代理 + 防火墙限网段 + 登录自启计划任务」，配套客户端接入与双向验证脚本、排障手册。

## 适用场景

- 把自己的网络共享给室友 / 另一台电脑 / 手机
- 用这台电脑当代理，让浏览器和 App 都走
- 排查共享后的 407、`ERR_PROXY_CONNECTION_FAILED`、安卓填不了代理密码、Portal MAC 绑定错误等问题

## 目录结构

```
SKILL.md                          # Skill 主入口：场景判定、硬性前提、三段流程
references/
  client-setup.md                 # Windows / iPhone / Android 各平台接入细节
  troubleshooting.md              # 按报错、按场景的排障速查
scripts/
  setup-share-server.ps1          # 服务端一键搭建（gost + 防火墙 + 计划任务 + 自测）
  setup-client-clash.ps1          # Windows 客户端：生成 Clash Verge 配置并开 TUN/系统代理
  verify-share.ps1                # 两端验证：端口、407/200 认证、TUN 接管
```

## 快速开始

> 需要 Windows 服务端 + 管理员权限；客户端必须与服务端同网段。

### 1. 服务端（提供网络的那台机器）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1

# 自定义端口与账号
powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1 -Port 18080 -SocksPort 18081 -User b404 -Password 自定义密码
```

脚本会下载 gost、生成账号密码、写启动脚本、添加仅限本网段的防火墙规则、注册登录自启计划任务，并自测一次。跑完输出的汇总表（IP / 端口 / 账号 / 密码 / 放行网段）拿给客户端用。

- 默认端口：`18080`（HTTP）、`18081`（SOCKS5）；默认账号 `b404`，密码自动生成。
- 代理监听 `0.0.0.0` 且**强制认证**，防火墙再把来源限制在服务端当前网段。

### 2. 客户端

| 形态 | 做法 |
|---|---|
| 浏览器 / 系统代理 | 填 IP + 18080，首次访问弹认证框输账号密码并记住 |
| Windows 让 App 也走 | `scripts\setup-client-clash.ps1`（Clash Verge + TUN），或 Proxifier |
| iPhone / iPad | Wi‑Fi → 配置代理 → 手动 → 填地址端口 + 打开「认证」 |
| Android | 原生代理无认证字段，需用 v2rayNG / Clash Meta for Android 作为节点并开 VPN |

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-client-clash.ps1 -Server 192.168.112.32 -Port 18080 -SocksPort 18081 -User b404 -Password 密码
```

### 3. 验证

```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify-share.ps1 -Server 192.168.112.32 -Port 18080 -User b404 -Password 密码

# 额外校验 TUN 是否真的接管了 App 流量
powershell -ExecutionPolicy Bypass -File scripts\verify-share.ps1 -Server 192.168.112.32 -Port 18080 -User b404 -Password 密码 -CheckTun
```

判定标准：端口通 → 无凭据返回 407、带凭据返回 200 → `-CheckTun` 检查 `Meta` 网卡、默认路由、DNS fake-ip。

## 硬性前提

1. **单网口做不了 NAT 网关**。Windows ICS 需要两块网卡；只有一块物理网口时，唯一可行路径是「带认证的代理 + 客户端主动配置」。
2. **客户端必须与服务端同网段**。校园网/宿舍网的 AP 客户端隔离会让同 SSID 设备也互访不通。
3. **服务端必须开机且已登录**，关机、注销、睡眠都会断。
4. 上游按账号/设备数计费时，他人流量记在共享者账号上；校园网多设备共享可能违反使用协议，请自行权衡。

## 清理与回滚

```powershell
# 服务端
Stop-ScheduledTask -TaskName 'LAN Proxy (gost)'
Unregister-ScheduledTask -TaskName 'LAN Proxy (gost)' -Confirm:$false
Remove-NetFirewallRule -DisplayName 'LAN Proxy (gost)'
Remove-Item "$env:LOCALAPPDATA\lan-share" -Recurse -Force
```

客户端（Clash Verge）：恢复配置目录下的 `.bak_*` 备份，删除 `profiles\pclan.yaml`，并把 `profiles.yaml` 的 `current` 改回原订阅。

## 安全与合规

- 代理必须带认证，且只对同网段放行；不要把账号密码发到群里或截图传播。
- 不支持、也不提供改 MAC、模拟认证客户端等绕过校园网计费或设备限制的做法。
- 共享结束后及时关闭计划任务，避免出口被长期借用。

## License

[MIT](LICENSE)
