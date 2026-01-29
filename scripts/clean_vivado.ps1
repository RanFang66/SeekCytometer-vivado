# ==========================================
# Vivado 工程清理脚本 (PowerShell)
# 用于 Git 提交前清理生成文件
# 脚本位置: scripts\clean_vivado.ps1
# ==========================================

param(
    [switch]$Force,        # 跳过确认
    [switch]$DryRun        # 只显示将要删除的内容，不实际删除
)

$ErrorActionPreference = "Stop"

# 获取脚本所在目录，然后定位到工程根目录
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# 工程目录名称
$ProjectName = "seek_cytometer"
$ProjectPath = Join-Path $ProjectRoot $ProjectName

# 定义要删除的目录
$DirsToDelete = @(
    "$ProjectName.cache",
    "$ProjectName.gen",
    "$ProjectName.hw",
    "$ProjectName.runs",
    "$ProjectName.sim",
    "$ProjectName.tmp",
    "$ProjectName.ip_user_files",
    ".Xil"
)

# 定义要删除的文件模式
$FilePatternsToDelete = @(
    "*.log",
    "*.jou", 
    "*.str",
    "*.backup.*",
    "*.wdb",
    "*.wcfg"
)

# 定义主目录下要删除的二进制文件
$BinaryFilesToDelete = @(
    "*.bit",
    "*.ltx",
    "*.xsa",
    "*.dcp",
    "ip_upgrade.log"
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Vivado 工程清理脚本 (PowerShell)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "脚本位置: $ScriptDir"
Write-Host "工程根目录: $ProjectRoot"
Write-Host "工程目录: $ProjectPath"

# 检查工程目录
if (-not (Test-Path $ProjectPath)) {
    Write-Host "[错误] 未找到 $ProjectPath 目录" -ForegroundColor Red
    exit 1
}

# 计算清理前大小
Write-Host ""
Write-Host "清理前空间占用:" -ForegroundColor Yellow
$SizeBefore = (Get-ChildItem -Path $ProjectPath -Recurse -ErrorAction SilentlyContinue | 
               Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host ("  {0:N2} MB" -f $SizeBefore)

# 统计将要删除的内容
Write-Host ""
Write-Host "将要删除的内容:" -ForegroundColor Yellow

$TotalSize = 0
$ItemsToDelete = @()

# 检查目录
foreach ($dir in $DirsToDelete) {
    $fullPath = Join-Path $ProjectPath $dir
    if (Test-Path $fullPath) {
        $size = (Get-ChildItem -Path $fullPath -Recurse -ErrorAction SilentlyContinue | 
                 Measure-Object -Property Length -Sum).Sum / 1MB
        Write-Host ("  [目录] {0} ({1:N2} MB)" -f $dir, $size) -ForegroundColor Gray
        $TotalSize += $size
        $ItemsToDelete += $fullPath
    }
}

# 检查日志文件
$logFiles = Get-ChildItem -Path $ProjectPath -Recurse -Include $FilePatternsToDelete -ErrorAction SilentlyContinue
if ($logFiles) {
    $logSize = ($logFiles | Measure-Object -Property Length -Sum).Sum / 1MB
    Write-Host ("  [文件] 日志等文件 ({0} 个, {1:N2} MB)" -f $logFiles.Count, $logSize) -ForegroundColor Gray
    $TotalSize += $logSize
}

# 检查二进制文件
$binFiles = Get-ChildItem -Path $ProjectPath -Include $BinaryFilesToDelete -ErrorAction SilentlyContinue
if ($binFiles) {
    $binSize = ($binFiles | Measure-Object -Property Length -Sum).Sum / 1MB
    Write-Host ("  [文件] 二进制产物 ({0} 个, {1:N2} MB)" -f $binFiles.Count, $binSize) -ForegroundColor Gray
    $TotalSize += $binSize
}

Write-Host ""
Write-Host ("预计释放空间: {0:N2} MB" -f $TotalSize) -ForegroundColor Green

if ($DryRun) {
    Write-Host ""
    Write-Host "[DryRun 模式] 以上内容不会被实际删除" -ForegroundColor Magenta
    exit 0
}

# 确认删除
if (-not $Force) {
    Write-Host ""
    $confirm = Read-Host "确认删除这些文件? (y/n)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Host "已取消" -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""
Write-Host "开始清理..." -ForegroundColor Green

# 删除目录
$step = 1
$totalSteps = $DirsToDelete.Count + 2

foreach ($dir in $DirsToDelete) {
    $fullPath = Join-Path $ProjectPath $dir
    Write-Host "[$step/$totalSteps] 删除 $dir..."
    if (Test-Path $fullPath) {
        Remove-Item -Path $fullPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    $step++
}

# 删除日志文件
Write-Host "[$step/$totalSteps] 删除日志文件..."
Get-ChildItem -Path $ProjectPath -Recurse -Include $FilePatternsToDelete -ErrorAction SilentlyContinue | 
    Remove-Item -Force -ErrorAction SilentlyContinue
$step++

# 删除二进制产物
Write-Host "[$step/$totalSteps] 删除二进制产物..."
Get-ChildItem -Path $ProjectPath -Include $BinaryFilesToDelete -ErrorAction SilentlyContinue | 
    Remove-Item -Force -ErrorAction SilentlyContinue

# 计算清理后大小
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "清理完成!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

$SizeAfter = (Get-ChildItem -Path $ProjectPath -Recurse -ErrorAction SilentlyContinue | 
              Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host ""
Write-Host "清理后空间占用:" -ForegroundColor Yellow
Write-Host ("  {0:N2} MB (释放了 {1:N2} MB)" -f $SizeAfter, ($SizeBefore - $SizeAfter))

Write-Host ""
Write-Host "现在可以进行 Git 提交了:" -ForegroundColor Cyan
Write-Host "  cd $ProjectRoot"
Write-Host "  git add -A"
Write-Host '  git commit -m "your message"'