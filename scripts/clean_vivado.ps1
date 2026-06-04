# ==========================================
# Vivado 工程清理脚本 (PowerShell)
# 工程现在整体生成在 build\（一次性产物），清理即删除 build\。
# 脚本位置: scripts\clean_vivado.ps1
# ==========================================

param(
    [switch]$Force,        # 跳过确认
    [switch]$DryRun        # 只显示将要删除的内容，不实际删除
)

$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$BuildDir    = Join-Path $ProjectRoot "build"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Vivado 工程清理脚本 (PowerShell)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "工程根目录: $ProjectRoot"
Write-Host "构建目录:   $BuildDir"

if (-not (Test-Path $BuildDir)) {
    Write-Host "build\ 不存在，无需清理。" -ForegroundColor Yellow
    exit 0
}

$SizeBefore = (Get-ChildItem -Path $BuildDir -Recurse -ErrorAction SilentlyContinue |
               Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host ""
Write-Host ("将要删除整个 build\ 目录 ({0:N2} MB)，可由 scripts\build.tcl 重新生成" -f $SizeBefore) -ForegroundColor Yellow

if ($DryRun) {
    Write-Host "[DryRun 模式] 不会实际删除" -ForegroundColor Magenta
    exit 0
}

if (-not $Force) {
    $confirm = Read-Host "确认删除? (y/n)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Host "已取消" -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "开始清理..." -ForegroundColor Green
Remove-Item -Path $BuildDir -Recurse -Force -ErrorAction SilentlyContinue

# 顺带清理根目录下 Vivado 偶尔遗留的日志
Get-ChildItem -Path $ProjectRoot -Include @("*.log","*.jou","*.str") -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "清理完成! 用 'source scripts/build.tcl' 可随时重建工程。" -ForegroundColor Green
