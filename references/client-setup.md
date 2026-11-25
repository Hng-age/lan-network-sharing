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
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -Value '192.168.112.32:18080'
# 关闭系统代理
# Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0
```

## 二、Windows：让 App 也走（TUN / 按进程）

### 方案 A：Clash Verge + TUN（推荐，脚本已自动化）
运行 `scripts/setup-client-clash.ps1`。它做的事等价于：

1. 在 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles\` 写 `pclan.yaml`（SOCKS5/HTTP 两个节点，`MATCH,PROXY` 全量转发，DNS 用 fake-ip）。
2. 在 `profiles.yaml` 里注册该配置并设为 `current`。
3. `verge.yaml` 打开 `enable_tun_mode` 与 `enable_system_proxy`。
4. 重启客户端，TUN 网卡 `Meta` 出现，系统代理变 `127.0.0.1:7897`。

验证：`verify-share.ps1 -CheckTun` 四项全 PASS。

注意：启动客户端必须在正常用户环境；受限环境下会报 `failed to persist singleton instance record: current-user file DACL is not protected`，删掉配置目录的 `singleton-instance*` 再从开始菜单启动即可。

### 方案 B：Proxifier（只接管 TCP，按进程控制）
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
    server: 192.168.112.32
    port: 18081
    username: b404
    password: 密码
    udp: true
mode: global
```
导入配置后开启“VPN/TUN”，即可让所有 App 走。

## 五、验证与常见坑

- 先用浏览器访问 `http://IP:18080`：看到 `407 Proxy Authentication Required` 说明网络层通了，剩下只是认证。
- 打不开、超时：不在同网段，或校园网/宿舍网开了 AP 客户端隔离。
- 只有浏览器通、App 不通：没开 TUN，或 App 用自有协议（微信/QQ/游戏）。
- 浏览器开了 QUIC/HTTP3：部分站点会绕开代理直连 UDP，关闭 QUIC 或换 TUN。
- 校园内网站（教务处、内网 IP、`*.edu.cn`）应先加入“不使用代理/绕过列表”，否则会被强行代理导致打不开。
