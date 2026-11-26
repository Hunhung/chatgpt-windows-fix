<#
.SYNOPSIS
    ChatGPT / Codex 桌面端（Windows）健康自检与自动修复

.DESCRIPTION
    检查代理、配置、安装包、运行时、下载目录、磁盘等关键环节，给出明确结论。
    默认只检查；加 -Fix 才会自动修复"安全可自动修复"的项（配置被清零/丢失、崩溃残留）。

    所有路径自动探测，不依赖特定用户名或安装位置。

.PARAMETER Fix
    自动修复：config.toml 缺失/被清零时从快照恢复；清理崩溃残留；更新每日快照。

.PARAMETER StartProxy
    发现代理端口没监听时，尝试自动启动代理软件（需配合 -ProxyExe 或常见路径）。

.PARAMETER ProxyExe
    代理软件可执行文件路径。不填则尝试常见路径。

.PARAMETER Quiet
    静默模式，不输出到控制台（供计划任务使用）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File codex-health.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File codex-health.ps1 -Fix -StartProxy

.NOTES
    本脚本不会：删除 .codex 目录、清理数据库、解除 EFS 加密、修改杀毒软件设置、关闭沙箱。
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$Quiet,
    [switch]$StartProxy,
    [string]$ProxyExe
)

$ErrorActionPreference = 'Continue'

# 控制台太窄会把中文截断，交互运行时放宽（失败无所谓）
if (-not $Quiet) {
    try {
        $raw = $Host.UI.RawUI
        $raw.BufferSize = New-Object Management.Automation.Host.Size(120, 3000)
        $raw.WindowSize = New-Object Management.Automation.Host.Size(112, 42)
    } catch { }
}

$script:Issues = New-Object System.Collections.ArrayList
$script:Fixes  = New-Object System.Collections.ArrayList
$script:Lines  = New-Object System.Collections.ArrayList

$ToolkitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReportDir  = Join-Path $ToolkitDir 'reports'
$SnapRoot   = Join-Path $ToolkitDir 'snapshots'
if (-not (Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null }

# ---------- 输出 ----------
function Add-Line {
    param([string]$Text, [string]$Level = 'INFO')
    $line = "[{0}][{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Text
    [void]$script:Lines.Add($line)
    if (-not $Quiet) {
        switch ($Level) {
            'OK'   { Write-Host $line -ForegroundColor Green }
            'WARN' { Write-Host $line -ForegroundColor Yellow }
            'FAIL' { Write-Host $line -ForegroundColor Red }
            'FIX'  { Write-Host $line -ForegroundColor Cyan }
            default { Write-Host $line }
        }
    }
}
function Add-Issue { param([string]$Text) [void]$script:Issues.Add($Text) }

# ---------- 环境探测 ----------
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }

function Get-SystemProxy {
    $k = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if (-not $k) { return $null }
    if ($k.ProxyEnable -ne 1) { return $null }
    $raw = "$($k.ProxyServer)"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $cand = $raw
    if ($raw -match '=') {
        $parts = $raw -split ';'
        $https = $parts | Where-Object { $_ -match '^\s*https=' } | Select-Object -First 1
        $http  = $parts | Where-Object { $_ -match '^\s*http=' }  | Select-Object -First 1
        if ($https) { $cand = ($https -split '=', 2)[1] }
        elseif ($http) { $cand = ($http -split '=', 2)[1] }
    }
    $cand = $cand.Trim()
    if ($cand -notmatch '://') { $cand = "http://$cand" }
    return $cand
}

function Get-ProxyEndpoint {
    param([string]$Url)
    try {
        $u = [uri]$Url
        $p = if ($u.Port -gt 0) { $u.Port } else { 8080 }
        return @{ Host = $u.Host; Port = $p }
    } catch { return $null }
}

