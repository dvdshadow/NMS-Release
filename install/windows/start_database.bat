@echo off
setlocal EnableExtensions
REM Start MariaDB/MySQL before Spire or the game server.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_database.ps1"
exit /b %ERRORLEVEL%
