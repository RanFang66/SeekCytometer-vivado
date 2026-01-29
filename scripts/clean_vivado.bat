@echo off
REM ==========================================
REM Vivado 工程清理脚本 (Windows)
REM 用于 Git 提交前清理生成文件
REM 脚本位置: scripts\clean_vivado.bat
REM ==========================================

setlocal enabledelayedexpansion

REM 获取脚本所在目录
set SCRIPT_DIR=%~dp0

REM 定位到工程根目录（scripts的上级目录）
cd /d "%SCRIPT_DIR%.."
set PROJECT_ROOT=%cd%

REM 工程目录名称
set PROJECT_NAME=seek_cytometer
set PROJECT_PATH=%PROJECT_ROOT%\%PROJECT_NAME%

echo ==========================================
echo Vivado 工程清理脚本
echo ==========================================
echo 脚本位置: %SCRIPT_DIR%
echo 工程根目录: %PROJECT_ROOT%
echo 工程目录: %PROJECT_PATH%

REM 检查工程目录是否存在
if not exist "%PROJECT_PATH%" (
    echo [错误] 未找到 %PROJECT_PATH% 目录
    pause
    exit /b 1
)

echo.
echo 将要删除的目录和文件:
echo   - %PROJECT_NAME%\%PROJECT_NAME%.cache\
echo   - %PROJECT_NAME%\%PROJECT_NAME%.gen\
echo   - %PROJECT_NAME%\%PROJECT_NAME%.hw\
echo   - %PROJECT_NAME%\%PROJECT_NAME%.runs\
echo   - %PROJECT_NAME%\%PROJECT_NAME%.sim\
echo   - %PROJECT_NAME%\%PROJECT_NAME%.tmp\
echo   - %PROJECT_NAME%\%PROJECT_NAME%.ip_user_files\
echo   - %PROJECT_NAME%\.Xil\
echo   - 日志文件 (*.log, *.jou)
echo   - 二进制产物 (*.bit, *.dcp, *.ltx, *.xsa)

echo.
set /p CONFIRM="确认删除这些文件? (y/n): "
if /i not "%CONFIRM%"=="y" (
    echo 已取消
    pause
    exit /b 0
)

echo.
echo [开始清理...]

REM 删除生成目录
echo [1/7] 删除 cache 目录...
if exist "%PROJECT_PATH%\%PROJECT_NAME%.cache" rd /s /q "%PROJECT_PATH%\%PROJECT_NAME%.cache"

echo [2/7] 删除 gen 目录...
if exist "%PROJECT_PATH%\%PROJECT_NAME%.gen" rd /s /q "%PROJECT_PATH%\%PROJECT_NAME%.gen"

echo [3/7] 删除 hw 目录...
if exist "%PROJECT_PATH%\%PROJECT_NAME%.hw" rd /s /q "%PROJECT_PATH%\%PROJECT_NAME%.hw"

echo [4/7] 删除 runs 目录...
if exist "%PROJECT_PATH%\%PROJECT_NAME%.runs" rd /s /q "%PROJECT_PATH%\%PROJECT_NAME%.runs"

echo [5/7] 删除 sim 目录...
if exist "%PROJECT_PATH%\%PROJECT_NAME%.sim" rd /s /q "%PROJECT_PATH%\%PROJECT_NAME%.sim"

echo [6/7] 删除 tmp 目录...
if exist "%PROJECT_PATH%\%PROJECT_NAME%.tmp" rd /s /q "%PROJECT_PATH%\%PROJECT_NAME%.tmp"

echo [7/7] 删除其他生成文件...
if exist "%PROJECT_PATH%\%PROJECT_NAME%.ip_user_files" rd /s /q "%PROJECT_PATH%\%PROJECT_NAME%.ip_user_files"
if exist "%PROJECT_PATH%\.Xil" rd /s /q "%PROJECT_PATH%\.Xil"

REM 删除日志文件
del /s /q "%PROJECT_PATH%\*.log" 2>nul
del /s /q "%PROJECT_PATH%\*.jou" 2>nul
del /s /q "%PROJECT_PATH%\*.str" 2>nul
del /s /q "%PROJECT_PATH%\*.backup.*" 2>nul

REM 删除主目录下的二进制产物
del /q "%PROJECT_PATH%\*.bit" 2>nul
del /q "%PROJECT_PATH%\*.ltx" 2>nul
del /q "%PROJECT_PATH%\*.xsa" 2>nul
del /q "%PROJECT_PATH%\ip_upgrade.log" 2>nul

echo.
echo ==========================================
echo 清理完成!
echo ==========================================
echo.
echo 现在可以进行 Git 提交了:
echo   cd %PROJECT_ROOT%
echo   git add -A
echo   git commit -m "your message"
echo.
pause