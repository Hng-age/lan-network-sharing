# setup-share-server.ps1
# 在提供网络的 Windows 机器上搭建带认证的 HTTP/SOCKS5 代理，并注册登录自启。
# 用法: powershell -ExecutionPolicy Bypass -File setup-share-server.ps1 -User shareuser
# 程序目录默认落在 D 盘（D:\Doubao\tools\gost），没有 D 盘才回退到 LOCALAPPDATA。

param(
    [int]$Port = 18080,
    [int]$SocksPort = 18081,
    [string]$User = 'shareuser',
    [string]$Password,
    [string]$TaskName = 'LAN Proxy (gost)',
    [string]$RuleName = 'LAN Proxy (gost)',
    [string]$InstallDir,
    [string]$AllowCidr,
    [switch]$NoAutoStart,
    [switch]$AtStartup
)

$ErrorActionPreference = 'Stop'

# ---- 自动提权 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port -SocksPort $SocksPort -User `"$User`" -TaskName `"$TaskName`" -RuleName `"$RuleName`""
    if ($Password) { $argLine += " -Password `"$Password`"" }
    if ($InstallDir) { $argLine += " -InstallDir `"$InstallDir`"" }
    if ($AllowCidr) { $argLine += " -AllowCidr `"$AllowCidr`"" }
    if ($NoAutoStart) { $argLine += ' -NoAutoStart' }
    if ($AtStartup) { $argLine += ' -AtStartup' }
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

# ---- 1. 准备目录与程序（默认落 D 盘，避免占系统盘） ----
if (-not $InstallDir) {
    if (Test-Path 'D:\') { $InstallDir = 'D:\Doubao\tools\gost' }
    else {
        $InstallDir = "$env:LOCALAPPDATA\lan-share\gost"
        Write-Warning '未检测到 D 盘，回退到 LOCALAPPDATA；如需固定到 D 盘请先分区或用 -InstallDir 指定。'
    }
}
Write-Host ("程序目录        : {0}" -f $InstallDir)
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

# ---- 4. 启动脚本（cmd 版：密码从 pass.txt 读，不进命令行；避免 powershell 以 SYSTEM 写日志被拒） ----
$startScript = Join-Path $InstallDir 'run-proxy.cmd'
@"
@echo off
rem 由开机任务调用：从 pass.txt 读密码后后台启动 gost，日志追加到 proxy.log
setlocal
set "DIR=%~dp0"
set /p PASS=<"%DIR%pass.txt"
tasklist /fi "imagename eq gost.exe" 2>nul | find /i "gost.exe" >nul && exit /b 0
start "" /b "%DIR%gost.exe" -L "http://${User}:%PASS%@:${Port}" -L "socks5://${User}:%PASS%@:${SocksPort}" >> "%DIR%proxy.log" 2>&1
endlocal
"@ | Set-Content -LiteralPath $startScript -Encoding ascii

# ---- 5. 计划任务：登录后自动启动（-NoAutoStart 可跳过） ----
if (-not $NoAutoStart) {
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' `
        -Argument "/c `"$startScript`"" -WorkingDirectory $InstallDir
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    if ($AtStartup) {
        # 开机即起，不等用户登录（SYSTEM 身份，日志仍写 D 盘目录）
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $desc = "局域网网络共享代理 $Port(HTTP)/$SocksPort(SOCKS5)（开机启动）"
    } else {
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $desc = "局域网网络共享代理 $Port(HTTP)/$SocksPort(SOCKS5)（登录启动）"
    }
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description $desc -Force | Out-Null
} else {
    Write-Host '已跳过开机自启注册（-NoAutoStart）。需要时手动运行 run-proxy.cmd。'
}

# ---- 6. 启动并自测 ----
Get-Process gost -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
if ($NoAutoStart) {
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$startScript`"" -WindowStyle Hidden
} else {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    if (-not (Get-Process gost -ErrorAction SilentlyContinue)) {
        Write-Warning '计划任务未拉起 gost，改用 run-proxy.cmd 直接启动'
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$startScript`"" -WindowStyle Hidden
    }
}
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
Write-Host ("计划任务       : {0}" -f $(if ($NoAutoStart) { '未注册（-NoAutoStart）' } else { $TaskName }))
Write-Host ("防火墙规则     : {0}" -f $RuleName)
Write-Host ("程序目录       : {0}" -f $InstallDir)
Write-Host '--------------------------------------------------------'
Write-Host ("监听端口       : {0}" -f $(if ($portOk) { 'PASS' } else { 'FAIL - 检查 gost 进程与端口' }))
Write-Host ("认证可用       : {0}" -f $(if ($authOk) { 'PASS' } else { 'FAIL - 代理无法出网' }))
Write-Host ("无凭据被拒绝   : {0}" -f $(if ($rejectOk) { 'PASS' } else { 'WARN - 未返回 407' }))
Write-Host '========================================================'

Write-Host ''
Write-Host '下一步：把上面这组 IP/端口/账号密码交给客户端，按 SKILL.md 的「客户端」段配置。'
