@echo off
setlocal
set "LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ClaudeUsage.lnk"
if exist "%LNK%" del "%LNK%"
taskkill /f /im powershell.exe /fi "WINDOWTITLE eq ClaudeUsage" >nul 2>&1
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*claude_usage.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
echo Removed ClaudeUsage from startup and stopped it.
