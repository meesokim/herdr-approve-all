@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0approve-windows.ps1" %*
exit /b %ERRORLEVEL%
