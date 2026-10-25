# gh-fast.ps1 - One-click GitHub accelerator for Windows
#
# Routes ONLY GitHub traffic through a local socks5 proxy (WARP/wireproxy,
# clash, v2ray ... anything listening on 127.0.0.1). Everything else stays
# direct. Covers: browser (PAC), git https, git ssh, and a `ghfast` shell
# switch for gh/curl/wget.
#
# Actions:
#   install    full setup: PAC + git + ssh + shell hook + autostart + shortcut
#   uninstall  revert everything installed above (keeps the proxy itself)
#   on         light day-to-day: ensure proxy is up, enable PAC, open github.com
#   off        disable browser PAC only
#   status     diagnose every channel
#
# Requires PowerShell 5.1+ (stock Windows). No admin rights needed.

param(
    [ValidateSet('install', 'uninstall', 'on', 'off', 'status')]
    [string]$Action = 'status',
    [switch]$NoOpen,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------
$SocksHost        = '127.0.0.1'
$PreferredPort    = 25344                       # wireproxy (WARP) default
$CandidatePorts   = @(25344, 7890, 7897, 1080, 10808, 10809, 2080)
$WireproxyDir     = Join-Path $env:LOCALAPPDATA 'claude-proxy\warp'
$WireproxyExe     = Join-Path $WireproxyDir 'wireproxy.exe'
$ToolDir          = $PSScriptRoot
$PacPath          = Join-Path $ToolDir 'github.pac'
$VbsPath          = Join-Path $ToolDir 'start-wireproxy.vbs'
$OnBat            = Join-Path $ToolDir 'GitHub-Fast-On.bat'
$RegInternet      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$RunKey           = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName          = 'github-fast-wireproxy'
$GitDomains       = @('github.com', 'codeload.github.com',
                      'objects.githubusercontent.com', 'gist.github.com')
$SshConfig        = Join-Path $env:USERPROFILE '.ssh\config'
$SshMark          = 'github-fast ssh proxy'
$ShellMark        = 'github-fast'

$PacDomains = @(
    'github.com', 'githubusercontent.com', 'githubassets.com',
    'github.io', 'github.dev', 'githubcopilot.com',
    'ghcr.io', 'githubapp.com', 'githubcloud.com'
)

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
function Test-Port([int]$p) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($SocksHost, $p, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(600, $false) -and $client.Connected) { return $true }
        return $false
    } catch { return $false }
    finally { $client.Close() }
}

function Find-SocksPort {
    if ($Port -gt 0) { if (Test-Port $Port) { return $Port }; return 0 }
    foreach ($p in ($PreferredPort, $CandidatePorts | Where-Object { $_ -ne $PreferredPort })) {
        if (Test-Port $p) { return $p }
    }
    return 0
}

