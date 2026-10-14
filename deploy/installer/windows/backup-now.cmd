@echo off
rem Back up Serk Finance (runs as administrator; the data folder is protected).
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
echo Backing up Serk Finance...
"%~dp0serk-server.exe" backup --data "%ProgramData%\SerkFinance"
echo.
echo Copy the backup file to a USB drive or another computer and keep it safe.
pause
