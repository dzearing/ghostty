# T48 — deadlock dump analysis (root cause CONFIRMED)

Analysis of `.dumps/ghoztty-9056-deadlock-20260714-183552.dmp` (744 MB full
minidump; installed exe of 2026-07-14, reproducible-build hash `D07EA2BA`,
stripped so no matching pdb). Debugged 2026-07-15 with the store WinDbg's
`cdb.exe` + Microsoft public symbols — system frames (ntdll/win32u/user32/
imm32/msctf) resolve fully without the ghoztty pdb, which is all that was
needed.

Reproduce the debugger run:

```
# The watchdog wrote the dump elevated → owner-only DACL denies read even
# to the owner until re-granted (owner has implicit WRITE_DAC):
icacls <dump> /grant "$env:USERNAME:R"
# The store-packaged cdb runs in an app container that can't read D:\ or
# arbitrary paths; invoke the underlying exe (still packaged identity, so a
# user-profile path like the dump's own dir works once the DACL is fixed):
$cdb = "$env:LOCALAPPDATA\Microsoft\WindowsApps\Microsoft.WinDbg_8wekyb3d8bbwe\cdbX64.exe"
$env:_NT_SYMBOL_PATH = "srv*https://msdl.microsoft.com/download/symbols"
& $cdb -z <dump> -c "~*k; !locks; dps @rsp L200; q"
```

## Verdict: NOT a lock cycle. A re-entrant condition-variable hang.

- `!analyze -hang` → `APPLICATION_HANG`, FAULTING/BLOCKING thread = the GUI
  thread (0), `DERIVED_WAIT_CHAIN` lists only thread 0 with wait type
  `(null)` — the OS could not find a synchronizable object it owns/awaits.
- `!locks` → "Scanned 15 critical sections", **none owned**. No CRITICAL_SECTION
  deadlock.