function Get-DownloadDir {
    try {
        $sh = New-Object -ComObject Shell.Application
        $p = $sh.NameSpace('shell:Downloads').Self.Path
        if ($p) { return $p }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

$ProxyUrl = Get-SystemProxy
$ProxyEp  = if ($ProxyUrl) { Get-ProxyEndpoint $ProxyUrl } else { $null }

# ---------- 1. 代理端口 ----------
function Test-ProxyPort {
    if (-not $ProxyEp) {
        Add-Line '系统未启用代理（直连模式）' 'INFO'
        return $true
    }
    $listen = Get-NetTCPConnection -LocalPort $ProxyEp.Port -State Listen -ErrorAction SilentlyContinue
    if ($listen) {
        $procId = ($listen | Select-Object -First 1).OwningProcess
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        Add-Line "代理端口 $($ProxyEp.Port) 正在监听（进程: $($p.ProcessName)）" 'OK'
        return $true
    }
    Add-Line "代理端口 $($ProxyEp.Port) 没有监听 —— 代理软件未运行或未开启系统代理" 'FAIL'
    return $false
}

# ---------- 2. 自动拉起代理 ----------
function Start-ProxyApp {
    $cands = @()
    if ($ProxyExe) { $cands += $ProxyExe }
    $cands += @(
        (Join-Path $env:APPDATA 'SakuraCat\SakuraCat\core.exe'),
        'D:\Program Files\SakuraCat\com.sakuracat.app.exe',
        'C:\Program Files\SakuraCat\com.sakuracat.app.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\SakuraCat\com.sakuracat.app.exe'),
        (Join-Path $env:APPDATA 'clash-verge\Clash Verge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Clash Verge\Clash Verge.exe')
    )
    $exe = $null
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { $exe = $c; break } }
    if (-not $exe) {
        Add-Line '找不到代理软件，请手动打开（或用 -ProxyExe 指定路径）' 'WARN'
        return $false
    }
    Add-Line "尝试启动代理软件: $exe" 'INFO'
    try { Start-Process -FilePath $exe -ErrorAction Stop | Out-Null }
    catch { Add-Line "启动失败: $($_.Exception.Message)" 'WARN'; return $false }

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        if (Get-NetTCPConnection -LocalPort $ProxyEp.Port -State Listen -ErrorAction SilentlyContinue) { return $true }
    }
    Add-Line '代理软件已启动，但 60 秒内端口仍未监听' 'WARN'
    return $false
}

# ---------- 3. 出网检查 ----------
function Test-Egress {
    $target = 'https://chatgpt.com/'
    $args = @('-s', '-o', 'NUL', '-w', '%{http_code}', '--max-time', '20')
    if ($ProxyUrl) { $args += @('--proxy', $ProxyUrl) } else { $args += '--noproxy' ; $args += '*' }
    $code = (& curl.exe @args $target 2>$null | Out-String).Trim()
    if ($code -and $code -ne '000') {
        $via = if ($ProxyUrl) { "经代理 $ProxyUrl" } else { '直连' }
        Add-Line "$via 访问 chatgpt.com 成功（HTTP $code）" 'OK'
        return $true
    }
    $via = if ($ProxyUrl) { "经代理 $ProxyUrl" } else { '直连' }
    Add-Line "$via 访问 chatgpt.com 失败（无 HTTP 响应）" 'FAIL'
    Add-Issue '无法访问 chatgpt.com'
    return $false
}

# ---------- 4. 配置文件 ----------
function Test-Config {
    $cfg = Join-Path $CodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $cfg)) {
        Add-Line "config.toml 不存在: $cfg" 'FAIL'
        Add-Issue 'config.toml 缺失'
        if ($Fix -and (Restore-LatestBackup -FileName 'config.toml')) {
            Add-Line '已从备份恢复 config.toml' 'FIX'
            [void]$script:Fixes.Add('恢复 config.toml')
            return $true
        }
        return $false
    }
    $len = (Get-Item -LiteralPath $cfg).Length
    if ($len -lt 100) {
        Add-Line "config.toml 只有 $len 字节 —— 疑似被清零" 'FAIL'
        Add-Issue 'config.toml 疑似被清零'
        if ($Fix -and (Restore-LatestBackup -FileName 'config.toml')) {
            Add-Line '已从备份恢复 config.toml' 'FIX'
            [void]$script:Fixes.Add('恢复 config.toml')
            return $true
        }
        return $false
    }
    Add-Line "config.toml 正常（$len 字节）" 'OK'
    return $true
}

