@echo off
REM ==========================================
REM Vivado 工程清理脚本 (Windows)
REM 工程现在整体生成在 build\（一次性产物），清理即删除 build\。
REM 脚本位置: scripts\clean_vivado.bat
REM ==========================================

setlocal
set SCRIPT_DIR=%~dp0
cd /d "%SCRIPT_DIR%.."
set PROJECT_ROOT=%cd%
set BUILD_DIR=%PROJECT_ROOT%\build

echo ==========================================
echo Vivado 工程清理脚本
echo ==========================================
echo 工程根目录: %PROJECT_ROOT%
echo 构建目录:   %BUILD_DIR%

if not exist "%BUILD_DIR%" (
    echo build\ 不存在，无需清理。
    pause
    exit /b 0
)

echo.
echo 将要删除整个 build\ 目录（可由 scripts\build.tcl 重新生成）
set /p CONFIRM="确认删除? (y/n): "
if /i not "%CONFIRM%"=="y" (
    echo 已取消
    pause
    exit /b 0
)

echo [开始清理...]
rd /s /q "%BUILD_DIR%"

REM 顺带清理根目录下 Vivado 偶尔遗留的日志
del /q "%PROJECT_ROOT%\*.log" 2>nul
del /q "%PROJECT_ROOT%\*.jou" 2>nul
del /q "%PROJECT_ROOT%\*.str" 2>nul

echo.
echo 清理完成! 用 "source scripts/build.tcl" 可随时重建工程。
pause
