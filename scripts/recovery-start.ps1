# 恢复局域网共享代理（D 盘常驻）
# 双击 启动共享代理.cmd 调用本脚本：重建防火墙规则 → 补建开机任务 → 拉起 gost → 自检弹窗
param([switch]$Elevated)

$ErrorActionPreference = 'Continue'
$selfPath = $PSCommandPath
$dir = $PSScriptRoot
if (-not $dir) { $dir = Split-Path -Parent $selfPath }
if (-not $dir) { $dir = 'D:\Doubao\tools\gost' }
$logPath = Join-Path $dir 'restore.log'

function Log([string]$m) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`" -Elevated" | Out-Null
    exit 0
}

Log '=== 开始恢复 ==='

$port = 18080
$socksPort = 18081
$userName = 'shareuser'
$ruleName = 'LAN Proxy (gost)'
$taskName = 'LAN Proxy (gost)'
$passFile = Join-Path $dir 'pass.txt'
$exe = Join-Path $dir 'gost.exe'
$runCmd = Join-Path $dir 'run-proxy.cmd'

if (-not (Test-Path -LiteralPath $exe)) { Log '缺少 gost.exe，无法继续'; exit 1 }
if (-not (Test-Path -LiteralPath $passFile)) { Log '缺少 pass.txt，无法继续'; exit 1 }
if (-not (Test-Path -LiteralPath $runCmd)) { Log '缺少 run-proxy.cmd，无法继续'; exit 1 }
$pass = (Get-Content -LiteralPath $passFile -Raw).Trim()

$localIp = $null
$cidr = $null
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
if ($route) {
    $ipInfo = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if ($ipInfo) {
        $localIp = $ipInfo.IPAddress
        $prefix = $ipInfo.PrefixLength
        $bytes = ([System.Net.IPAddress]::Parse($localIp)).GetAddressBytes()
        $net = @()
        for ($i = 0; $i -lt 4; $i++) {
            $bits = [math]::Min(8, [math]::Max(0, $prefix - $i * 8))
            $mask = 256 - [int][math]::Pow(2, 8 - $bits)
            $net += ($bytes[$i] -band $mask)
        }
        $cidr = (($net -join '.') + "/$prefix")
        Log ("本机 IP {0}，网段 {1}" -f $localIp, $cidr)
    }
}
if (-not $localIp) { Log '未连网：找不到默认路由' }

$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($existing) {
    Log '防火墙规则已存在，跳过'
} elseif ($cidr) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $port, $socksPort -RemoteAddress $cidr -Profile Any | Out-Null
    Log '防火墙规则已重建'
} else {
    Log '无网段信息，防火墙规则未创建'
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$needRebuild = $true
if ($task -and $task.Actions.Count -gt 0) {
    if ($task.Actions[0].Execute -match 'cmd\.exe' -and $task.Actions[0].Arguments -match 'run-proxy\.cmd') { $needRebuild = $false }
}
if ($needRebuild) {
    try {
        $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$runCmd`"" -WorkingDirectory $dir
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
            -Principal $principal -Description '局域网共享代理 18080(HTTP)/18081(SOCKS5)（开机启动）' -Force | Out-Null
        Log '计划任务已按 cmd 启动方式重建（开机启动 / SYSTEM）'
    } catch {
        Log ('计划任务重建失败：' + $_.Exception.Message)
    }
} else {
    Log ("计划任务已就绪，状态 {0}" -f $task.State)
}

if (Get-Process gost -ErrorAction SilentlyContinue) {
    Log 'gost 已在运行'
} else {
    $started = $false
    try {
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Start-Sleep -Seconds 5
        $started = [bool](Get-Process gost -ErrorAction SilentlyContinue)
    } catch { Log ('计划任务启动失败：' + $_.Exception.Message) }
    if (-not $started) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$runCmd`"" -WindowStyle Hidden
        Start-Sleep -Seconds 4
        Log '已用 run-proxy.cmd 直接拉起'
    } else {
        Log 'gost 已通过计划任务启动'
    }
}

Start-Sleep -Seconds 2

$portOk = $false
try {
    $c = New-Object System.Net.Sockets.TcpClient
    $portOk = ($c.ConnectAsync('127.0.0.1', $port).Wait(3000) -and $c.Connected)
    $c.Dispose()
} catch { }

function Get-HttpStatus([string]$targetUrl, $cred) {
    $req = [System.Net.WebRequest]::Create($targetUrl)
    $req.Proxy = New-Object System.Net.WebProxy("http://127.0.0.1:$port")
    if ($cred) { $req.Proxy.Credentials = $cred; $req.Credentials = $cred }
    try {
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return $code
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    } catch { return 0 }
}

$noCred = Get-HttpStatus 'http://www.baidu.com' $null
$withCred = Get-HttpStatus 'http://www.baidu.com' (New-Object System.Net.NetworkCredential($userName, $pass))
$rejectOk = ($noCred -eq 407)
$authOk = ($withCred -eq 200)
Log ("自检：监听={0} 无凭据状态码={1} 带认证状态码={2}" -f $portOk, $noCred, $withCred)

$state = if ($portOk -and $authOk -and $rejectOk) { '共享代理已就绪' } else { '有异常，见 restore.log' }
$msg = @"
$state

服务器 IP : $(if ($localIp) { $localIp } else { '（未连网）' })
HTTP 代理 : $(if ($localIp) { "$localIp`:$port" } else { '-' })
SOCKS5    : $(if ($localIp) { "$localIp`:$socksPort" } else { '-' })
账号 / 密码: $userName / $pass
放行网段   : $(if ($cidr) { $cidr } else { '-' })

手机端：Wi-Fi 代理手动填上面 IP 与 18080，开启认证后填账号密码
"@
try { (New-Object -ComObject WScript.Shell).Popup($msg, 8, '局域网共享代理', 64) | Out-Null } catch { }