# ---------- 5. .env 代理变量 ----------
function Test-EnvFile {
    $envFile = Join-Path $CodexHome '.env'
    if (-not $ProxyUrl) { Add-Line '未配置系统代理，跳过 .env 检查' 'INFO'; return $true }
    if (-not (Test-Path -LiteralPath $envFile)) {
        Add-Line '.codex\.env 不存在（Codex 靠它给子进程注入代理）' 'WARN'
        Add-Issue '.env 缺失'
        if ($Fix -and (Restore-LatestBackup -FileName '.env')) {
            Add-Line '已从备份恢复 .env' 'FIX'
            [void]$script:Fixes.Add('恢复 .env')
            return $true
        }
        return $false
    }
    $text = Get-Content -LiteralPath $envFile -Raw -ErrorAction SilentlyContinue
    $missing = @()
    foreach ($k in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
        if ($text -notmatch "(?m)^\s*$k\s*=") { $missing += $k }
    }
    if ($missing.Count -eq 0) { Add-Line '.env 中代理变量齐全' 'OK'; return $true }
    Add-Line ('.env 缺少: ' + ($missing -join ', ')) 'WARN'
    Add-Issue ('.env 缺少 ' + ($missing -join ','))
    return $false
}

# ---------- 6. 桌面端安装 ----------
# 注意：Codex 会同时安装若干“框架包”(IsFramework)，它们的 Status 常为 NotAvailable，
# 属于正常现象，不能当主程序判断，否则会误报。
function Get-DesktopAppPackage {
    $all = Get-AppxPackage -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'Codex|ChatGPT' }
    if (-not $all) { return $null }

    # 优先：安装目录下确实有 app\ChatGPT.exe 的那个
    foreach ($p in $all) {
        if (-not $p.InstallLocation) { continue }
        $exe = Join-Path $p.InstallLocation 'app\ChatGPT.exe'
        if (Test-Path -LiteralPath $exe) { return $p }
    }
    # 其次：非框架包里版本最高的
    return ($all | Where-Object { -not $_.IsFramework } |
            Sort-Object Version -Descending | Select-Object -First 1)
}

function Test-Package {
    $pkg = Get-DesktopAppPackage
    if (-not $pkg) {
        Add-Line '未找到 Store 版桌面端（可能装的是其他分发版本）' 'WARN'
        return $null
    }
    if ($pkg.Status -ne 'Ok') {
        Add-Line "安装包状态异常: $($pkg.Status)（$($pkg.Name) $($pkg.Version)）" 'FAIL'
        Add-Issue "安装包状态 $($pkg.Status)"
    } else {
        Add-Line "安装包正常: $($pkg.Name) $($pkg.Version)，状态 Ok" 'OK'
    }
    $exe = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
    if (Test-Path -LiteralPath $exe) {
        $sig = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction SilentlyContinue
        if ($sig -and $sig.Status -eq 'Valid') { Add-Line '主程序签名有效' 'OK' }
        else { Add-Line "主程序签名状态: $($sig.Status)" 'WARN' }
    }
    return $pkg
}

# ---------- 7. 运行时路径 ----------
function Test-RuntimePaths {
    $cfg = Join-Path $CodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $cfg)) { return }
    $text = Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue
    $paths = [regex]::Matches($text, "'([A-Za-z]:\\[^']+?\.(?:exe|mjs))'") |
             ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    if ($paths.Count -eq 0) { Add-Line 'config.toml 中没有可校验的运行时路径' 'INFO'; return }
    $bad = 0
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { Add-Line "运行时存在: $(Split-Path $p -Leaf)" 'OK' }
        else { $bad++; Add-Line "运行时缺失: $p" 'FAIL'; Add-Issue "运行时缺失 $(Split-Path $p -Leaf)" }
    }
    if ($bad -eq 0) { Add-Line "全部 $($paths.Count) 个运行时路径有效" 'OK' }
}

