lan-network-sharing 技能包
==========================

把一台 Windows 机器的网络出口借给同一网段的其它设备（手机、另一台电脑），
用带认证的 HTTP + SOCKS5 代理实现，不需要两块网卡、不做 NAT 网关。

【包内容】
  SKILL.md                       技能主文档（场景判定、服务端/客户端流程、验证标准、红线）
  references/client-setup.md     客户端细节：Windows 系统代理、toci、Clash Verge、Proxifier、iOS/Android 节点字段
  references/troubleshooting.md  报错与场景排障速查表
  scripts/setup-share-server.ps1 服务端一键部署：下载 gost → 生成密码 → 写启动脚本 → 建防火墙规则 → 注册开机任务 → 启动自检
  scripts/verify-share.ps1       两端校验：端口 / 407 / 带认证出网 / 可选 TUN 接管
  scripts/setup-client-clash.ps1 客户端 Clash Verge Rev 一键配置（生成共享节点、开 TUN）
  scripts/setup-client-toci.ps1  客户端 toci（campus-sni-proxy）配置写入 + 自检
  scripts/recovery-start.ps1     还原型机器用的一键恢复脚本（重建防火墙与任务、拉起 gost、自检弹窗）

【服务端用法】
  powershell -ExecutionPolicy Bypass -File scripts\setup-share-server.ps1
  常用参数：-Port 18080 -SocksPort 18081 -User shareuser -Password 自定义
           -AtStartup（开机即起，SYSTEM 身份，不用登录）  -NoAutoStart（不注册自启）
           -InstallDir 'D:\某目录\gost'   -AllowCidr '192.168.1.0/24'
  跑完会打印本机 IP、双端口、账号密码、放行网段，直接交给客户端。

【本次修订点（相对原版）】
  1. 启动入口从 powershell 包一层改为 cmd：run-proxy.cmd 从 pass.txt 读密码后 start /b 启动 gost。
     原因：部分机器以 SYSTEM 身份运行时，powershell 写服务端磁盘日志会被系统拒绝，
     日志里只剩“拒绝访问”，任务结果 0xFFFFFFFF，看着“任务在跑”但 gost 根本没起。
  2. 计划任务动作相应改为 cmd.exe /c run-proxy.cmd；若任务没能拉起，脚本会自动回退直接启动。
  3. SKILL.md 增加“还原型机器（C 盘每次开机恢复原样）”一节：这类机器没有真正的开机自启，
     只能把重建做成一次双击，并给出用标记文件 + 4 种自启机制实测还原时机的办法。
  4. troubleshooting.md 增加对应条目，便于按“任务在跑但没进程 / 日志只有拒绝访问”快速定因。

【安全提示】
  - 代理必须带认证，防火墙只放行本机所在网段，别把账号密码发到群里或截图传播。
  - 共享期间，他人的流量记在共享者的账号上；校园网多设备共享可能违反使用协议，需自行权衡。
  - 共享结束后停掉计划任务与防火墙规则，避免被长期借用出口。

【隐私说明】
  本包内不含任何真实主机的 IP、机器名、账号密码、日志或个人路径；
  文中的 192.168.1.10 / 192.168.1.0/24 / shareuser 均为示例值。
