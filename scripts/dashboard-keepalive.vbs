' Windowless launcher for the task-dashboard keep-alive (user report 2026-08-30).
'
' The keep-alive task fires every 5 minutes. Registered the obvious way, its
' action is powershell.exe under LogonType=Interactive, so the Task Scheduler
' creates that process ON THE USER'S DESKTOP: a console window flashes up and
' TAKES FOCUS, every tick, all day. `-WindowStyle Hidden` cannot prevent it -
' powershell reads that flag only after its console already exists, so it hides
' a window the user has already been interrupted by.
'
' The fixes that do not work here:
'   - S4U (`schtasks /RU <user> /NP`) would run it off-desktop, but registering
'     it needs the "log on as a batch job" right and returns "Access is denied"
'     unelevated on this box.
'   - `conhost.exe --headless powershell.exe ...` did not run the command at
'     all when probed (no output file, no exit code).
'
' wscript.exe is a GUI-subsystem binary: it is given no console to begin with,
' and Run's intWindowStyle 0 keeps the child from creating one. Nothing flashes,
' nothing takes focus, and no elevation is involved.
'
' Deliberately argument-free. schtasks /TR takes the whole command as ONE
' argument with its inner quotes backslash-escaped, and anything else silently
' loses everything after the first space (the trap T440 documents). A launcher
' that needs no arguments cannot fall into it.
Option Explicit
Dim shell, repo, cmd
Set shell = CreateObject("WScript.Shell")
repo = "D:\git\ghoztty"
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & repo & _
      "\scripts\task-dashboard.ps1"" -Port 7788 -NoPane"
' 0 = hidden window, False = do not wait. The task is a tick, not a session:
' it should return immediately and let the launched check run on its own.
shell.Run cmd, 0, False
