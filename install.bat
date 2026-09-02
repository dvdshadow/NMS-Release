@echo off
setlocal
REM Convenience wrapper — run from the repository root.
REM Prefer an elevated PowerShell / "Run as administrator" for first-time installs
REM so MariaDB and Perl can be installed via winget.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install\windows\install.ps1" %*
if errorlevel 1 pause
