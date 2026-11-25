# setup-share-server.ps1
# 在提供网络的 Windows 机器上搭建带认证的 HTTP/SOCKS5 代理，并注册登录自启。
# 用法: powershell -ExecutionPolicy Bypass -File setup-share-server.ps1 -User b404

param(
    [int]$Port = 18080,
    [int]$SocksPort = 18081,
    [string]$User = 'b404',
    [string]$Password,
    [string]$TaskName = 'LAN Proxy (gost)',
    [string]$RuleName = 'LAN Proxy (gost)',
    [string]$InstallDir = "$env:LOCALAPPDATA\lan-share\gost",
    [string]$AllowCidr
)

$ErrorActionPreference = 'Stop'

# ---- 自动提权 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port -SocksPort $SocksPort -User `"$User`""
    if ($Password) { $argLine += " -Password `"$Password`"" }
    if ($AllowCidr) { $argLine += " -AllowCidr `"$AllowCidr`"" }
    Write-Host '需要管理员权限，正在请求提权...'
    Start-Process powershell -Verb RunAs -ArgumentList $argLine
    exit 0
}

function Get-CidrString([string]$Ip, [int]$Prefix) {
    $bytes = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    $net = @()
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [math]::Min(8, [math]::Max(0, $Prefix - $i * 8))
        $mask = 256 - [int][math]::Pow(2, 8 - $bits)
        $net += ($bytes[$i] -band $mask)
    }
    return (($net -join '.') + "/$Prefix")
}

# ---- 1. 准备目录与程序 ----
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$exe = Join-Path $InstallDir 'gost.exe'

if (-not (Test-Path $exe)) {
    Write-Host '未找到 gost.exe，开始下载 (v2.12.0 amd64)...'
    $rel = 'https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_windows_amd64.zip'
    $mirrors = @("https://gh-proxy.com/$rel", "https://ghfast.top/$rel", "https://ghproxy.net/$rel", $rel)
    $zip = Join-Path $InstallDir 'gost.zip'
    $ok = $false
    foreach ($u in $mirrors) {
        try {
            Invoke-WebRequest -Uri $u -OutFile $zip -TimeoutSec 90 -UseBasicParsing
            if ((Get-Item $zip).Length -gt 1MB) { $ok = $true; Write-Host "下载成功: $u"; break }
        } catch { Write-Host "镜像失败: $u" }
    }
    if (-not $ok) { throw "所有镜像均下载失败。请手动下载 gost_2.12.0_windows_amd64.zip 并解压到 $InstallDir" }
    Expand-Archive -LiteralPath $zip -DestinationPath $InstallDir -Force
    $found = Get-ChildItem -Recurse $InstallDir -Filter 'gost.exe' | Select-Object -First 1
    if (-not $found) { throw '解压后未找到 gost.exe' }
    if ($found.FullName -ne $exe) { Move-Item $found.FullName $exe -Force }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

# ---- 2. 账号密码 ----
if (-not $Password) {
    $chars = ((48..57) + (65..90) + (97..122)) | ForEach-Object { [char]$_ }
    $Password = -join (1..10 | ForEach-Object { $chars | Get-Random })
}
Set-Content -LiteralPath (Join-Path $InstallDir 'pass.txt') -Value $Password -NoNewline -Encoding ascii

# ---- 3. 防火墙放行网段 ----
if (-not $AllowCidr) {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
    $ipInfo = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 |
              Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if (-not $ipInfo) { throw '无法确定本机网段，请用 -AllowCidr 手动指定（如 192.168.1.0/24）' }
    $AllowCidr = Get-CidrString $ipInfo.IPAddress $ipInfo.PrefixLength
}

Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $Port, $SocksPort -RemoteAddress $AllowCidr -Profile Any | Out-Null

# ---- 4. 启动脚本（密码从文件读，不进命令行） ----
$startScript = Join-Path $InstallDir 'start-proxy.ps1'
@"
`$dir = `$PSScriptRoot
`$pass = (Get-Content "`$dir\pass.txt" -Raw).Trim()
if (Get-Process gost -ErrorAction SilentlyContinue) { exit 0 }
& "`$dir\gost.exe" -L "http://${User}:`$pass@:${Port}" -L "socks5://${User}:`$pass@:${SocksPort}" *>> "`$dir\proxy.log"
"@ | Set-Content -LiteralPath $startScript -Encoding utf8

# ---- 5. 计划任务：登录后自动启动 ----
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "局域网网络共享代理 $Port(HTTP)/$SocksPort(SOCKS5)" -Force | Out-Null

# ---- 6. 启动并自测 ----
Get-Process gost -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5

function Test-Tcp([string]$Target, [int]$P) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { return ($c.ConnectAsync($Target, $P).Wait(3000) -and $c.Connected) }
    catch { return $false }
    finally { $c.Dispose() }
}

$portOk = Test-Tcp '127.0.0.1' $Port

$proxy = New-Object System.Net.WebProxy("http://127.0.0.1:$Port")
$proxy.Credentials = New-Object System.Net.NetworkCredential($User, $Password)
$wc = New-Object System.Net.WebClient
$wc.Proxy = $proxy
$authOk = $false
try { $wc.DownloadString('http://www.baidu.com') | Out-Null; $authOk = $true } catch { $authOk = $false }

$wcNo = New-Object System.Net.WebClient
$wcNo.Proxy = New-Object System.Net.WebProxy("http://127.0.0.1:$Port")
$rejectOk = $false
try { $wcNo.DownloadString('http://www.baidu.com') | Out-Null } catch { $rejectOk = $_.Exception.Message -match '407' }

$localIp = (Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress

Write-Host ''
Write-Host '==================== 网络共享已就绪 ====================' -ForegroundColor Green
Write-Host ("本机 IP        : {0}" -f $localIp)
Write-Host ("HTTP 代理      : {0}:{1}" -f $localIp, $Port)
Write-Host ("SOCKS5 代理    : {0}:{1} (支持 UDP)" -f $localIp, $SocksPort)
Write-Host ("账号 / 密码    : {0} / {1}" -f $User, $Password)
Write-Host ("仅允许网段     : {0}" -f $AllowCidr)
Write-Host ("计划任务       : {0}" -f $TaskName)
Write-Host ("防火墙规则     : {0}" -f $RuleName)
Write-Host ("程序目录       : {0}" -f $InstallDir)
Write-Host '--------------------------------------------------------'
Write-Host ("监听端口       : {0}" -f $(if ($portOk) { 'PASS' } else { 'FAIL - 检查 gost 进程与端口' }))
Write-Host ("认证可用       : {0}" -f $(if ($authOk) { 'PASS' } else { 'FAIL - 代理无法出网' }))
Write-Host ("无凭据被拒绝   : {0}" -f $(if ($rejectOk) { 'PASS' } else { 'WARN - 未返回 407' }))
Write-Host '========================================================'

Write-Host ''
Write-Host '下一步：把上面这组 IP/端口/账号密码交给客户端，按 SKILL.md 的「客户端」段配置。'
