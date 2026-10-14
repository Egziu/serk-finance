@echo off
rem Set a new password for a Serk Finance user (runs as administrator).
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
set /p WS=Workspace (sign-in name): 
set /p EM=User email: 
"%~dp0serk-server.exe" reset-password --data "%ProgramData%\SerkFinance" --workspace "%WS%" --email "%EM%"
pause
