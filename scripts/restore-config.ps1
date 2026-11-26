<#
.SYNOPSIS
    从备份恢复 Codex 配置（出问题时的回滚工具）

.DESCRIPTION
    列出所有备份（每日快照 + 手动备份），把 config.toml / .env / cap_sid 恢复回去。
    覆盖前会把当前文件另存为 *.broken-时间戳，不会丢失现场。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File restore-config.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File restore-config.ps1 -BackupName backup-20261126-163503
#>
[CmdletBinding()]
param(
    [string]$BackupName,
    [string[]]$Files = @('config.toml', '.env', 'cap_sid')
)

$ErrorActionPreference = 'Stop'
$ToolkitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome  = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }

# 候选备份：每日快照优先，其次手动备份
$candidates = @()
$snapRoot = Join-Path $ToolkitDir 'snapshots'
if (Test-Path -LiteralPath $snapRoot) {
    $candidates += Get-ChildItem -LiteralPath $snapRoot -Directory -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending
}
$candidates += Get-ChildItem -LiteralPath $ToolkitDir -Directory -Filter 'backup-*' -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending

if ($candidates.Count -eq 0) {
    Write-Host '没有找到任何备份。' -ForegroundColor Red
    Write-Host '先运行一次 setup.ps1 或 codex-health.ps1 -Fix 来生成备份。' -ForegroundColor DarkGray
    exit 1
}

if (-not $BackupName) {
    Write-Host '可用备份：' -ForegroundColor Cyan
    $i = 1
    foreach ($b in $candidates) {
        $cnt = (Get-ChildItem -LiteralPath $b.FullName -File -ErrorAction SilentlyContinue).Count
        Write-Host ("  [{0}] {1}  （{2} 个文件）" -f $i, $b.Name, $cnt)
        $i++
    }
    $pick = Read-Host '输入编号选择要恢复的备份（直接回车=最新）'
    if ([string]::IsNullOrWhiteSpace($pick)) {
        $target = $candidates[0]
    } else {
        $idx = 0
        if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $candidates.Count) {
            Write-Host '编号无效。' -ForegroundColor Red
            exit 1
        }
        $target = $candidates[$idx - 1]
    }
} else {
    $target = $candidates | Where-Object { $_.Name -eq $BackupName } | Select-Object -First 1
    if (-not $target) {
        Write-Host "找不到备份: $BackupName" -ForegroundColor Red
        exit 1
    }
}

Write-Host "使用备份: $($target.FullName)" -ForegroundColor Cyan
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'

foreach ($f in $Files) {
    $src = Join-Path $target.FullName $f
    $dst = Join-Path $CodexHome $f
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host "  跳过（备份中无此文件）: $f" -ForegroundColor DarkGray
        continue
    }
    if (-not (Test-Path -LiteralPath $CodexHome)) {
        New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
    }
    if (Test-Path -LiteralPath $dst) {
        $keep = "$dst.broken-$ts"
        Copy-Item -LiteralPath $dst -Destination $keep -Force
        Write-Host "  已保留当前文件: $(Split-Path $keep -Leaf)" -ForegroundColor DarkGray
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host "  已恢复: $f" -ForegroundColor Green
}

Write-Host ''
Write-Host '恢复完成。请完全退出并重新打开 ChatGPT 桌面端使配置生效。' -ForegroundColor Green
