@echo off
setlocal EnableExtensions
REM =============================================================================
REM  NMS Server — Windows one-click installer
REM
REM  Double-click this file after downloading/cloning the repo.
REM  It will ask for Administrator permission (UAC), then walk you through
REM  the install. You do not need to open PowerShell yourself.
REM =============================================================================

cd /d "%~dp0"

REM Re-launch elevated if we are not already admin.
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo.
    echo  NMS Server Installer
    echo  --------------------
    echo  Administrator permission is required to install MariaDB / Perl
    echo  and configure the server. Windows will show a UAC prompt next.
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM Keep a readable console and run the real installer.
title NMS Server Installer
color 0B
echo.
echo  ============================================================
echo   NMS Server Installer
echo  ============================================================
echo   You can accept the defaults by pressing Enter at each prompt.
echo   This will compile the server, import the database, download
echo   maps + Spire, and create a runnable folder under your user
echo   profile (default: %%USERPROFILE%%\nms-server).
echo  ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install\windows\install.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

echo.
if "%EXITCODE%"=="0" (
    echo  Installer finished.
) else (
    echo  Installer exited with code %EXITCODE%.
    echo  If something failed, scroll up for the error message.
)
echo.
pause
exit /b %EXITCODE%