function Update-ProxySettings {
    $sig = '[DllImport("wininet.dll", SetLastError = true)] public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);'
    $type = Add-Type -MemberDefinition $sig -Name WinINet2 -Namespace Proxy -PassThru
    $type::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    $type::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

function Start-Wireproxy {
    Start-Process -FilePath $WireproxyExe -ArgumentList "-c `"$WireproxyDir\wireproxy.conf`"" `
        -WorkingDirectory $WireproxyDir -WindowStyle Hidden
}

function Test-TunnelHealth([int]$p, [int]$TimeoutSec = 8) {
    # the socks port may listen while the upstream tunnel is dead; probe for real
    $code = & curl.exe -s -o NUL -w "%{http_code}" --connect-timeout $TimeoutSec `
        -x "socks5h://${SocksHost}:$p" "https://api.github.com" 2>$null
    return ($code -match '^2\d\d$')
}

function Stop-Wireproxy {
    $listener = netstat -ano | Select-String "TCP\s+${SocksHost}:${PreferredPort}\s.*LISTENING"
    if ($listener) {
        $procId = ("$listener" -split '\s+')[-1]
        if ($procId -match '^\d+$') {
            & taskkill /PID $procId /F 2>$null | Out-Null
            Start-Sleep -Seconds 1
        }
    }
}

function Restart-Wireproxy {
    # WARP tunnels die silently (UDP flows get culled); a restart revives them
    Stop-Wireproxy
    Start-Wireproxy
}

function Ensure-Wireproxy {
    $port = Find-SocksPort
    if ($port -and (Test-TunnelHealth $port)) { return $true }

    if (-not (Test-Path $WireproxyExe)) {
        if ($port) {
            Write-Host "[!!] socks5 ${SocksHost}:$port is listening but the tunnel is unhealthy." -ForegroundColor Red
            Write-Host "    Cannot auto-fix (wireproxy.exe not found). Restart your proxy manually." -ForegroundColor Yellow
        } else {
            Write-Host "[ERROR] No local socks5 proxy found and wireproxy.exe missing:" -ForegroundColor Red
            Write-Host "        $WireproxyExe" -ForegroundColor Red
            Write-Host "        Start your proxy (clash/v2ray/wireproxy) or edit `$PreferredPort in gh-fast.ps1." -ForegroundColor Yellow
        }
        return $false
    }

    # WARP handshakes succeed probabilistically; retry the whole start cycle
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (Find-SocksPort) {
            Write-Host "[..] attempt ${attempt}: tunnel unhealthy - restarting wireproxy ..."
            Restart-Wireproxy
        } else {
            Write-Host "[..] attempt ${attempt}: starting wireproxy (WARP) ..."
            Start-Wireproxy
        }
        # wait for the socks port ...
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 1
            if (Find-SocksPort) { break }
        }
        # ... then give the WireGuard tunnel a moment before probing
        Start-Sleep -Seconds 5
        for ($i = 0; $i -lt 10; $i++) {
            $port = Find-SocksPort
            if ($port -and (Test-TunnelHealth $port 4)) {
                Write-Host "[OK] wireproxy tunnel healthy (${SocksHost}:$port)" -ForegroundColor Green
                return $true
            }
            Start-Sleep -Seconds 1
        }
        Stop-Wireproxy   # clean slate for the next attempt
    }
    Write-Host "[ERROR] wireproxy tunnel did not recover (WARP endpoint may be down)" -ForegroundColor Red
    return $false
}

# --------------------------------------------------------------------------
# PAC (browser)
# --------------------------------------------------------------------------
function Write-Pac([int]$p) {
    $list = ($PacDomains | ForEach-Object { '  "' + $_ + '"' }) -join ",`n"
    $tpl = @"
// github-fast PAC - route GitHub domains through local socks5, all else direct
var PROXY = "SOCKS5 ${SocksHost}:$p; SOCKS ${SocksHost}:$p; DIRECT";
var DOMAINS = [
$list
];
function FindProxyForURL(url, host) {
  host = host.toLowerCase();
  if (host.length > 0 && host.charAt(host.length - 1) == ".") {
    host = host.substring(0, host.length - 1);
  }
  for (var i = 0; i < DOMAINS.length; i++) {
    if (dnsDomainIs(host, DOMAINS[i])) { return PROXY; }
  }
  return "DIRECT";
}
"@
    Set-Content -Path $PacPath -Value $tpl -Encoding ASCII
}

function Enable-Pac {
    $pacUrl = 'file:///' + ($PacPath -replace '\\', '/')
    Set-ItemProperty -Path $RegInternet -Name AutoConfigURL -Value $pacUrl
    Set-ItemProperty -Path $RegInternet -Name ProxyEnable -Value 0
    Update-ProxySettings
    Write-Host "[OK] Browser PAC  -> $pacUrl" -ForegroundColor Green
}

