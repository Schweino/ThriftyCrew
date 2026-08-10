' Console-free launcher for run-pc-capture-client.ps1. The capture client task
' must stay in the interactive session (real-Chrome captures), and a scheduled
' powershell.exe action in that session flashes a visible console every cycle;
' wscript.exe has no console, and window style 0 keeps PowerShell's hidden.
Dim shell, scriptDir, runner, args, i, exitCode
Set shell = CreateObject("WScript.Shell")
scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
runner = scriptDir & "run-pc-capture-client.ps1"
args = ""
For i = 0 To WScript.Arguments.Count - 1
  args = args & " " & Chr(34) & WScript.Arguments(i) & Chr(34)
Next
exitCode = shell.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & runner & Chr(34) & args, 0, True)
WScript.Quit exitCode
