@echo off
REM SLIIT Wi-Fi Auto-Login - one-time setup
REM Opens a GUI window where you enter your SLIIT credentials and (optionally)
REM install the auto-login scheduled task. No admin rights required.

setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0login.ps1" -Setup

REM Exit code is informational; the GUI shows status itself.
endlocal
