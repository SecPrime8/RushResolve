@echo off
REM Run Fix-Teams-MultiUser_Offline_v2.ps1 as Administrator
set "SCRIPT=%~dp0Fix-Teams-MultiUser_Offline_v2.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
pause
