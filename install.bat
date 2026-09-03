@echo off
setlocal EnableExtensions
REM NMS Server - Windows one-click installer
REM Double-click this file after downloading/cloning the repo.

cd /d "%~dp0"

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

REM Refresh the PowerShell installer from GitHub with curl so Windows
REM does not re-encode the file as UTF-16 (that breaks parsing).
set "PS1=%~dp0install\windows\install.ps1"
set "PS1URL=https://raw.githubusercontent.com/dvdshadow/NMS-Release/cursor/fix-windows-ps1-parse-25b8/install/windows/install.ps1"
if exist "%SystemRoot%\System32\curl.exe" (
    echo  Downloading latest install.ps1 ...
    "%SystemRoot%\System32\curl.exe" -L --fail --silent --show-error -o "%PS1%" "%PS1URL%"
    if errorlevel 1 (
        echo  WARNING: could not refresh install.ps1, using the local copy.
    )
)

echo  Starting installer...
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
