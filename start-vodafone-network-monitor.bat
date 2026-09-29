@echo off
setlocal
where pythonw.exe >nul 2>nul
if not errorlevel 1 (
    start "" pythonw.exe "%~dp0vodafone-network-monitor.py"
    exit /b 0
)
python "%~dp0vodafone-network-monitor.py"
