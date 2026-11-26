<#
.SYNOPSIS
    一键安装：把自检工具装到本机，注册计划任务，创建桌面快捷方式

.DESCRIPTION
    在克隆下来的仓库里运行本脚本即可。它会：
      1. 把脚本复制到 %USERPROFILE%\CodexFix
      2. 备份当前 Codex 配置
      3. 注册计划任务（登录后 3 分钟 + 每天 12:30 自动自检）
      4. 在桌面创建「一键修复网络」快捷方式
      5. 立即跑一次自检

    重复运行是安全的（会覆盖更新脚本、重建任务）。

.PARAMETER InstallDir
    安装目录，默认 %USERPROFILE%\CodexFix

.PARAMETER NoTask
    跳过计划任务注册

.PARAMETER NoShortcut
    跳过桌面快捷方式

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'CodexFix'),
    [switch]$NoTask,
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'

function Say  { param($m, $c = 'Gray')  Write-Host $m -ForegroundColor $c }
function Ok   { param($m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  [!!] $m" -ForegroundColor Yellow }

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }

Say ''
Say '=====================================================' 'Cyan'
Say '  ChatGPT / Codex 桌面端 修复工具 - 安装' 'Cyan'
Say '=====================================================' 'Cyan'
Say ''

# ---------- 1. 准备安装目录 ----------
Say "[1/6] 准备安装目录" 'White'
if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}
Ok "安装目录: $InstallDir"

# ---------- 2. 复制脚本 ----------
Say "[2/6] 复制脚本" 'White'
$srcScripts = Join-Path $PSScriptRoot '.'
Get-ChildItem -LiteralPath $srcScripts -Filter '*.ps1' | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $InstallDir -Force
    Ok $_.Name
}
foreach ($sub in @('reports')) {
    $d = Join-Path $InstallDir $sub
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---------- 3. 备份当前配置 ----------
Say "[3/6] 备份当前 Codex 配置" 'White'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $InstallDir "backup-$stamp"
if (Test-Path -LiteralPath $CodexHome) {
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    $n = 0
    foreach ($f in @('config.toml', '.env', 'cap_sid', 'AGENTS.md')) {
        $src = Join-Path $CodexHome $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $backup -Force
            $n++
        }
    }
    Ok "已备份 $n 个文件到 backup-$stamp"
} else {
    Warn "没找到配置目录 $CodexHome（Codex 可能还没运行过）"
}

# ---------- 4. 注册计划任务 ----------
Say "[4/6] 注册计划任务" 'White'
if ($NoTask) {
    Warn '已跳过（-NoTask）'
} else {
    $taskName = 'CodexHealthCheck'
    $health = Join-Path $InstallDir 'codex-health.ps1'
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$health`" -Fix -StartProxy -Quiet"
        $t1 = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $t1.Delay = 'PT3M'   # 开机 3 分钟后再查，避免代理还没起来就误报
        $t2 = New-ScheduledTaskTrigger -Daily -At '12:30'
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($t1, $t2) `
            -Settings $settings -Principal $principal -Force `
            -Description 'ChatGPT/Codex 健康自检：登录后 3 分钟 + 每天 12:30；代理未开时自动拉起' | Out-Null
        Ok "已注册计划任务 $taskName（登录后 3 分钟 + 每天 12:30）"
    } catch {
        Warn "注册计划任务失败: $($_.Exception.Message)"
        Warn '可以稍后用管理员权限重新运行本脚本'
    }
}

# ---------- 5. 桌面快捷方式 ----------
Say "[5/6] 创建桌面快捷方式" 'White'
if ($NoShortcut) {
    Warn '已跳过（-NoShortcut）'
} else {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path $desktop '一键修复网络.lnk'
        $health = Join-Path $InstallDir 'codex-health.ps1'
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $sc.Arguments        = "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$health`" -Fix -StartProxy"
        $sc.WorkingDirectory = $InstallDir
        $sc.IconLocation     = 'shell32.dll,21'
        $sc.Description      = '检查并修复 ChatGPT/Codex 联网（代理没开会自动打开）'
        $sc.Save()
        Ok "已创建: $lnk"
    } catch {
        Warn "创建快捷方式失败: $($_.Exception.Message)"
    }
}

# ---------- 6. 首次自检 ----------
Say "[6/6] 首次自检" 'White'
Say ''
$health = Join-Path $InstallDir 'codex-health.ps1'
if (Test-Path -LiteralPath $health) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $health -Fix -StartProxy
} else {
    Warn '找不到 codex-health.ps1'
}

Say ''
Say '=====================================================' 'Cyan'
Say '  安装完成' 'Cyan'
Say '=====================================================' 'Cyan'
Say ''
Say "  工具目录 : $InstallDir"
Say "  报告     : $InstallDir\reports\latest.txt"
Say "  一键入口 : 桌面「一键修复网络」"
Say ''
Say '  以后出问题：双击桌面「一键修复网络」，看结论行。' 'Yellow'
Say '  HEALTHY = 机器侧正常（问题在代理节点或服务端）' 'Yellow'
Say '  PROBLEM = 按提示处理' 'Yellow'
Say ''
