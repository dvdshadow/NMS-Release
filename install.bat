@echo off
setlocal EnableExtensions
REM NMS Server - Windows one-click installer

cd /d "%~dp0"
set "NMS_REPO_ROOT=%cd%"

net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo.
    echo  NMS Server Installer
    echo  Administrator permission is required. Windows will show a UAC prompt.
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

title NMS Server Installer
color 0B
echo.
echo  ============================================================
echo   NMS Server Installer
echo  ============================================================
echo.

set "PS1=%~dp0install\windows\install.ps1"
if not exist "%PS1%" (
    echo  ERROR: missing %PS1%
    echo  Run this from a full clone or unzip of the NMS-Release repository.
    pause
    exit /b 1
)

findstr /C:"CmdletBinding" "%PS1%" >nul
if not errorlevel 1 (
    echo  ERROR: install.ps1 contains CmdletBinding and will not run on Windows PowerShell 5.1.
    pause
    exit /b 1
)

echo  Using local installer script:
echo  %PS1%
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
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
