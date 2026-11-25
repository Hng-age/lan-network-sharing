# verify-share.ps1
# 验证共享链路：端口可达 → 认证生效 → (可选) TUN 接管。
# 用法: powershell -ExecutionPolicy Bypass -File verify-share.ps1 -Server 192.168.1.10 -Password 密码 -CheckTun -TunName SNI-Proxy-TUN

param(
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 18080,
    [int]$SocksPort = 18081,
    [string]$User = 'shareuser',
    [Parameter(Mandatory = $true)][string]$Password,
    [switch]$CheckTun,
    [string]$TunName = 'Meta'
)

$results = [System.Collections.ArrayList]::new()
function Add-Result([string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$results.Add([pscustomobject]@{ Check = $Name; Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

# ---- 1. 端口可达 ----
foreach ($p in $Port, $SocksPort) {
    $c = New-Object System.Net.Sockets.TcpClient
    $ok = $false
    try { $ok = ($c.ConnectAsync($Server, $p).Wait(3000) -and $c.Connected) } catch { $ok = $false } finally { $c.Dispose() }
    Add-Result "端口 $p 可达" $ok $(if ($ok) { "$Server`:$p" } else { '跨网段 / AP 隔离 / 服务端未启动' })
}

# ---- 2. 无凭据应 407 ----
$wcNo = New-Object System.Net.WebClient
$wcNo.Proxy = New-Object System.Net.WebProxy("http://${Server}:$Port")
$status407 = $false
try { $wcNo.DownloadString('http://www.baidu.com') | Out-Null; $detail = '未要求认证' }
catch { $status407 = $_.Exception.Message -match '407'; $detail = $_.Exception.Message.Split([Environment]::NewLine)[0] }
Add-Result '无凭据被拒绝(407)' $status407 $detail

# ---- 3. 带凭据可出网 ----
$wc = New-Object System.Net.WebClient
$proxy = New-Object System.Net.WebProxy("http://${Server}:$Port")
$proxy.Credentials = New-Object System.Net.NetworkCredential($User, $Password)
$wc.Proxy = $proxy
$authOk = $false
try { $len = $wc.DownloadString('http://www.baidu.com').Length; $authOk = $len -gt 0 }
catch { $authOk = $false }
Add-Result '认证后出网' $authOk $(if ($authOk) { 'HTTP 200' } else { '账号密码错误或服务端无出口' })

# ---- 4. TUN 接管（客户端本机） ----
if ($CheckTun) {
    $tun = Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue
    Add-Result "TUN 网卡 $TunName Up" ($tun -and $tun.Status -eq 'Up') $(if ($tun) { $tun.Status } else { '未创建：检查 TUN 开关与服务模式（Clash 用 Meta，toci 用 SNI-Proxy-TUN）' })

    $tunRoutes = Get-NetRoute -InterfaceAlias $TunName -ErrorAction SilentlyContinue
    $cover = $tunRoutes | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0', '0.0.0.0/1', '0.0.0.0/5', '128.0.0.0/1') }
    Add-Result '公网流量已进 TUN' ($null -ne $cover) $(if ($cover) { ($cover | Select-Object -First 2 -ExpandProperty DestinationPrefix) -join ', ' } else { 'TUN 上无公网路由，未接管' })

    $dnsIp = (Resolve-DnsName 'www.baidu.com' -Type A -ErrorAction SilentlyContinue | Where-Object IPAddress | Select-Object -First 1).IPAddress
    Add-Result 'DNS fake-ip 生效' ($dnsIp -like '198.18.*') "$dnsIp"

    $egress = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create('http://www.baidu.com')
        $req.Proxy = $null
        $req.Timeout = 12000
        $req.UserAgent = 'lan-share-check'
        $resp = $req.GetResponse()
        $code = $resp.StatusCode
        $resp.Close()
        if ($code -eq 200) { $egress = 'HTTP 200' }
    } catch { $egress = $null }
    Add-Result '绕过系统代理可出网' ($null -ne $egress) $(if ($egress) { $egress } else { '直连失败，TUN 未接管或上游不通' })
}

# ---- 输出 ----
Write-Host ''
$results | Format-Table -AutoSize
$fails = @($results | Where-Object Result -eq 'FAIL').Count
if ($fails -eq 0) {
    Write-Host '结论: 全部通过，链路可用。' -ForegroundColor Green
    exit 0
} else {
    Write-Host "结论: $fails 项失败，按 references/troubleshooting.md 对号入座。" -ForegroundColor Yellow
    exit 1
}
