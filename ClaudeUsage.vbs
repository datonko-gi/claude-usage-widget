Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
selfPath = fso.GetParentFolderName(WScript.ScriptFullName)
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & selfPath & "\claude_usage.ps1""", 0, False
