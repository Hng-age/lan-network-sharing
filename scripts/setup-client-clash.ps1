# setup-client-clash.ps1
# 在客户端 Windows 上，把共享代理接进 Clash Verge 并开启 TUN，让 App 流量也走代理。
# 用法: powershell -ExecutionPolicy Bypass -File setup-client-clash.ps1 -Server 192.168.112.32 -Password 密码

param(
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 18080,
    [int]$SocksPort = 18081,
    [string]$User = 'b404',
    [Parameter(Mandatory = $true)][string]$Password,
    [string]$ProfileName = '台式机共享代理',
    [string]$VergeExe,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$cfg = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
if (-not (Test-Path $cfg)) { throw "未找到 Clash Verge 配置目录: $cfg（请先安装并启动一次 Clash Verge）" }

# ---- 1. 备份 ----
$bak = Join-Path $cfg ('.bak_' + (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Path $bak -Force | Out-Null
foreach ($f in 'profiles.yaml', 'verge.yaml', 'config.yaml') {
    if (Test-Path (Join-Path $cfg $f)) { Copy-Item (Join-Path $cfg $f) $bak -Force }
}
Write-Host "已备份现有配置到: $bak"

# ---- 2. 写专用配置 ----
$yaml = @"
mode: rule
log-level: info
allow-lan: false
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
proxies:
  - name: PC-LAN-SOCKS
    type: socks5
    server: $Server
    port: $SocksPort
    username: $User
    password: $Password
    udp: true
  - name: PC-LAN-HTTP
    type: http
    server: $Server
    port: $Port
    username: $User
    password: $Password
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - PC-LAN-SOCKS
      - PC-LAN-HTTP
rules:
  - MATCH,PROXY
"@
Set-Content -LiteralPath (Join-Path $cfg 'profiles\pclan.yaml') -Value $yaml -Encoding utf8

# ---- 3. 注册并设为当前配置 ----
$pfPath = Join-Path $cfg 'profiles.yaml'
$pf = Get-Content $pfPath -Raw
$pf = [regex]::Replace($pf, '(?m)^current:.*$', 'current: pclan0001')
if ($pf -notmatch 'uid: pclan0001') {
    $pf = $pf.TrimEnd() + "`n- uid: pclan0001`n  type: local`n  name: $ProfileName`n  file: pclan.yaml`n  updated: $([DateTimeOffset]::Now.ToUnixTimeSeconds())`n"
}
Set-Content -LiteralPath $pfPath -Value $pf -Encoding utf8 -NoNewline

# ---- 4. 打开 TUN 与系统代理 ----
$vgPath = Join-Path $cfg 'verge.yaml'
$vg = Get-Content $vgPath -Raw
$vg = $vg -replace 'enable_tun_mode:\s*false', 'enable_tun_mode: true'
$vg = $vg -replace 'enable_system_proxy:\s*false', 'enable_system_proxy: true'
Set-Content -LiteralPath $vgPath -Value $vg -Encoding utf8 -NoNewline

# ---- 5. 重启客户端 ----
if (-not $NoStart) {
    Get-Process clash-verge -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
    Remove-Item (Join-Path $cfg 'singleton-instance.json'), (Join-Path $cfg 'singleton-instance.lock') -Force -ErrorAction SilentlyContinue

    if (-not $VergeExe) {
        $keys = @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $item = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Clash\s*Verge' } | Select-Object -First 1
        if ($item -and $item.InstallLocation) {
            $VergeExe = Join-Path ($item.InstallLocation.Trim('"')) 'clash-verge.exe'
        }
        if (-not $VergeExe -or -not (Test-Path $VergeExe)) {
            foreach ($p in 'D:\Clash Verge\clash-verge.exe', 'C:\Program Files\Clash Verge\clash-verge.exe') {
                if (Test-Path $p) { $VergeExe = $p; break }
            }
        }
        if (-not $VergeExe -or -not (Test-Path $VergeExe)) { throw '找不到 clash-verge.exe，请用 -VergeExe 指定完整路径' }
    }
    Start-Process -FilePath $VergeExe -WorkingDirectory (Split-Path $VergeExe)
    Start-Sleep -Seconds 12
}

# ---- 6. 验证 ----
Start-Sleep -Seconds 2
$tun = Get-NetAdapter -Name 'Meta' -ErrorAction SilentlyContinue
$sysProxy = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).ProxyServer
$dnsIp = (Resolve-DnsName 'www.baidu.com' -Type A -ErrorAction SilentlyContinue | Where-Object IPAddress | Select-Object -First 1).IPAddress
$egress = $null
try { $egress = (Invoke-RestMethod 'http://ip-api.com/json/?fields=query,isp' -NoProxy -TimeoutSec 12).query } catch {}

Write-Host ''
Write-Host '==================== 客户端接入结果 ====================' -ForegroundColor Green
Write-Host ("节点            : {0}:{1} (SOCKS5) / {0}:{2} (HTTP)" -f $Server, $SocksPort, $Port)
Write-Host ("当前配置        : {0}" -f $ProfileName)
Write-Host ("TUN 网卡 Meta   : {0}" -f $(if ($tun -and $tun.Status -eq 'Up') { 'PASS' } else { 'FAIL - TUN 未启动（检查服务模式/管理员）' }))
Write-Host ("系统代理        : {0}" -f $(if ($sysProxy -match '127.0.0.1') { "PASS ($sysProxy)" } else { "WARN (实际: $sysProxy)" }))
Write-Host ("DNS fake-ip     : {0}" -f $(if ($dnsIp -like '198.18.*') { "PASS ($dnsIp)" } else { "WARN ($dnsIp)" }))
Write-Host ("出口 IP         : {0}" -f $(if ($egress) { $egress } else { 'FAIL - 无法出网，检查服务端是否在线' }))
Write-Host '========================================================'
Write-Host ''
Write-Host "想回滚: 把 $bak 里的 profiles.yaml / verge.yaml / config.yaml 覆盖回去，并删除 profiles\pclan.yaml"
