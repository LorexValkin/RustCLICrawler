@echo off
powershell.exe -NoLogo -NoProfile -NonInteractive -File "%~dp0scripts\Start-Dashboard.ps1"
if errorlevel 1 (
  echo Dashboard could not start. Check .dashboard\stderr.log.
  pause
  exit /b 1
)
start "" "http://localhost:8765"
