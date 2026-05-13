' launch-supervisor.vbs
'
' VBScript-Bootstrap fuer "nextWAVE Call Watcher" Scheduled Task.
' Startet watcher-supervisor.ps1 hidden, fire-and-forget.
'
' Hintergrund: PowerShell direkt als Task-Action mit -WindowStyle Hidden
' stirbt unter AtLogon-Trigger silently (Exit 0, kein Log). VBS via
' wscript.exe hat kein Window-Lifecycle-Problem im Task-Scheduler-Kontext
' und ist seit Windows XP der etablierte Hidden-Launcher-Workaround.
'
' Aufruf via Task-Action:
'   Execute  = wscript.exe
'   Argument = "C:\nextWAVE\nextwave-to-do-list\scripts\record\launch-supervisor.vbs"

Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\nextWAVE\nextwave-to-do-list\scripts\record\watcher-supervisor.ps1""", 0, False
