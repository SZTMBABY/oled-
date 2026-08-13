@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0OLED_BlackScreen.ps1"
if errorlevel 1 (
    echo.
    echo [ERROR] Script failed. Press any key to close...
    pause >nul
)
