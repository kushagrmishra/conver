@echo off
setlocal enabledelayedexpansion

echo ==> Building Conver for Windows (.exe Installer & Portable)...
cd /d "%~dp0conver"

call npm install
if errorlevel 1 (
    echo [ERROR] npm install failed. Please ensure Node.js 20+ is installed.
    exit /b 1
)

call npm run dist:win
if errorlevel 1 (
    echo [ERROR] Electron build failed.
    exit /b 1
)

echo ==> Done! Windows binaries are ready in conver\dist\
endlocal
