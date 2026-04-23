@echo off
REM One-time setup for SLIIT Wi-Fi auto-login.
REM  1. Prompts for credentials and saves them DPAPI-encrypted.
REM  2. Registers a scheduled task (on logon + on network connect).
REM No admin rights required — everything runs as the current user.

setlocal
cd /d "%~dp0"

echo ============================================
echo  SLIIT Wi-Fi Auto-Login  -  one-time setup
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0login.ps1" -Setup
if errorlevel 1 (
    echo.
    echo Setup failed. See above.
    pause
    exit /b 1
)

echo.
echo Registering scheduled task...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0login.ps1" -Install
if errorlevel 1 (
    echo.
    echo Task registration failed. See above.
    pause
    exit /b 1
)

echo.
echo Done. You can close this window.
echo.
echo Useful commands:
echo   Test now:   powershell -File "%~dp0login.ps1"
echo   View log:   notepad "%~dp0login.log"
echo   Uninstall:  powershell -File "%~dp0login.ps1" -Uninstall
echo.
pause
endlocal
