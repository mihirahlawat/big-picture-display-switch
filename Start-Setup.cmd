@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" %*
set "setup_exit=%errorlevel%"
echo.
if not "%setup_exit%"=="0" echo Setup failed with exit code %setup_exit%.
pause
exit /b %setup_exit%
