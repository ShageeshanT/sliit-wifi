@echo off
REM ===========================================================
REM  SLIIT Wi-Fi - click-to-login
REM  Runs the login flow visibly, shows the log, pauses at end.
REM ===========================================================

setlocal
cd /d "%~dp0"

title SLIIT Wi-Fi Login

echo ============================================
echo   SLIIT Wi-Fi Login
echo ============================================
echo.
echo Running login script...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0login.ps1"
set EXIT_CODE=%ERRORLEVEL%

echo.
echo --- login.log (last 20 lines) ---
powershell -NoProfile -Command "if (Test-Path '%~dp0login.log') { Get-Content '%~dp0login.log' -Tail 20 } else { 'No log file.' }"
echo ----------------------------------

echo.
if "%EXIT_CODE%"=="0" (
    echo [ OK ] Success. You should have internet now.
) else if "%EXIT_CODE%"=="2" (
    echo [FAIL] Portal rejected credentials. Run setup.cmd to fix password.
) else if "%EXIT_CODE%"=="3" (
    echo [FAIL] Couldn't find SLIIT portal. Are you actually on SLIIT-STD?
) else (
    echo [FAIL] Exit code %EXIT_CODE%. See log above.
)
echo.
echo Press any key to close this window...
pause >nul
endlocal