function Disable-Pac {
    Remove-ItemProperty -Path $RegInternet -Name AutoConfigURL -ErrorAction SilentlyContinue
    Update-ProxySettings
    Write-Host "[OK] Browser PAC  -> removed (browser back to direct)" -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# git https
# --------------------------------------------------------------------------
function Enable-GitProxy([int]$p) {
    foreach ($d in $GitDomains) {
        & git config --global "http.https://$d.proxy" "socks5h://${SocksHost}:$p" | Out-Null
    }
    Write-Host "[OK] git https    -> socks5h://${SocksHost}:$p (github domains only)" -ForegroundColor Green
}

function Disable-GitProxy {
    foreach ($d in $GitDomains) {
        & git config --global --unset-all "http.https://$d.proxy" 2>$null
    }
    Write-Host "[OK] git https    -> proxy entries removed" -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# git ssh (ssh.github.com:443 via socks5)
# --------------------------------------------------------------------------
function Find-ConnectExe {
    foreach ($base in @("$env:ProgramFiles\Git", "$env:ProgramFiles(x86)\Git")) {
        foreach ($sub in @('ucrt64\bin', 'mingw64\bin')) {
            $c = Join-Path $base "$sub\connect.exe"
            if (Test-Path $c) { return $c }
        }
    }
    return $null
}

function Enable-SshProxy([int]$p) {
    if (-not (Test-Path $SshConfig)) {
        Write-Host "[--] git ssh      -> no ~/.ssh/config, skipped" -ForegroundColor DarkGray
        return
    }
    if (Select-String -Path $SshConfig -Pattern $SshMark -SimpleMatch -Quiet) {
        Write-Host "[OK] git ssh      -> already proxied" -ForegroundColor Green
        return
    }
    $connect = Find-ConnectExe
    if (-not $connect) {
        Write-Host "[--] git ssh      -> connect.exe not found (Git for Windows), skipped" -ForegroundColor DarkGray
        return
    }
    $lines = [System.IO.File]::ReadAllLines($SshConfig)
    $out = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    foreach ($ln in $lines) {
        $out.Add($ln)
        if (-not $inserted -and $ln -match '^Host\s+github\.com\s*$') {
            $out.Add("    # $SshMark (delete these 4 lines to revert)")
            $out.Add("    HostName ssh.github.com")
            $out.Add("    Port 443")
            $out.Add("    ProxyCommand `"$connect`" -S ${SocksHost}:$p %h %p")
            $inserted = $true
        }
    }
    if (-not $inserted) {
        Write-Host "[--] git ssh      -> no 'Host github.com' block, skipped" -ForegroundColor DarkGray
        return
    }
    [System.IO.File]::WriteAllLines($SshConfig, $out)
    Write-Host "[OK] git ssh      -> ssh.github.com:443 via socks5" -ForegroundColor Green
}

function Disable-SshProxy {
    if (-not (Test-Path $SshConfig)) { return }
    $lines = [System.IO.File]::ReadAllLines($SshConfig)
    $out = New-Object System.Collections.Generic.List[string]
    $skip = 0
    foreach ($ln in $lines) {
        if ($skip -gt 0) { $skip--; continue }
        if ($ln -match "# $SshMark") { $skip = 3; continue }   # drop marker + 3 lines
        $out.Add($ln)
    }
    [System.IO.File]::WriteAllLines($SshConfig, $out)
    Write-Host "[OK] git ssh      -> reverted to direct :22" -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# ghfast shell hook (gh / curl / wget switch)
# --------------------------------------------------------------------------
$BashHook = @"
# >>> $ShellMark >>>
ghfast() {
  case "`$1" in
    on)  export HTTPS_PROXY=socks5h://${SocksHost}:__PORT__ HTTP_PROXY=socks5h://${SocksHost}:__PORT__; echo "proxy ON  -> `$HTTPS_PROXY" ;;
    off) unset HTTPS_PROXY HTTP_PROXY; echo "proxy OFF" ;;
    *)   echo "HTTPS_PROXY=`${HTTPS_PROXY:-<unset>}  (usage: ghfast on|off)" ;;
  esac
}
# <<< $ShellMark <<<
"@

$PsHook = @"
# >>> $ShellMark >>>
function ghfast {
    param([ValidateSet('on','off','status')][string]`$Action = 'status')
    `$p = 'socks5h://${SocksHost}:__PORT__'
    switch (`$Action) {
        'on'     { `$env:HTTPS_PROXY = `$p; `$env:HTTP_PROXY = `$p; Write-Host "proxy ON  -> `$p" -ForegroundColor Green }
        'off'    { Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue; Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue; Write-Host 'proxy OFF' -ForegroundColor Yellow }
        default  { Write-Host "HTTPS_PROXY = `$env:HTTPS_PROXY  (usage: ghfast on|off)" }
    }
}
# <<< $ShellMark <<<
"@

function Enable-ShellHook([int]$p) {
    $bashrc = Join-Path $env:USERPROFILE '.bashrc'
    Add-Content -Path $bashrc -Value ("`n" + $BashHook -replace '__PORT__', "$p") -Encoding ASCII
    $psDir  = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell'
    $psProf = Join-Path $psDir 'profile.ps1'
    if (-not (Test-Path $psDir)) { New-Item -ItemType Directory -Path $psDir | Out-Null }
    Add-Content -Path $psProf -Value ("`n" + $PsHook -replace '__PORT__', "$p") -Encoding ASCII
    Write-Host "[OK] ghfast hook  -> .bashrc + PowerShell profile (ghfast on/off)" -ForegroundColor Green
}

function Disable-ShellHook {
    foreach ($f in @((Join-Path $env:USERPROFILE '.bashrc'),
                     (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\profile.ps1'))) {
        if (-not (Test-Path $f)) { continue }
        $text = [System.IO.File]::ReadAllText($f)
        $new = [regex]::Replace($text, "(?s)\r?\n?# >>> $ShellMark >>>.*?# <<< $ShellMark <<<\r?\n?", "`r`n")
        if ($new -ne $text) { [System.IO.File]::WriteAllText($f, $new) }
    }
    Write-Host "[OK] ghfast hook  -> removed from shells" -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# wireproxy autostart (HKCU Run + hidden vbs launcher)
# --------------------------------------------------------------------------
function Write-Vbs {
    $vbs = @"
' github-fast: hidden-start wireproxy at logon
Dim shell
Set shell = CreateObject("WScript.Shell")
shell.Run """$WireproxyExe"" -c ""$WireproxyDir\wireproxy.conf""", 0, False
"@
    Set-Content -Path $VbsPath -Value $vbs -Encoding ASCII
}

function Enable-Autostart {
    if (-not (Test-Path $WireproxyExe)) {
        Write-Host "[--] autostart    -> wireproxy not found, skipped" -ForegroundColor DarkGray
        return
    }
    Write-Vbs
    Set-ItemProperty -Path $RunKey -Name $RunName -Value "wscript.exe `"$VbsPath`""
    Write-Host "[OK] autostart    -> wireproxy at logon (HKCU Run)" -ForegroundColor Green
}

function Disable-Autostart {
    Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
    if (Test-Path $VbsPath) { Remove-Item $VbsPath -Force }
    Write-Host "[OK] autostart    -> removed" -ForegroundColor Yellow
}

function New-Shortcut {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'GitHub Fast.lnk'))
    $lnk.TargetPath = $OnBat
    $lnk.WorkingDirectory = $ToolDir
    $lnk.Description = 'Enable GitHub accelerator and open github.com'
    $lnk.IconLocation = 'C:\Windows\System32\shell32.dll,13'
    $lnk.Save()
    Write-Host "[OK] shortcut     -> Desktop 'GitHub Fast.lnk'" -ForegroundColor Green
}

# --------------------------------------------------------------------------
# status / diagnostics
# --------------------------------------------------------------------------
function Test-GithubLatency([string]$Label, [string[]]$CurlArgs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = & curl.exe -s -o NUL -w "%{http_code}" --connect-timeout 6 @CurlArgs "https://github.com" 2>$null
    $sw.Stop()
    if ($code -eq '200') {
        Write-Host ("    {0,-10} HTTP 200 in {1,5:n1}s" -f $Label, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    } else {
        Write-Host ("    {0,-10} FAILED (code={1}) in {2,5:n1}s" -f $Label, $code, $sw.Elapsed.TotalSeconds) -ForegroundColor Red
    }
}

function Show-Status {
    Write-Host "=== github-fast status ===" -ForegroundColor Cyan

    $cur = (Get-ItemProperty -Path $RegInternet -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
    if ($cur) { Write-Host "browser PAC  : ON  ($cur)" -ForegroundColor Green }
    else      { Write-Host "browser PAC  : off (browser direct)" -ForegroundColor Yellow }

    $port = Find-SocksPort
    if ($port) {
        if (Test-TunnelHealth $port) {
            Write-Host "socks5 proxy : UP + tunnel healthy (${SocksHost}:$port)" -ForegroundColor Green
        } else {
            Write-Host "socks5 proxy : listening but tunnel DEAD - run 'on' or 'install' to auto-restart (${SocksHost}:$port)" -ForegroundColor Red
        }
    } else {
        Write-Host "socks5 proxy : NOT RUNNING (run install / on)" -ForegroundColor Red
    }

    $gitProxy = & git config --global --get http.https://github.com.proxy 2>$null
    if ($gitProxy) { Write-Host "git https    : proxied ($gitProxy)" -ForegroundColor Green }
    else           { Write-Host "git https    : direct" -ForegroundColor Yellow }

    if ((Test-Path $SshConfig) -and (Select-String -Path $SshConfig -Pattern $SshMark -SimpleMatch -Quiet)) {
        Write-Host "git ssh      : proxied (ssh.github.com:443)" -ForegroundColor Green
    } else {
        Write-Host "git ssh      : direct :22" -ForegroundColor Yellow
    }

    $run = (Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue).$RunName
    if ($run) { Write-Host "autostart    : ON ($run)" -ForegroundColor Green }
    else      { Write-Host "autostart    : off" -ForegroundColor Yellow }

    Write-Host "latency to https://github.com:"
    Test-GithubLatency 'direct' @()
    if ($port) { Test-GithubLatency 'via proxy' @('-x', "socks5h://${SocksHost}:$port") }
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
switch ($Action) {

    'install' {
        Write-Host "=== github-fast install ===" -ForegroundColor Cyan
        if (-not (Ensure-Wireproxy)) { exit 1 }
        $port = Find-SocksPort
        Write-Host "using socks5 ${SocksHost}:$port"
        Write-Pac $port
        Enable-Pac
        Enable-GitProxy $port
        Enable-SshProxy $port
        Enable-ShellHook $port
        Enable-Autostart
        New-Shortcut
        Write-Host ""
        Write-Host "All set. GitHub-only routing via ${SocksHost}:$port; everything else direct." -ForegroundColor Cyan
        Write-Host "Uninstall any time: powershell gh-fast.ps1 -Action uninstall"
    }

    'uninstall' {
        Write-Host "=== github-fast uninstall ===" -ForegroundColor Cyan
        Disable-Pac
        Disable-GitProxy
        Disable-SshProxy
        Disable-ShellHook
        Disable-Autostart
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'GitHub Fast.lnk'
        if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "[OK] shortcut     -> removed" -ForegroundColor Yellow }
        if (Test-Path $PacPath) { Remove-Item $PacPath -Force }
        Write-Host ""
        Write-Host "Reverted. (The proxy process itself was left running.)" -ForegroundColor Cyan
    }

    'on' {
        if (-not (Ensure-Wireproxy)) { exit 1 }
        $port = Find-SocksPort
        if (-not (Test-Path $PacPath)) { Write-Pac $port }
        Enable-Pac
        if (-not $NoOpen) {
            Write-Host "[..] Opening https://github.com ..."
            Start-Process 'https://github.com'
        }
    }

    'off' { Disable-Pac }

    'status' { Show-Status }
}
