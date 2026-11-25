# 客户端接入手册

服务端跑完 `setup-share-server.ps1` 后拿到四个值：`IP`、`HTTP端口(默认18080)`、`SOCKS5端口(默认18081)`、`账号/密码`。下面是各平台怎么填。

## 一、Windows：系统代理（只覆盖浏览器和少数程序）

1. 设置 → 网络和 Internet → 代理 → 手动设置代理 → 打开“使用代理服务器”。
2. 地址填 IP，端口填 18080，保存。
3. 打开浏览器访问任意网页，会弹“代理服务器需要身份验证”：填账号密码，勾选记住凭据。
4. 灰色地带：Windows 设置页**没有**用户名/密码输入框，不要在那里找。

一次性写入（可复制到 PowerShell）：

```powershell
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 1
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -Value '192.168.1.10:18080'
# 关闭系统代理
# Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0
```

## 二、Windows：让 App 也走（TUN / 按进程）

### 方案 A：toci（campus-sni-proxy 3.x）——机器上已有就直接复用

toci 自带 Mihomo，能把任意 SOCKS5 上游包装成 TUN，所以不必再装 Clash。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-client-toci.ps1 -Server 192.168.1.10 -Password 密码
# 目录识别不了时显式指定
# -TociDir 'D:\Tools\toci'
```

等价的手工操作（GUI「代理配置」页）：

1. 线路：代理协议 **SOCKS5（支持 UDP）**、服务器 IP、端口 **18081**、用户名/密码，勾“开启 UDP 转发”。
2. TUN 栈 **gVisor**，勾“绕过局域网与私有网段”“启用 Fake-IP DNS 劫持”。
3. 点“测试连通性与认证”，显示延迟（如 `3.1 ms`）说明上游可用；再点“保存配置并应用”。
4. 应用后 `state\tun_mihomo.yaml` 会被重建：`proxies` 里出现指向 `socks5://账号:密码@IP:18081` 的 `LAN-PROXY`，`rules` 末尾 `MATCH,PROXY`，`route-exclude` 排除私网段与服务端 IP。

判定接管成功：网卡 `SNI-Proxy-TUN` 为 Up；`Resolve-DnsName www.baidu.com` 返回 `198.18.x`；该网卡上出现 `0.0.0.0/5`、`128.0.0.0/1` 这类细分公网路由。**顶层 `0.0.0.0/0` 仍在物理网卡属正常**，toci 不改默认路由。

协议与端口必须成对：18080 只认 HTTP（不留 SOCKS 握手），18081 只认 SOCKS5。错配就是 `协议探测失败: timed out`。

`also_set_sys_proxy` 保持原值即可；若同时开了系统代理和 TUN，个别程序会双重接管，出怪问题时把它关掉只留 TUN。

### 方案 B：Clash Verge + TUN
运行 `scripts/setup-client-clash.ps1`。它做的事等价于：

1. 在 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles\` 写 `pclan.yaml`（SOCKS5/HTTP 两个节点，`MATCH,PROXY` 全量转发，DNS 用 fake-ip）。
2. 在 `profiles.yaml` 里注册该配置并设为 `current`。
3. `verge.yaml` 打开 `enable_tun_mode` 与 `enable_system_proxy`。
4. 重启客户端，TUN 网卡 `Meta` 出现，系统代理变 `127.0.0.1:7897`。

验证：`verify-share.ps1 -CheckTun -TunName Meta` 全 PASS。

注意：启动客户端必须在正常用户环境；受限环境下会报 `failed to persist singleton instance record: current-user file DACL is not protected`，删掉配置目录的 `singleton-instance*` 再从开始菜单启动即可。

### 方案 C：Proxifier（只接管 TCP，按进程控制）
1. `Profile → Proxy Servers → Add`：Address=IP，Port=18080，Type=HTTP，Authentication 填账号密码。
2. 设为默认代理。
3. `Profile → Proxification Rules`：默认规则指向该代理，或按 exe 精确指定。
4. 主界面日志会逐条显示 `进程 → 域名 → 代理`，有记录即生效。

两套方案不要同时开。

## 三、iPhone / iPad（原生支持认证）

设置 → 无线局域网 → 点当前网络右侧 `i` → 配置代理 → 手动 → 服务器 IP、端口 18080 → 打开“认证” → 用户名/密码 → 存储。

## 四、Android（原生系统代理填不了密码）

安卓 Wi‑Fi 代理设置只有主机名+端口，没有认证字段，直连只会 407。两条可行路径：

### v2rayNG
1. 添加手动节点：类型选 `HTTP`（或 SOCKS），地址 IP，端口 18080（SOCKS 用 18081），填用户名/密码。
2. 设为活动节点，开启 VPN 开关，路由模式选“全局”。

### Clash Meta for Android
```yaml
proxies:
  - name: PC-LAN
    type: socks5
    server: 192.168.1.10
    port: 18081
    username: shareuser
    password: 密码
    udp: true
mode: global
```
导入配置后开启“VPN/TUN”，即可让所有 App 走。

## 五、验证与常见坑

- 先用浏览器访问 `http://IP:18080`：看到 `407 Proxy Authentication Required` 说明网络层通了，剩下只是认证。
- 打不开、超时：不在同网段，或校园网/宿舍网开了 AP 客户端隔离。
- 只有浏览器通、App 不通：没开 TUN，或 App 用自有协议（微信/QQ/游戏）。
- `协议探测失败: timed out`（toci）：协议与端口错配（SOCKS5 配 18080 / HTTP 配 18081），或服务端没开、跨网段。
- 开了 TUN 反而更慢或部分站点超时：两个 TUN 同时存在（toci 的 `SNI-Proxy-TUN` + Clash 的 `Meta`），关掉一个。
- 浏览器开了 QUIC/HTTP3：部分站点会绕开代理直连 UDP，关闭 QUIC 或换 TUN。
- 校园内网站（教务处、内网 IP、`*.edu.cn`）应先加入“不使用代理/绕过列表”，否则会被强行代理导致打不开。
