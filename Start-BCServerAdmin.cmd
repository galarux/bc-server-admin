@echo off
rem BC Server Admin launcher. Double-click to start; the script asks for elevation itself.
rem Extra arguments are passed through, e.g.:  Start-BCServerAdmin.cmd -Demo
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-BCServerAdmin.ps1" %*
if errorlevel 1 pause