- `~*k` → every other thread is in a clean idle wait: renderer/io threads in
  `GetQueuedCompletionStatusEx` (IOCP), io-reader threads in `ReadFile` (PTY),
  NVIDIA driver worker/present threads in `WaitForSingleObject`/
  `NtUserMsgWaitForMultipleObjectsEx`, one threadpool worker idle. Nobody is
  blocked on anybody. **There is no EventPairLow anywhere** (the earlier
  T48 note's "EventPairLow ×2" was WER bucket noise, not the real stacks).

So the hang is a single stuck thread — the GUI thread — asleep on a Win32
condition variable with no one able to wake it. Same *family* as T40 (lost
wakeup), different mechanism.

## The GUI thread (thread 0) — reconstructed call chain

`~0s; dps @rsp L200` walks the raw stack; return addresses into system DLLs
resolve even though ghoztty is stripped. Reading oldest→newest:

```
user32!DefWindowProcW / RealDefWindowProcWorker / uxtheme!_ThemeDefWindowProc
  ← our WindowProc                         ghoztty+0x15bbc0   (surface wndproc)
  ← [NVIDIA WH_CALLWNDPROC hook: user32!DispatchHookA → nvoglv64!DrvValidateVersion]
  ← our WindowProc calls SetFocus          ghoztty+0x15bcce
      win32u!NtUserSetFocus                 ← *** the trigger ***
      user32!ImeSystemHandler
      user32!FocusSetIMCContext
      imm32!ImmSetActiveContext
      msctf!CtfImeSetActiveContext          ← CTF/TSF does a synchronous SendMessage
      user32!SendMessageW → SendMessageWorker → NtUserMessageCall
        (message on stack near this frame = 0x0281 = WM_IME_SETCONTEXT)
      ntdll!KiUserCallbackDispatcher / user32!apfnDispatch
  ← re-enters our code                     ghoztty+0x1ffa0e   *** blocked here ***
      KERNELBASE!SleepConditionVariableSRW(cv, srwlock, INFINITE, 0)
      ntdll!RtlSleepConditionVariableSRW
      ntdll!NtWaitForAlertByThreadId        ← waits forever
```

Disasm at the blocked site confirms the primitive:

```
ghoztty+0x1ff9e4  cmp  dword ptr [r14+4A20h], 40h      ; state gate
ghoztty+0x1ff9ec  jne  +skip                            ; only wait if state==0x40
ghoztty+0x1ff9ee  add  qword ptr [r14+4A10h], 1         ; waiter count++
ghoztty+0x1ff9f6  lea  rcx, [r14+4A08h]                 ; &CONDITION_VARIABLE
ghoztty+0x1ffa00  mov  r8d, 0FFFFFFFFh                  ; dwMilliseconds = INFINITE
ghoztty+0x1ffa06  xor  r9d, r9d                         ; flags = 0
ghoztty+0x1ffa09  call ghoztty+0xa9d8b0                 ; → SleepConditionVariableSRW
ghoztty+0x1ffa0e  ...                                   ; return addr in the dump
ghoztty+0x1ffa10  add  qword ptr [r14+4A10h], -1        ; waiter count--
```

That is exactly Zig's `std.Thread.Condition.wait` on Windows
(`lib/std/Thread/Condition.zig` `WindowsImpl` → `kernel32.SleepConditionVariableSRW`,
verified in 0.15.2). `r14` is a large owning struct (fields at +0x4A08 cv,
+0x4A10 waiter count, +0x4A20 a state compared to 0x40) — an unidentified
ghoztty subsystem carrying a `Condition`. Exact function needs a *matching*
symbolized dump (see NEXT); the installed exe/pdb were rebuilt 2026-07-15
05:33, after this dump, so they mis-match module `D07EA2BA` and must not be
loaded against it.

## Root cause

The Win32 GUI thread calls **`SetFocus` synchronously from inside its
WindowProc**. `SetFocus` runs the IME/CTF (`msctf`/`imm32`) activation
cascade inline — `ImeSystemHandler → CtfImeSetActiveContext` does a
synchronous `SendMessage` (WM_IME_SETCONTEXT) that **re-enters our WindowProc**.
On that nested, non-pumping WndProc stack, ghoztty performs a
`std.Thread.Condition.wait()` (INFINITE). Whatever cross-thread signal that
wait depends on can never be observed, because the GUI thread is buried in
message dispatch and has stopped pumping — so it sleeps forever. Window stops
repainting, `Responding=false`, the on-GUI-thread IPC listener stops
accepting → clients see pipe-busy. All downstream of the one stuck thread.

This is the identical re-entrancy class documented at
`src/apprt/win32/App.zig:2465` (the WM_GETOBJECT/oleacc AccWrap hang, whose
comment literally predicts "SleepConditionVariableSRW forever — the ghost-hang
dumps all bottom out exactly there"). That fix — `return 0` for
`OBJID_CLIENT` — was already present in the dump's build (added
`e0118f682`, 2026-07-05; confirmed ancestor of the dump build `2bb4c802d`).
It closed only the **oleacc** trigger. **This dump reaches the same hang
through the IME/CTF `SetFocus` path, which that guard does not cover.**

### Refuted prior candidates (from the old T48 note)

1. *GUI-thread reentrant win32k callback self-block (EventPairLow).* Partly
   right in spirit (it IS a re-entrant WndProc self-block) but **no
   EventPairLow exists in the dump**; the wait is a condition variable, and
   the trigger is IME/CTF via SetFocus, not oleacc.
2. *GUI blocks on `renderer_state.mutex` while the PTY reader holds it.*
   Refuted: `!locks` shows no owned critical section, and the io-reader
   threads are idle in `ReadFile`, not holding anything.
3. *Unsynchronized CS_OWNDC HDC contention.* Refuted: not in the chain.

## Fix direction (for the implementation task)

Break the re-entrancy at the point WE introduce it — do not call `SetFocus`
synchronously from within WindowProc message handling:

- **Primary:** defer focus changes. From a WndProc, `PostMessageW(hwnd,
  WM_APP_SETFOCUS, …)` and call the real `SetFocus` when that posted message
  is dispatched at the top of the message loop — outside any nested
  SendMessage/hook/CTF callback — so the IME/CTF cascade runs where the
  thread can pump. Candidate call sites inside WindowProc:
  `App.zig:2537/2546/2555/2566` (and the focus-on-click paths in
  `Surface.zig`, `Window.zig`).
- **Deeper (belt-and-suspenders):** the GUI thread should never
  `Condition.wait()` while inside message dispatch. Once a *matching*
  symbolized dump identifies the `ghoztty+0x1ffa0e` subsystem, make that wait
  non-blocking on the GUI thread (or pump via `MsgWaitForMultipleObjectsEx`
  instead of an infinite `SleepConditionVariableSRW`).
- Consider suppressing the CTF re-entrancy for our surface windows
  (evaluate `ImmDisableTextFrameService`/per-window CTF opt-out) — but only
  if it doesn't regress IME input; the deferral fix is lower-risk.

## NEXT (implementation task)

The watchdog build is now `-Dstrip=false` with a pdb, so the *next* hang
dump will be symbolizable against its own module. Repro under the symbolized
build, resolve `ghoztty+0x1ffa0e` to confirm the exact wait site, implement
the deferral fix, and validate (a stress harness that focuses panes under
heavy TUI output; watchdog stays green for a long soak with no AppHang).
