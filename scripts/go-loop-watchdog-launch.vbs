' Windowless launcher for the GhozttyGoLoopWatchdog task (T1192).
'
' Registered as powershell.exe under LogonType=Interactive, the task creates
' its process on the user's desktop. With Windows Terminal set as the Windows
' 11 default terminal application, that console allocation is handed to Windows
' Terminal, which draws a real window, TAKES FOCUS, and closes a fraction of a
' second later. `-WindowStyle Hidden` does not prevent it: powershell reads the
' flag only after its console already exists.
'
' This task is not the every-few-minutes offender the user reported on
' 2026-08-30 - that was a pair of tasks from another repo, caught red-handed by
' pairing a foreground-window probe with a process probe. The watchdog is a
' long-running process, so its 10-minute relaunch is refused (0x800710E0) while
' it is alive and normally creates nothing. It steals focus only when it
' genuinely restarts, which is precisely when nobody is watching for it.
'
' The launcher is argument-free so it can never hit the schtasks /TR quoting
' trap (T440), and wscript.exe is GUI-subsystem so it is given no console at
' all. The watchdog still runs in the interactive session and can still open
' Ghoztty windows when it re-enters the loop.
Option Explicit
Dim shell
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & _
          """D:\git\ghoztty\scripts\go-loop-watchdog.ps1"" -Repo ""D:\git\ghoztty""", 0, False
