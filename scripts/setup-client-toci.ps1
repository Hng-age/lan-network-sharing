# setup-client-toci.ps1
# 把共享代理写进 SNI-Proxy-Desktop (toci) 的 TUN 配置，让全机 App 走代理。
# 用法: powershell -ExecutionPolicy Bypass -File setup-client-toci.ps1 -Server 192.168.1.10 -Password 密码

param(
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$SocksPort = 18081,
    [int]$HttpPort = 18080,
    [ValidateSet('socks5', 'http')][string]$Protocol = 'socks5',
    [string]$User = 'shareuser',
    [Parameter(Mandatory = $true)][string]$Password,
    [ValidateSet('global', 'rule')][string]$Mode = 'global',
    [string]$TociDir,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'

# ---- 1. 定位应用目录 ----
if (-not $TociDir) {
    $desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'toci.lnk'
    if (Test-Path $desktopLnk) {
        $sh = New-Object -ComObject WScript.Shell
        $target = $sh.CreateShortcut($desktopLnk).TargetPath
        if ($target) { $TociDir = Split-Path $target }
    }
}
if (-not $TociDir) {
    $candidates = @('D:\Tools\toci', 'D:\Apps\toci', 'D:\SNI-Proxy\toci', "$env:LOCALAPPDATA\Programs\toci")
    foreach ($p in $candidates) {
        if (Test-Path (Join-Path $p 'tun_config.json')) { $TociDir = $p; break }
    }
}
if (-not $TociDir -or -not (Test-Path (Join-Path $TociDir 'tun_config.json'))) {
    throw '找不到 tun_config.json，请用 -TociDir 指定 toci.exe 所在目录'
}

$cfgPath = Join-Path $TociDir 'tun_config.json'
$backup = Join-Path $TociDir ('tun_config.bak_' + (Get-Date -Format 'yyyyMMddHHmmss') + '.json')
Copy-Item $cfgPath $backup -Force
Write-Host "已备份原配置: $backup"

$cfg = Get-Content $cfgPath -Raw -Encoding utf8 | ConvertFrom-Json

# ---- 2. 组装参数 ----
$port = if ($Protocol -eq 'socks5') { $SocksPort } else { $HttpPort }
$udp = ($Protocol -eq 'socks5')

$profile = [ordered]@{
    id            = 'default'
    name          = "共享代理 ($Server)"
    protocol      = $Protocol
    server        = $Server
    port          = $port
    username      = $User
    password      = $Password
    udp           = $udp
    last_status   = '待测试'
    last_latency_ms = $null
}

# 保留其它线路，替换 id=default 的那条
$profiles = @()
if ($cfg.profiles) {
    foreach ($p in $cfg.profiles) { if ($p.id -ne 'default') { $profiles += $p } }
}
$profiles += $profile

# 规则：保留原有，确保三条兜底规则存在
$rules = @()
if ($cfg.rules) { foreach ($r in $cfg.rules) { $rules += $r } }
$need = @(
    @{ type = 'DOMAIN-SUFFIX'; value = 'edu.cn';  policy = 'DIRECT'; comment = '高校内网/教务系统直连' },
    @{ type = 'DOMAIN-SUFFIX'; value = 'local';   policy = 'DIRECT'; comment = '局域网本地域名直连' },
    @{ type = 'PROCESS-NAME';  value = 'gost.exe'; policy = 'DIRECT'; comment = '防止本地服务端代理回环' }
)
foreach ($n in $need) {
    if (-not ($rules | Where-Object { $_.type -eq $n.type -and $_.value -eq $n.value })) {
        $rules += [pscustomobject]@{ enabled = $true; type = $n.type; value = $n.value; policy = $n.policy; comment = $n.comment }
    }
}

# ---- 3. 写出（保留原有其它字段） ----
$out = [ordered]@{}
foreach ($prop in $cfg.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
$out['active_profile_id'] = 'default'
$out['profiles']          = @($profiles)
$out['server']            = $Server
$out['port']              = $port
$out['protocol']          = $Protocol
$out['username']          = $User
$out['password']          = $Password
$out['mode']              = $Mode
$out['udp']               = $udp
if (-not $out.Contains('stack'))      { $out['stack'] = 'gvisor' }
if (-not $out.Contains('fake_ip'))    { $out['fake_ip'] = $true }
if (-not $out.Contains('bypass_lan')) { $out['bypass_lan'] = $true }
if (-not $out.Contains('also_set_sys_proxy')) { $out['also_set_sys_proxy'] = $false }
if (-not $out.Contains('mixed_port')) { $out['mixed_port'] = 17897 }
if (-not $out.Contains('api_port'))   { $out['api_port'] = 19090 }
if (-not $out.Contains('device_name')) { $out['device_name'] = 'SNI-Proxy-TUN' }
if (-not $out.Contains('final_policy')) { $out['final_policy'] = 'PROXY' }
$out['rules'] = @($rules)

$json = $out | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $cfgPath -Value $json -Encoding utf8
Write-Host "已写入: $cfgPath"

# ---- 4. 自检 ----
$check = Get-Content $cfgPath -Raw -Encoding utf8 | ConvertFrom-Json
if ($check.profiles.Count -lt 1 -or $check.port -ne $port) { throw '写入校验失败，请检查 JSON 结构' }

$tc = New-Object System.Net.Sockets.TcpClient
$ok = $false
try { $ok = ($tc.ConnectAsync($Server, $port).Wait(3000) -and $tc.Connected) } catch { $ok = $false } finally { $tc.Dispose() }

Write-Host ''
Write-Host '==================== TUN 客户端配置完成 ====================' -ForegroundColor Green
Write-Host ("线路名称        : 共享代理 ({0})" -f $Server)
Write-Host ("协议 / 端口     : {0} / {1}" -f $Protocol, $port)
Write-Host ("账号 / 密码     : {0} / {1}" -f $User, $Password)
Write-Host ("模式            : {0}" -f $Mode)
Write-Host ("UDP 转发        : {0}" -f $(if ($udp) { '开启（仅 SOCKS5）' } else { '不可用（HTTP 无 UDP）' }))
Write-Host ("TUN 设备名      : {0}" -f $check.device_name)
Write-Host ("端口连通        : {0}" -f $(if ($ok) { 'PASS' } else { 'FAIL - 服务端未启动或跨网段' }))
Write-Host '============================================================'
Write-Host ''
Write-Host '下一步（必须在图形界面点一次，配置才会真正下发）：'
Write-Host '  1. 打开 toci，进入「TUN / VPN」页；'
Write-Host ("  2. 选中线路「共享代理 ({0})」，点「测试连通性与认证」应显示延迟；" -f $Server)
Write-Host '  3. 点「保存配置并应用」，等虚拟网卡 SNI-Proxy-TUN 出现。'
Write-Host ''
Write-Host '验证：DNS 返回 198.18.x.x、网卡 SNI-Proxy-TUN 为 Up 即接管成功。'
Write-Host ("回滚：把 {0} 覆盖回 tun_config.json，再在界面重新应用。" -f $backup)

if ($Launch) {
    $exe = Join-Path $TociDir 'toci.exe'
    if (Test-Path $exe) { Start-Process -FilePath $exe -WorkingDirectory $TociDir }
}
