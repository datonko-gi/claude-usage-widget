@echo off
setlocal
set "HERE=%~dp0"
set "LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ClaudeUsage.lnk"
rem Double any apostrophe so a folder like O'Brien survives the single-quoted PowerShell strings below.
set "HERE_PS=%HERE:'=''%"
set "LNK_PS=%LNK:'=''%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = New-Object -ComObject WScript.Shell; $l = $s.CreateShortcut('%LNK_PS%'); $l.TargetPath = '%HERE_PS%ClaudeUsage.vbs'; $l.WorkingDirectory = '%HERE_PS%'; $l.Save()"
start "" "%HERE%ClaudeUsage.vbs"
echo Installed ClaudeUsage to startup and launched it.