# ---------- 8. 下载目录 ----------
function Test-DownloadDir {
    $dl = Get-DownloadDir
    if (-not (Test-Path -LiteralPath $dl)) {
        Add-Line "下载目录不存在: $dl" 'FAIL'; Add-Issue '下载目录不存在'; return
    }
    $probe = Join-Path $dl ("_codex_health_{0}.tmp" -f (Get-Random))
    try {
        Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        Add-Line "下载目录可写: $dl" 'OK'
    } catch {
        Add-Line "下载目录不可写: $dl —— $($_.Exception.Message)" 'FAIL'
        Add-Issue '下载目录不可写'
    }
}

# ---------- 9. 磁盘 ----------
function Test-DiskSpace {
    $drive = (Split-Path $CodexHome -Qualifier).TrimEnd(':')
    if (-not $drive) { $drive = 'C' }
    $d = Get-PSDrive -Name $drive -ErrorAction SilentlyContinue
    if (-not $d -or $null -eq $d.Free) { return }
    $freeGB = [math]::Round($d.Free / 1GB, 1)
    if ($freeGB -lt 5) { Add-Line "$drive 盘剩余 $freeGB GB，空间不足" 'FAIL'; Add-Issue '磁盘空间不足' }
    elseif ($freeGB -lt 15) { Add-Line "$drive 盘剩余 $freeGB GB，偏紧" 'WARN' }
    else { Add-Line "$drive 盘剩余 $freeGB GB" 'OK' }
}

# ---------- 10. 崩溃残留 ----------
function Test-CrashLeftovers {
    if (-not (Test-Path -LiteralPath $CodexHome)) { return }
    $left = Get-ChildItem -LiteralPath $CodexHome -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*.tmp-*' }
    if ($left.Count -eq 0) { Add-Line '没有崩溃残留文件' 'OK'; return }
    Add-Line "发现 $($left.Count) 个崩溃残留临时文件" 'WARN'
    Add-Issue "崩溃残留 $($left.Count) 个"
    if ($Fix) {
        $dest = Join-Path $ToolkitDir 'crash-leftovers'
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
        $moved = 0
        foreach ($f in $left) {
            try { Move-Item -LiteralPath $f.FullName -Destination $dest -Force; $moved++ } catch { }
        }
        if ($moved -gt 0) {
            Add-Line "已移走 $moved 个残留文件到 $dest" 'FIX'
            [void]$script:Fixes.Add('清理崩溃残留')
        }
    }
}

# ---------- 11. EFS 提示 ----------
function Test-EfsInfo {
    $pkg = Get-DesktopAppPackage
    if (-not $pkg -or -not $pkg.InstallLocation) { return }
    $sample = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $sample)) { return }
    if ((Get-Item -LiteralPath $sample -Force).Attributes -band [IO.FileAttributes]::Encrypted) {
        Add-Line '提示: 安装包文件带 EFS 加密属性（未发现访问错误则无需处理）' 'INFO'
    }
}

