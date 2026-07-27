' run-hidden.vbs <ps1-path> - runs a PowerShell -File script with NO visible window, waits for it to
' finish, and returns its exit code to the caller. Used by scheduled tasks (SMP Bakers Daily Scan) so the
' daily 6am run does not pop a console window on the desktop. wscript.exe + Run(...,0,True) is windowless
' AND runs as the interactive user, so git credentials / network / Kroger+Ghost tokens all work exactly as
' when the task ran visibly. WScript.Quit propagates the script's exit code so the task's LastTaskResult
' (which health-heartbeat.ps1 checks) still reflects the real outcome.
Dim sh, rc, cmd
Set sh = CreateObject("Wscript.Shell")
cmd = "powershell -ExecutionPolicy Bypass -File """ & WScript.Arguments(0) & """"
rc = sh.Run(cmd, 0, True)
WScript.Quit(rc)
