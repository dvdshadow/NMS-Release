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
set "PS1TMP=%TEMP%\nms-install-20260903-6.ps1"
set "PS1URL=https://raw.githubusercontent.com/dvdshadow/NMS-Release/568de5128f113ce665967dd468b002c51f2543d3/install/windows/install.ps1"

echo  Downloading installer script...
if exist "%SystemRoot%\System32\curl.exe" (
    "%SystemRoot%\System32\curl.exe" -L --fail --silent --show-error -H "Cache-Control: no-cache" -o "%PS1TMP%" "%PS1URL%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('%PS1URL%', '%PS1TMP%')"
)

if not exist "%PS1TMP%" (
    echo  ERROR: download failed.
    pause
    exit /b 1
)

findstr /C:"InstallerRevision 20260903-6" "%PS1TMP%" >nul
if errorlevel 1 (
    echo  ERROR: downloaded file is not revision 20260903-6.
    echo  First lines of what was downloaded:
    more /E +0 "%PS1TMP%"
    pause
    exit /b 1
)

findstr /C:"CmdletBinding" "%PS1TMP%" >nul
if not errorlevel 1 (
    echo  ERROR: downloaded file still contains CmdletBinding. Refusing to run it.
    pause
    exit /b 1
)

copy /Y "%PS1TMP%" "%PS1%" >nul
echo  Using installer revision 20260903-6
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