# ---------- 每日快照 ----------
function Update-DailySnapshot {
    if (-not (Test-Path -LiteralPath $SnapRoot)) { New-Item -ItemType Directory -Force -Path $SnapRoot | Out-Null }
    $today = Join-Path $SnapRoot (Get-Date -Format 'yyyyMMdd')
    if (-not (Test-Path -LiteralPath $today)) { New-Item -ItemType Directory -Force -Path $today | Out-Null }
    $copied = 0
    foreach ($f in @('config.toml', '.env', 'cap_sid')) {
        $src = Join-Path $CodexHome $f
        if (-not (Test-Path -LiteralPath $src)) { continue }
        if ((Get-Item -LiteralPath $src).Length -lt 1) { continue }
        $dst = Join-Path $today $f
        $same = $false
        if (Test-Path -LiteralPath $dst) {
            $same = ((Get-FileHash -LiteralPath $src).Hash -eq (Get-FileHash -LiteralPath $dst).Hash)
        }
        if (-not $same) { Copy-Item -LiteralPath $src -Destination $dst -Force; $copied++ }
    }
    if ($copied -gt 0) { Add-Line "已更新今日配置快照（$copied 个文件）" 'OK' }
    $all = Get-ChildItem -LiteralPath $SnapRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if ($all.Count -gt 10) {
        $all | Select-Object -Skip 10 | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------- 从备份恢复 ----------
function Restore-LatestBackup {
    param([string]$FileName)
    $dirs = @()
    if (Test-Path -LiteralPath $SnapRoot) {
        $dirs += Get-ChildItem -LiteralPath $SnapRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    }
    $dirs += Get-ChildItem -LiteralPath $ToolkitDir -Directory -Filter 'backup-*' -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending
    foreach ($d in $dirs) {
        $src = Join-Path $d.FullName $FileName
        if (Test-Path -LiteralPath $src) {
            $dst = Join-Path $CodexHome $FileName
            if (Test-Path -LiteralPath $dst) {
                $bad = "$dst.broken-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                Copy-Item -LiteralPath $dst -Destination $bad -Force -ErrorAction SilentlyContinue
                Add-Line "已保留损坏文件副本: $(Split-Path $bad -Leaf)" 'INFO'
            }
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $dst) { return $true }
        }
    }
    Add-Line "备份中找不到 $FileName" 'FAIL'
    return $false
}

# ================= 主流程 =================
$mode = if ($Fix) { '检查 + 自动修复' } else { '仅检查' }
if ($StartProxy) { $mode += ' + 允许启动代理' }
Add-Line "===== ChatGPT/Codex 健康自检开始（$mode） =====" 'INFO'
Add-Line "配置目录: $CodexHome" 'INFO'
Add-Line "系统代理: $(if($ProxyUrl){$ProxyUrl}else{'未启用'})" 'INFO'

$proxyOk = Test-ProxyPort
if (-not $proxyOk -and $StartProxy -and $ProxyEp) {
    if (Start-ProxyApp) {
        Add-Line "代理软件已启动，端口 $($ProxyEp.Port) 恢复监听" 'FIX'
        [void]$script:Fixes.Add('自动启动代理软件')
        $proxyOk = $true
    }
}
if (-not $proxyOk) { Add-Issue '代理端口未监听' }

if ($proxyOk) { [void](Test-Egress) } else { Add-Line '代理未就绪，跳过出网检查' 'INFO' }

$cfgOk = Test-Config
[void](Test-EnvFile)
if ($Fix -and $cfgOk) { Update-DailySnapshot }
[void](Test-Package)
Test-RuntimePaths
Test-DownloadDir
Test-DiskSpace
Test-CrashLeftovers
Test-EfsInfo

$verdict = if ($script:Issues.Count -eq 0) { 'HEALTHY' }
           elseif ($script:Fixes.Count -gt 0 -and $script:Issues.Count -le $script:Fixes.Count) { 'REPAIRED' }
           else { 'PROBLEM' }
$level = switch ($verdict) { 'HEALTHY' { 'OK' } 'REPAIRED' { 'FIX' } default { 'FAIL' } }
Add-Line "===== 结论: $verdict（问题 $($script:Issues.Count) 项，修复 $($script:Fixes.Count) 项） =====" $level
if ($script:Issues.Count -gt 0) { Add-Line ('问题清单: ' + ($script:Issues -join ' / ')) 'WARN' }

$logPath = Join-Path $ReportDir ("health-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$script:Lines | Add-Content -LiteralPath $logPath -Encoding UTF8
$script:Lines | Set-Content -LiteralPath (Join-Path $ReportDir 'latest.txt') -Encoding UTF8
[ordered]@{
    time      = (Get-Date).ToString('s')
    verdict   = $verdict
    codexHome = $CodexHome
    proxy     = $ProxyUrl
    issues    = @($script:Issues)
    fixes     = @($script:Fixes)
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ReportDir 'latest.json') -Encoding UTF8

switch ($verdict) { 'HEALTHY' { exit 0 } 'REPAIRED' { exit 2 } default { exit 1 } }
