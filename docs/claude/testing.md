# Testing: lanes, acceptance scripts, harness rules

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load this before
> writing or running ANY test — unit lanes, `test/win32/` acceptance scripts,
> or scripts that drive the GUI. The audit rules in here (exit-code, skip,
> verdict, asserted-nothing, body-completion, one-shared-kill,
> foreground/desktop, persistence declaration, liveness, PS 5.1 argv fidelity)
> are enforced by sweeps that fail the suite.

### Test lanes and acceptance scripts

The floor for any change — all of these green, on the platform you changed:

```powershell
zig build test -Dapp-runtime=none      # pure logic, no app runtime
zig build test -Dapp-runtime=win32     # win32 apprt units (Windows)
zig build test-agent                   # ghoztty-agent, incl. real-pty tests
zig build -Dapp-runtime=none           # compiles lib ghostty (Windows canary)
```

`zig build test` with no `-Dapp-runtime` is the `none` lane on macOS and the
`win32` lane on Windows, so **name the lane explicitly** rather than assuming
the bare command covers both.

The fourth is a **build**, not a test, and it is a lane because nothing else on
Windows compiles the shared core into the msvc-target `lib ghostty` artifact
(T475). POSIX-only code can therefore land in `src/` with all three test lanes
green: `posix.pipe2`, `posix.kill`, an `fd >= 0` against a HANDLE and a `{d}`
over a pid all sat in `src/remote/ssh_transport.zig` for weeks, invisible
because the tests that reach them `SkipZigTest` on Windows — and a comptime-true
`return error.SkipZigTest` stops Zig analyzing the rest of the body, so the
test lane never even looked. Cached it costs about a second; it compiles only
when the shared core moved.

On Windows, run them through the watchdog rather than bare (T430):

```powershell
powershell -NoProfile -File scripts\floor-lane.ps1 -Lane all
```

It sets `ZIG_GLOBAL_CACHE_DIR` on the repo's drive inside the launched command,
logs unbuffered through `cmd.exe`, and — the reason it exists — **tells a slow
lane from a wedged one**: a lane that is computing burns CPU, a lane that is
blocked does not, so zero CPU delta across the process tree with no new output
is reported as `STALL` with a diagnostic (process tree, per-thread wait reasons,
WebView2 hosts, log tail) instead of hanging forever with nothing to read. Exit
0 pass / 1 fail / 2 wedged / 3 wall-clock cap; `-Lane <one>`, `-Repeat N`,
`-Filter <test-filter>`, `-SelfTest` to prove the detector itself.

**And a red lane says whether it is the code or the box** (T1170). A lane that
fails is re-run immediately, narrowed to the tests it blamed, and the summary
carries the answer: `agent#1=FAIL [alone: PASS alone - NOT reproduced ->
harness/timing, not the product]`. This is the T1137 rule applied to lanes
instead of to the acceptance suite, and it exists because a whole task went on
establishing by hand that three reds and one green differed only in how loaded
the box was. **The answer never changes the verdict** - red stays red and the
exit code stays non-zero; "passes alone" is a diagnosis, not a pass. The
narrowed re-run is cheap (measured: 414 s loaded, 36 s narrowed). It is skipped
when the log names no failing test (a build break or a crash), when more than
three tests failed (a lane-wide break, not one slow wait), when `-Filter` is
already narrowing the run, and under `-NoSoloConfirm`. Acceptance:
`test\win32\floor-lane-solo-confirm.ps1`.

A related bound worth knowing, on the other side of the same problem: the
`waitFor` helper the win32 viewer tests pump through measures **stillness, not
wall clock**. Its `timeout_s` is how long the pane may sit completely unchanged;
any observable change starts the count again, up to a hard ceiling of eight
times the bound. A wedged pane still fails as fast as it ever did, and a slow
box no longer fails a wait that two worker round trips were plainly still
satisfying. A timeout prints the whole observable pane state, so the next one is
diagnosable from the log rather than from a re-run.

**A red lane never ends on a bare exit code** (T444). `std.process.Child`
truncates a Windows exit code to a byte, so a *crashed* child reaches `zig build`
as `NTSTATUS & 0xFF` — `0xC0000005` (access violation) arrives as
`error code 5`, `0x80000003` (Zig's segfault handler aborting) as `code 3` —
which reads as a compile step failing for no reason at all.
`scripts/lib/CrashDiag.ps1` decodes it back and correlates it with the Windows
`Application Error` log, so a FAIL ends with a `-- crash diagnostics --` block
naming the process, exception, module and fault offset. The decode alone is only
a suspicion (a program really can `exit(5)`), so with no crash record behind it
the block says so rather than asserting. Acceptance:
`test\win32\crash-diagnostics.ps1`.

**And when the process that died was the COMPILER, the lane says so and retries**
(T451). `zig.exe` itself takes access violations on this box — eight in the 32
days to 2026-09-04, four of them at the same module-relative offset inside one
minute — and the lane then dies on exactly the bare `error code 5` above, which
reads as broken code. It is not a result: a `COMPILER CRASH` block names the
fault (and names a repeated fault site when it sees one, which is what separates
a compiler bug from a sick machine), the lane is re-run **once**, and the
re-run's verdict is final — the same budget and the same finality as the cache
heal. The rule that keeps it honest is the veto: a crash in one of OUR test
binaries in the same window is never relabelled a toolchain fault, because that
red is the T443 crash hunt's evidence. Classifier in
`scripts\lib\CompilerCrash.ps1`; acceptance:
`test\win32\floor-lane-compiler-crash.ps1`, whose end-to-end arm drives a real
access-violating process named `zig.exe` through the wrapper. The compiler on
this box is byte-identical to the official `zig-x86_64-windows-0.15.2` release,
so this is zig 0.15.2 (or the machine), not a corrupted install.

**And a red lane captures a real stack** (T450). Zig's segfault handler dies in
a recursive panic here, and even when it works it only ever walks the thread
that faulted — never the one that did the damage. So a crash in one of our test
binaries makes `floor-lane.ps1` re-run that binary under **cdb**, which takes
the exception on first chance and writes a full minidump plus `~*kv` for every
thread into `.dumps\`; the console gets a `-- crash stack --` block with source
lines and the name of the test that was running. It gets **one** attempt by
default, so a red lane costs ~10 extra minutes at worst; `-NoCatch` skips it and
`-CatchAttempts 2` buys better odds on a specific intermittent crash. Run it by
hand against an intermittent crash with

```powershell
powershell -NoProfile -File scripts\crash-catch.ps1 -Lane agent -Attempts 6
```

which runs the lane's built test binary directly (~20–110 s a go, no build).
`cdb` needs no install and no elevation on this box — the Store WinDbg package
ships a console `cdbX64.exe` under `%LOCALAPPDATA%\Microsoft\WindowsApps\`.
Library: `scripts/lib/CrashCatch.ps1`, which documents the three cdb traps
(backslashes eaten inside quoted commands, filters must be armed at the loader
break, cdb echoes its own command back). Acceptance:
`test\win32\crash-stacks.ps1`.

**But a re-run only ever describes a crash that agrees to happen twice** (T460).
The crash that tooling was built for lands on about half of runs, so the
occurrence that actually failed the lane is precisely the one it cannot see, and
an intermittent crash gets diagnosed by trying to provoke it again. Nothing
needed inventing: Windows was already keeping the evidence. WER's **LocalDumps**
is enabled machine-wide here, so a binary that dies leaves a minidump in
`%LOCALAPPDATA%\CrashDumps` **at the moment it dies** — unattended, on the FIRST
crash, at zero cost to a run that does not crash — and nothing read it. A red
lane now reads that dump first (`cdb -z`, about a second) and reaches the
~10-minute re-run only when there is none. By hand:
`crash-catch.ps1 -Last -Lane <lane>`, `-FromDump <path>` for a named dump, and
`-Status` for whether the box is armed at all.

Four things that look like details and are not:

- **A mini dump answers a stack question.** LocalDumps' default type carries
  every thread's stack, which is what the re-run was bought for; full memory
  needs a per-exe `DumpType=2` under **HKLM** and therefore elevation, so it is
  an upgrade and not a precondition. **HKCU is ignored outright** — measured: a
  `DumpFolder` set there was skipped and the dump still landed in the HKLM
  default folder.
- **The recorded exception is zig's handler aborting, not the fault.** The
  handler runs first and aborts, so the dump's exception is `0x80000003`; the
  frames that faulted are still on that same thread's stack *under*
  `handleSegfaultWindows`, with every other thread beside them. The block says
  so, rather than leaving a reader chasing a breakpoint that never existed.
- **Whether a dump is a crash is asked of the FILE, not of the debugger.** cdb
  reports `80000003 (Break instruction exception)` off the current context for a
  dump holding no exception at all — indistinguishable, in its output, from a
  real abort — so a T48 freeze-watchdog dump of a *healthy* process would read as
  a crash and manufacture a stack for a bug that never happened.
  `Test-MinidumpHasException` reads the stream directory for an ExceptionStream
  instead.
- **A dump older than the run that is asking is never returned.** A wrong stack
  costs more than no stack: it sends the next investigation somewhere the bug has
  never been.

Library: `scripts/lib/CrashDump.ps1`. Acceptance:
`test\win32\crash-first-chance.ps1`, whose lane arm drives the crasher through
`floor-lane.ps1 -Command` and requires both directions — the dump path when a
dump exists, and, under `GHOZTTY_CRASH_NO_WER=1` (a box with no capture,
reproduced from this same tree), the re-run fallback.

**A harness must never fabricate a failure, and one shape of that is now
checked** (T197). `Start-Process -PassThru` hands back a process object whose
`ExitCode` reads back **empty** unless something touched `$p.Handle` while the
child was still alive — so `if ($code -ne 0) { fail }` scores a *working* CLI as
broken. A fabricated failure costs more than a missed one: it sends the next
session hunting a defect that is not there, which it did twice (T145, then a
whole T147 turn spent on six red assertions against a build whose complete
`+list` output was sitting in the redirect file).

The trigger is now measured rather than remembered: it fires **only when
`Start-Process` is given `-RedirectStandardOutput` / `-RedirectStandardError`**
(0 of 8 reads survive, whether the handle is cached late or never; 8 of 8 with
it cached first, and 8 of 8 without any redirect). That is why it read as
flakiness — most helpers here redirect *inside* `cmd /c … > file`, which is
unaffected, and the two spellings sit line-for-line next to each other. So the
rule is mechanical and applies to every site:

```powershell
$p = Start-Process ... -PassThru
$null = $p.Handle          # FIRST, before any wait
if (-not $p.WaitForExit($ms)) { ... }
$p.WaitForExit()
return $p.ExitCode
```

Better still, **gate on the OUTPUT when the output is the answer** — parse the
JSON, look for the marker — rather than on a shell-plumbing detail. Exemptions
are `-Wait` (Start-Process holds the handle itself) and an explicit
`# exitcode-audit: <reason>` marker, the same state-your-intent convention the
`# persistence:` markers use. The analyzer is
`test\win32\lib\ExitCodeAudit.ps1`; acceptance (and the sweep that must stay at
zero across `test\win32\` **and** `scripts\`):
`test\win32\harness-exitcode-audit.ps1`.

**PowerShell 5.1 cannot put generated text on a native command line, so don't
let it try** (T279). Its command-line builder is not the inverse of the CRT
parser every C/C++/Zig program uses to split that line back into argv. Measured
with a `GetCommandLineW` oracle, its rule is: an argument is wrapped in `"` only
when whitespace appears at a position preceded by an **even** number of `"`
characters, and an embedded `"` is copied through **unescaped**. Both halves
corrupt silently, at exit 0 — the loop's own relaunch passed
`--command=claude --dangerously-skip-permissions --continue "read go.md and go"`
and ghoztty received `--command=claude … --continue read` plus `go.md`, `and`,
`go` as three stray positionals, so every relaunched session came up with no
loop prompt and nothing said so.

**No escaper fixes this**, and that is a proof rather than a failed attempt.
Escaping `"` as `\"` leaves the `"` character in place, so it still counts
toward PowerShell's parity while the CRT no longer treats it as structural: for
text whose first whitespace is preceded by an ODD number of quotes — `"a quoted
phrase" then more`, an entirely ordinary title or banner — PowerShell declines to
wrap, the CRT splits the argument at the spaces, and the structural open quote
that would fix it adds a second `"` and flips the parity straight back.

So build the command line yourself and hand it to `CreateProcess`:
`ConvertTo-NativeArgToken` / `Invoke-NativeExact` in `scripts\lib\NativeArgv.ps1`
(dot-sourced by `loop-session.ps1`, so the loop, the lock, the upgrade and the
watchdog all have it). That is total, and it fixes every flag of every verb at
once rather than one `--<field>-file=` at a time — which is why this did NOT
grow a `--title-file` / `--banner-file` pair: the defect is in our PowerShell
call sites, not in the product, and a CLI flag is a cross-platform obligation
(the T141 rule) bought to work around one shell. `+send-keys --keys-file=`
stays the transport for a PROMPT, whose bytes must skip key notation as well as
quoting and can exceed a command line's 32767-character cap.
`Invoke-NativeExact` also settles T663 for its callers: reaching CreateProcess
directly captures a GUI-subsystem `ghoztty.exe`'s stdout with no `2>&1` merge,
so a stderr line can no longer land inside a `+list --json` a script parses.
Acceptance: `test\win32\cli-argv-fidelity.ps1`, whose section D re-sends every
payload the old way and requires it to arrive CORRUPTED — a payload that was
never at risk proves nothing — alongside a safe payload that must survive both
ways.

**A section the suite SKIPPED is named in the line anybody reads** (T219).
Skipping is legitimate — pwsh is not installed, there is no network, a release
build compiled the debug oracle out. A skip the RESULT cannot see is not: it is
an un-run assertion wearing a green hat, and an assertion inside one can rot for
months. `ipc-version.ps1` asserted the About box was a `#32770` MessageBox long
after it became a native `GhozttyConfirmDialog`, and every run still printed
`ALL PASS` because the foreground grab kept losing and the whole palette section
took its SKIP branch (T217 found it by making the chord land). Since the loop
reads exactly ONE line (`| Select-Object -Last 1`), a `(2 section(s) SKIPPED)`
line printed *above* the verdict is invisible to the only reader there is — five
scripts printed one there. So the count goes in the verdict itself:

```powershell
Write-Host 'SKIP  pwsh: not installed on this box'; $script:skipped++
...
"ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })"
"ALL PASS (12 assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
```

Consumers match `ALL PASS` as a substring, so the suffix breaks nothing.
Exemptions are narrow and stated: a site that prints and immediately `exit`s is
its own last line, and a `# skip-audit: <reason>` marker is the same
state-your-intent convention `# persistence:` and `# exitcode-audit:` use.
Analyzer: `test\win32\lib\SkipAudit.ps1`, which reports `unreported` (skips
exist, the verdict is silent) and `uncounted` (a site the counter misses — a
number that under-reports is worse than no number, because it reads as
audited). Acceptance: `test\win32\skip-visibility.ps1`, whose `$SkipAuditPending`
list of not-yet-converted scripts can only SHRINK — an entry that no longer
violates fails the run just as an unlisted violator does.

**And a script that PRINTS failure EXITS failure** (T221). The verdict line is
for the human; the exit code is for everything else, and they used to be able to
disagree. `chooser-menu.ps1` and `host-settings.ps1` ended with a bare `if …
{ "ALL PASS" } else { "$fail FAILURE(S)" }` and no `exit` in sight, so a run with
red assertions fell off the end with `$LASTEXITCODE` at 0 — correct on screen, a
pass to any suite driver, `; if ($?)` chain or CI that scored it. (`config-errors.ps1`
had the identical bug, fixed in T217; all three are fixed, so what T221 delivered
is what keeps them fixed.) The rule runs **both** directions: the failure path
must terminate the script nonzero, AND the pass path must not fall into the
failure verdict on its way out — dropping the `exit 0` from the suite's
early-return shape makes a *green* run announce `FAILURE(S)` and exit 1.

Analyzer: `test\win32\lib\VerdictExitAudit.ps1`, reporting `fallthrough` (the
defect), `exits-zero`, `pass-falls-through` (the other direction) and
`no-verdict`. It reads the **AST**, unlike its two sibling audits, and that is
load-bearing rather than stylistic: in most of this suite the exit shares the
verdict's line (`else { "$fail FAILURE(S)"; exit 1 }`), so a line-oriented reader
must decide what "near" means — the first draft of one reported 128 of 160
scripts. Branch membership is a structural question, so ask the parser. What it
deliberately does not claim is a **computed** exit code (`exit ([int]($failures
-gt 0))`, which two scripts legitimately use); section C of the acceptance script
measures real codes on the wire instead, both shapes and both directions, with
the unfixed shape as a negative control. Exemption: the same stated-intent
`# verdict-audit: <reason>` marker, carried today only by `ipc-fake-server.ps1`,
a helper process with nothing to score. Acceptance:
`test\win32\verdict-exit-audit.ps1`, whose `-TeethCheck` plants a real violator
inside the swept directory and requires the sweep to find it.

**Those exit codes only reach you if you do not pipe them away** (T982). The
scripts hold up their end; the way an agent runs them routinely does not. In a
POSIX shell `powershell -File x.ps1 | tail -5` reports **tail's** status, so a
run that died mid-way reads as 0 — which is how T1000 came to claim that a floor
run "died mid-lane and STILL EXITED 0" when `-File` had in fact exited 1. Worse,
PowerShell cmdlets are not commands in that shell: `... | Select-String error`
fails with `command not found` while the powershell child **keeps running**,
output going nowhere, so a lane looks like it failed instantly and is still
burning a core when the next one starts. Redirect and then filter —
`powershell -File x.ps1 > out.log 2>&1; echo "EXIT=$?"; grep -E 'PASS|FAIL' out.log`
— and gate on the OUTPUT, which is why every script here ends in one parseable
verdict line.

**And a run that asserted NOTHING is not a pass** (T271). The three audits above
all assume a run happened; this is the one that asks whether it did. A
precondition fails — a port still held by the previous run, a shell flavor not
installed on this box, a staging build missing, no usable `HKCU\Environment\Path`
entry — every assertion is dropped, and the last line still reads `ALL PASS
(0 assertions, 1 skipped)` over exit 0. A run that proved the feature works and
a run that never looked at it are then indistinguishable to the loop, to a suite
driver, and to a human reading a wall of green.

The invariant lives in one place, `test\win32\lib\TestScore.ps1`:
`Write-TestVerdict` owns the verdict wording AND the exit code, and answers three
different pieces of news rather than two — `ALL PASS (N assertions[, K
SKIPPED])` at **0**, `N FAILURE(S)` at **1**, and `ASSERTED NOTHING` at **2**,
because "the product is broken" and "the harness measured nothing" are not the
same result and a caller should not have to parse prose to tell them apart.
Existing consumers are unaffected: they match `ALL PASS` as a substring of the
last line and read any nonzero code as red. `-MinPass` is the strong form (a run
scoring 3 of its 30 assertions reports `ASSERTED TOO LITTLE` and also exits 2);
`-NoExit` returns the verdict instead of exiting, which is how `ipc-p1`–`p3` tee
their failure line into a transcript. `Write-TestAssertedNothing -Reason` is the
sugar for a precondition that failed before anything could be measured.

The sweep is `test\win32\lib\AssertedNothingAudit.ps1` — AST-based, for the
reason `VerdictExitAudit` is — enforcing two kinds at zero: `zero-count` (a
verdict hardcoding a zero count) and `early-green` (a pass verdict that ends the
run with exit 0 anywhere but the final verdict, i.e. an abort branch scoring the
whole run green). A third, `uncounted-final` — a final verdict that prints no
count at all, so nothing can tell a full run from an empty one — is reported with
its number under a ceiling that may only fall, rather than as a 37-name allowlist
nobody would read; **T775** converts those onto the scorer and then promotes the
kind. **A new harness starts on `Write-TestVerdict`** — the ceiling went 2 OVER
for eight days (T962) because the four filed after it was set each hand-rolled
their own verdict, and the fix for an exceeded ceiling is to convert scripts, not
to raise the number. Exemption: the same stated-intent `# asserted-nothing-audit: <reason>`
marker. Acceptance: `test\win32\asserted-nothing.ps1` (the scorer on the wire as
real processes, the analyzer against fixtures both directions, the suite sweep),
whose `-TeethCheck` synthesizes a violator so the sweep keeps its teeth once the
suite is clean.

**And a run that DID NOT FINISH is not a pass either** (T1039). The rule above
asks whether a run asserted anything; this one asks whether it got to the end.
Almost every script here wraps its body in a top-level `try { … } finally { … }`
with **no catch** — the finally is how the app, the agent and the test desktop
get cleaned up. Under `$ErrorActionPreference = 'Continue'` a *statement*-
terminating error inside that try (a division by zero, a bad cast, a method on
`$null` — `Get-Content -Raw` answers `$null` for an empty file) unwinds the try,
runs the finally, and then **execution continues with the statements after it**:
the guard stamp and the verdict, with the failure count still 0. Measured in
T329 on `activity-monitor-dialed.ps1`: a `.Trim()` ended the run at the top of
its last section and the script printed `ALL PASS (27 assertions)` and STAMPED.
95 of 155 scripts were in that exact shape. (`throw` is *script*-terminating and
therefore harmless here — it ends the run with no verdict at all.)

The invariant lives beside the one above in `test\win32\lib\TestScore.ps1`:
**dot-sourcing it ARMS the run**, `Complete-TestBody` as the **last statement of
the top-level try body** marks it finished, and `Write-TestVerdict` refuses a
green verdict without it — `RUN DID NOT FINISH (N assertions passed)` at exit
**2**, the same "the harness measured nothing" news as ASSERTED NOTHING. Arming
is the dot-source rather than a call to remember, because a rule that only
protects the scripts that opted in protects nobody; and the marker is checked
*last*, so it only ever speaks over a verdict that would otherwise be green —
FAILURE(S), ASSERTED NOTHING and ASSERTED TOO LITTLE keep their own wording.
The **stamp** is gated in the same breath: the marker publishes
`GHOZTTY_TEST_BODY` (`pending` → `complete`) into the environment, and
`scripts\guard-due.ps1 update` — a child process of the harness — refuses to
write a stamp while it reads `pending`, because the stamp is the half that
outlives the run. Put the marker **before** the stamp block in scripts that
stamp after their try. `-IgnoreRunState` is the one hatch, for
`test\win32\guard-due.ps1`, whose subject *is* stamping; it prints that it was
used.

The sweep is `test\win32\lib\BodyCompleteAudit.ps1` — AST-based — enforcing that
every top-level try in a scored script either **scores its own throw in a
`catch`** (T329's shape) or **ends in `Complete-TestBody`**, and that every
scored script marks completion somewhere (`missing`, `uncaught-try`,
`silent-catch`, `parse-error`, all at zero). Only a *measured* try is judged:
one whose body can lose assertions, derived per file from what that file's own
helpers do to a pass/fail/skip counter, so the `try { $x = [int]$s } catch { $x = 0 }`
idiom is not reported. Scope is the 58 scripts scored by `Write-TestVerdict`;
the rest hand-roll their verdict and arrive under this rule as **T775** converts
them. Exemption: the same stated-intent `# body-audit: <reason>` marker.
Acceptance: `test\win32\body-complete-audit.ps1` (the scorer on the wire as real
processes, the stamp gate against a throwaway repo, the analyzer against
fixtures both directions, the suite sweep), whose `-TeethCheck` plants a real
violator so the sweep keeps its teeth.

**And there is exactly ONE way to put the box back to empty** (T248, T351). A
script never writes its own kill of the app under test or its sibling agent:
`Stop-RepoGhoztty` in `test\win32\lib\CleanSlate.ps1` is it, with `-AppOnly` /
`-AgentOnly` for the two narrower scopes and `Reset-GhozttyTestState` on top when
the debug restore state must go too. It matches the EXACT ExecutablePath of the
exe under test and refuses outright an exe that is not under the repo — the
guarantee no private copy ever had, because they all filtered and none of them
refused. This rule has been paid for twice: T248 hoisted the reset and converted
19 scripts, and three weeks later **133** scripts carried a private copy again
under six different names, four of them redefining `Stop-RepoGhoztty` itself so
the private body won inside that process. Two divergences were live in them —
`$_.CommandLine -like '*zig-out*'`, which also kills a detached instance running
from `zig-out-release` (T53b), and app-only copies that left the agent holding a
PTY, so a previous run's pane survived and `+new-window --target=` FOCUSED it
instead of running this run's fixture. Litter that is genuinely one script's own
(a relay stub, a fake agent, marker-ping shells) stays local; the app and its
agent are everybody's. Sweep: `test\win32\lib\CleanSlateAudit.ps1`, reporting
`private-kill` and `empty-exemption` at zero over every harness script, plus a
caller that never dot-sources the library and a script that redefines the shared
name. Exemption: the same stated-intent `# cleanslate-exempt: <reason>` marker,
and a *reasonless* marker is itself a finding so it cannot become a rubber stamp.
Acceptance: `test\win32\cleanslate-audit.ps1`, whose `-TeethCheck` plants a real
violator.

**And the endpoint a script isolates onto is unique to the RUN** (T441, T352).
`Set-GhozttyTestIsolation` is the preferred form and has always appended `$PID`;
the hand-rolled half of the suite wrote `$env:GHOZTTY_PIPE_SUFFIX = '-vptest'`
and 131 scripts pinned one endpoint for all time that way. That isolates the
script from the user's terminal and from its neighbours, but not from its own
previous run: an instance leaked by a run that died before its cleanup is still
answering there with its windows and their `--target=` names registered, and
`+new-window --target=<name>` is idempotent BY DESIGN — it FOCUSES a name it
finds. The next run then grades last run's screen and passes. Keying the suffix
on `$PID` closes that for every name the script registers, now and later, at one
site per script — which is why the `--target=` names themselves were left alone
rather than each given a run-unique prefix of their own. Exemption: a
`# isolation: shared - <why>` marker for a script that genuinely needs an
endpoint a second process names by hand, and a reasonless marker is itself a
finding. Acceptance: `test\win32\isolation-meta.ps1` section C, with synthetic
controls A6–A10 and a real-tree teeth check in T352's own validation.

**And an oracle must read the same text wherever it runs** (T526, T531, T883).
The audits above ask whether a run happened and whether it scored itself
honestly. This one asks whether what it MEASURED was real. `2>&1` does not merge
bytes: it wraps each of a native command's stderr lines in an **ErrorRecord** and
puts the object on the pipeline, so `... 2>&1 | Out-String` hands the FORMATTER
the oracle's input — and formatting is a property of the host. The same
`git --nosuchflag` capture measured 774 characters in this box's tool session
(buffer width 134) and 778 in a consoleless child (width 120), because the
`NormalView` block it pads the message with is wrapped to the host's width and a
phrase an assert matches can land across a wrap. In a host PS 5.1 cannot format
for at all the record renders **blank**: that is what hid 14 red stderr-text
asserts in `viewer-panes.ps1` behind one apparently-stale failure, all of them
silently comparing against `''` (T526). The flip side is worse than a plain red —
the unfixed spelling works in a real console, so the same script is green by hand
and blind in the loop.

Stringify each object BEFORE the formatter and the formatter leaves the path
entirely, since `Out-String` passes plain strings through verbatim (measured: a
300-character string survives it unwrapped at any width):

```powershell
$out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
```

`cmd /c "exe args > file 2>&1"` is the other host-independent shape — bytes on
disk, written by cmd, PowerShell never holding an object — and is what
`cli-unknown-flag.ps1` and `ipc-target-exists-note.ps1` use. A PowerShell
redirect to a FILE (`*> $log`) is NOT one of them: it formats on the way to disk
the same way, which is how a launcher refusal that was in fact printed reached
`upgrade-no-fork.ps1`'s L24 as `''` (T531).

The error stream is not the only one that does this. `6>&1` — how a script
captures a PowerShell helper's `Write-Host` output — puts **InformationRecords**
on the pipeline and `Out-String` wraps them at the host width just the same:
measured, a 300-character `LEAK …` line came back with a newline through it and
a `-match` on the whole phrase failed, while the stringified capture kept it
whole. Five sites in the leak-sweep and cache-heal harnesses were in that state,
and no grep for `2>&1` would ever have found them.

The sweep is `test\win32\lib\StderrCaptureAudit.ps1` — AST-based, so a `2>&1` in
a comment or a here-string is not a finding and a stringify three elements
downstream still counts — enforcing `merged-formatted` (a merged stream reaching
`Out-String`/`Format-*` unstringified) at zero across `test\win32\*.ps1` **and**
`test\win32\lib\*.ps1`; the lib is swept because one of T883's 56 converted sites
was in `lib\BuildMode.ps1`. A second kind, `merged-to-file`, is reported under a
ceiling that may only fall rather than enforced: most such sites discard to a
file nobody reads back, and only a human can say which are oracles. Exemption:
the same stated-intent `# capture-audit: <reason>` marker. Acceptance:
`test\win32\stderr-capture-audit.ps1`, which measures both shapes live before it
scores anybody, and whose `-TeethCheck` synthesizes a violator so the sweep keeps
its teeth once the suite is clean.

**And a harness nobody RAN proves nothing either** (T783). The five audits above
all ask what a run said; this one asks whether the run happened at all. Outside
the P1–P3 floor an acceptance script is run when somebody remembers it, so a
harness can go red against code that changed under it and stay red unnoticed:
`b64c3e8aa` prefixed every `scripts\go-loop-lock.ps1` message with an ISO
timestamp, 26 assertions in `test\win32\go-loop-guard.ps1` anchor on the answer's
first word (`^ACQUIRED`, `^held`, `^stale-dead`), and the whole guard was red for
a day against a lock script that was working perfectly. The loop's supervisor is
the one thing whose failure nothing else can catch, which makes its harness the
worst place in the tree for that gap.

`scripts\guard-due.ps1` answers the question from a **committed stamp**: a
coverage table maps a harness to the files it is ABOUT (the `go-loop` row covers
`scripts\go-loop-*.ps1`, `scripts\loop-session.ps1` and the harness itself), a
clean green run of that harness stamps the SHA-256 of each of them, and `check`
compares the tree against the stamp — `GUARD CURRENT` when they match,
`GUARD DUE` naming each file that changed, appeared or vanished when they do not.
Four consequences it was built for:

- **It is a change gate, not a schedule.** A stamp never goes stale with time,
  and a file edited and edited back is not due. Hashing is over CRLF-folded,
  BOM-stripped bytes, because `.ps1` carries no `text` attribute in
  `.gitattributes` — a raw hash would report every file as changed on a
  differently-configured clone, and a gate that cries wolf is a gate nobody
  reads.
- **The stamp is committed**, so the question travels with the change: a
  `git pull` bringing in a loop-script edit made on another seat reads as DUE
  here, which is exactly what a local mtime or a "did this turn touch it" check
  cannot see.
- **Only a CLEAN green run stamps.** A red run leaves the stamp alone (red must
  stay due), and so does a run with skipped sections — a stamp written over
  unmeasured code is the green hat the T219 audit exists to refuse.
- **Two wirings, deliberately different in force.** `go-loop-exec.ps1 claim`
  (go.md step 0) REPORTS and never fails, because a claim that could exit
  nonzero over a stale stamp would wedge the loop, which is the disease and not
  the cure; `parity-tasks.ps1 validate` (go.md step 6, before every commit)
  FAILS, because that is where the remedy — run the harness, or fix what it
  catches — is the work this exists to cause. `-NoGuardDue` is the stated-intent
  hatch; it prints that it was used **and names which rows it excused** (T1189),
  so a turn excusing a harness that cannot run here and a turn excusing a RED
  one no longer leave identical evidence behind them.
- **A row this box cannot answer is `Advisory`** (T1189). The
  `release-artifacts-packaging` row asks whether the MSI still compiles, which
  needs wixl — Linux tooling, therefore Docker, which is deliberately kept down
  on this box. It was due after every `build-msi.sh` edit and the only way past
  the gate was `-NoGuardDue`, every time; a hatch pressed every time carries no
  information. An advisory row is reported everywhere a blocking one is (as
  `GUARD DUE (advisory) …`) and counted against nothing. That is a
  de-escalation, not a hole: `install-launch` covers the same file and still
  blocks, sections B5–B7 of `release-artifacts.ps1` parse the generated WXS
  without Docker, and fork-ci compiles the package on every push while
  `validate` already fails on a red CI verdict (T1219).
- **A row may be cleared from the build machine** (T1189):

  ```
  powershell -NoProfile -File scripts\guard-due.ps1 stamp-ci -Guard release-artifacts-packaging
  ```

  A row declaring `CiEvidence` names the workflow and job whose green run proves
  what the local harness would have. `stamp-ci` finds a successful run of that
  JOB (a green run with the job skipped proves nothing), checks that every
  covered file **at that run's commit** hashes the same as the file on disk now,
  and only then stamps — recording the run url and sha as the stamp's
  provenance, so the `GUARD CURRENT` line says the proof came from CI rather
  than from here. There is no hatch past the content check: a stamp taken from a
  run that built other bytes is the exact lie this mechanism exists to prevent.

It never runs a harness (that would put a multi-minute GUI-launching script
inside whatever called it) and never decides one PASSES — only that one has not
been asked. Acceptance: `test\win32\guard-due.ps1`, whose sections D and E
measure the two forces against each other (the same staleness must fail
`validate` and must not fail `claim`).

**And the SUITE itself is one command now** (T361). The stamp above is per
harness; nothing could ever run the whole of `test\win32\` — 241 top-level
scripts, 136 of which drive a GUI — so a change to a shared harness library
(`lib\TestDesktop.ps1`, `lib\ChromeGeometry.ps1`, `lib\CleanSlate.ps1`) was
validated against the handful a turn happened to think of, and the rest were
found broken by whichever later turn opened one. T267's own Validation asked for
"the GUI suite twice back to back, and then in reverse order" and could not be
discharged, because there was no runner and nobody had measured what a pass
costs.

```powershell
powershell -NoProfile -File scripts\suite-run.ps1 list          # what is in the suite
powershell -NoProfile -File scripts\suite-run.ps1 -Set gui      # run them all
powershell -NoProfile -File scripts\suite-run.ps1 -Set gui -Order reverse
powershell -NoProfile -File scripts\suite-run.ps1 compare -Runs a\summary.json,b\summary.json
```

Each script is its own `powershell -File` child with its stdout and stderr in a
per-script log, scored by the verdict contract above — `pass` / `fail` /
`nothing` (exit 2) / `stall` (killed at `-TimeoutSec`) / `error` (an odd exit
code, or exit 0 with no verdict line, which is the T221 shape and must never
launder as green). Four properties are the ones that matter in practice:

- **It survives being killed.** Every row is written to `summary.json` the
  moment its script ends, so a sweep stopped at script 90 keeps 90 rows, and
  `-Resume <summary.json>` picks up from there. A suite this long is going to be
  interrupted; the design assumes it.
- **One hang costs one script.** The child is killed at the timeout, scored
  `stall`, and the sweep carries on.
- **It sweeps leaks between scripts** — anything still running out of the repo's
  `zig-out`, path-exact and repo-scoped the way `lib\CleanSlate.ps1` is — and
  reports which script leaked. A leaked instance poisons every script after it,
  and the one that leaks is rarely the one that then fails.
- **`compare` is what discharges an order-independence claim.** Forward,
  forward, reverse, then compare the three summaries: a script whose verdict
  moves is reading state a neighbour left behind.

**It is serial, and that is a measured decision, not an omission.** Every script
here resolves the app as `<repo>\zig-out\bin\ghoztty.exe` — 91 of them compute
that path internally and ignore any `-Exe` a caller passes — and `CleanSlate`
kills the app under test by exact ExecutablePath. Two workers out of one
`zig-out` therefore kill each other's app mid-assertion, with no error either
can attribute, and they share `%LOCALAPPDATA%\ghoztty\*` besides. Parallelism
needs a per-worker exe copy and a per-worker `LOCALAPPDATA`, which needs every
script to honor an injected exe path first — a suite-wide change with its own
task. Until then the honest number is the serial one, and the runner prints it.
Acceptance: `test\win32\suite-run.ps1`.

**A red script is RE-RUN ALONE before it becomes a task** (T1137). "The feature
is broken" and "the test is broken" produce exactly the same red row, and the
sweep of 2026-08-22 filed thirty-one tasks off its red rows without anyone
telling the two apart. The first EIGHT of those to be worked — T1102, T1103,
T1104, T1105, T1106, T1107, T1108, T1110 — were all the harness. Every one had
been priced P1 and written up as a user-facing outage ("Ctrl+T from a viewer pane
no longer opens a tab", "the menu bar disables Close Tab with two tabs open"),
and several were `ALL PASS` on the first re-run, before a line of product code
had been read. A turn each.

So the runner does it, and the answer is in the row rather than in someone's
memory of the run:

```powershell
powershell -NoProfile -File scripts\suite-run.ps1                       # confirms as it goes
powershell -NoProfile -File scripts\suite-run.ps1 confirm -Resume <run>  # an older summary
```

- **Every non-pass script is re-run once, on its own, at the end of the run.**
  Only the reds — a pass is never re-run, so the pass costs the reds' time and
  nothing else. The second run is scored by the same code as the first, and its
  log is kept beside it as `<name>.alone.log`, so two disagreeing runs can be
  diffed rather than argued about.
- **What it decides.** Green alone = an isolation, timing or harness defect,
  which is NOT a user-facing outage and must not be titled or priced as one. Red
  both times = a product-defect candidate, and it keeps its priority. Neither is
  proof; what the pass buys is that the person filing starts from two data points
  instead of one.
- **"Not re-run" is a third answer and never reads as the first.** A row nobody
  confirmed carries an empty `Reproduced`, and the table says `[alone: not
  re-run]` — the one thing a summary must never do is let "we did not ask"
  look like "it did not reproduce".
- **`confirm -Resume <run>` is the retrospective half**, filling the same fields
  into a summary written before the pass existed. That is how a queue of tasks
  already filed off an old sweep is re-priced from evidence.
- **A resumed sweep does not re-confirm what already has an answer**, so the
  pass is idempotent across the interruptions a multi-hour sweep collects.

Acceptance: section P of `test\win32\suite-run.ps1` (a fixture script that is red
once and green after, one that is red however often it runs).

**A window under test is identified by the NAME the test gave it, never by "the
one that was not there a moment ago"** (T1103). `viewer-popup.ps1` snapshotted
the set of windows to ignore AFTER the page under test had already had the chance
to open its popup, so the popup was inside the ignore set and the script could
never find it again — filed, at P1, as "a viewer page's `window.open()` popup is
never adopted". The feature worked; the same run's later sections found that
popup by its title and closed it.

The rule, in the order to reach for it:

1. **Name it and ask for it by name.** Every window this suite opens is opened
   with `--target=<name>`, and that name is how it is found again — through
   `+list`, through `Wait-Win`, through its caption. A name the test chose cannot
   be raced by anything the app does on load.
2. **Where a handle really is needed, snapshot BEFORE the call that creates it**
   and diff after — never after an action that could itself have created one.
   The distinction is the whole defect: a set difference is a fine way to find a
   window whose creation you caused and bracketed, and a coin flip otherwise.
3. **Never let the set of things to ignore be gathered late.** An ignore list
   built after the fact hides the very object under test, and the failure it
   produces is "the feature never happened", which is indistinguishable from the
   feature never happening.

Swept 2026-08-23 (T1137): six scripts identify a top-level window by set
difference — `close-confirm-idle.ps1`, `hero-nav.ps1`, `overlay-zorder.ps1`, and
`viewer-panes.ps1` in three places — and all six snapshot before the call that
creates the window, so none is the shape above. Pane-name diffs
(`host-settings.ps1`, `remote-inherit.ps1`, `local-split-no-command-rerun.ps1`,
`chooser-resume-remote.ps1`) bracket a `+split` the script itself issues, which
is rule 2 rather than the defect.

**And a harness that ran against a STALE EXE proves nothing either** (T1028).
The stamp above answers "has this harness been run against the code as it now
stands?" — and until now the run itself never checked. Every `test\win32` script
defaults `-Exe` to `zig-out\bin\ghoztty.exe`; eleven of them build it first and
the rest, the P1–P3 floor included, drive whatever copy is on disk. The false RED
is self-correcting (T316's first `relay-account.ps1` run reported 3 FAILURE(S)
against an exe built four hours earlier, and a rebuild made it green). The false
GREEN is the defect: a change a stale exe still passes exits 0, exiting 0 STAMPS
the guard, and the one question the stamp exists to answer has then been made to
lie without anybody acting in bad faith.

`test\win32\lib\BuildFresh.ps1` is the freshness half of the same pre-flight that
already refuses a wrong-MODE build. It is dot-sourced by `lib\BuildMode.ps1` and
called from `Assert-GhozttyIsolatedBuild`, so all 49 scripts that ask the first
question ask the second one too, with no per-script edit:

- **Newest source mtime vs the exe's, not the baked commit.** A commit
  comparison is right for a *delivery* (`upgrade-staleness`) and wrong here in
  both directions: blind to uncommitted work — the state a turn is in for the
  whole of go.md steps 2–4 — and red on a commit that changed nothing, since the
  loop builds, tests and only then commits.
- **Sources are `build.zig`, `build.zig.zon` and `src\` minus `*.md` and
  `src\apprt\gtk\`.** A docs-only edit and Linux's frontend cannot change these
  bytes. ~1258 files in ~17ms, cached per process.
- **Only `<repo>\zig-out\` is in scope.** An installed release, a portable copy
  and a `$TEMP` stub are not claimed to be built from this tree, so "older than
  `src\`" says nothing about them.
- **Refuse by default, before anything is launched**, naming the exe, the source
  that outran it, the drift and the build command. Two stated-intent hatches,
  both loud: `GHOZTTY_TEST_REBUILD_STALE=1` builds and writes a witness beside
  the exe (the exit from the one false positive — an edit outside this exe's
  module graph relinks nothing, so the mtime would never move and the refusal
  would never clear), and `GHOZTTY_TEST_ALLOW_STALE=1` accepts a result about
  the old bytes and says so on the way past.

Acceptance: `test\win32\build-fresh-guard.ps1`, which plays both sides in a
throwaway fixture repo under `$TEMP` and keeps a positive control on the real
`zig-out` exe.

**And a harness that needs an ON-DEMAND binary builds it itself** (T359).
`remote-test-client` — the only thing here that speaks the agent protocol
without a GUI — has its own `zig build remote-test-client` step and is reached
by nothing the default install step builds. Six acceptance scripts need it, and
every one used to open by asserting the file exists, so a tree that had only
ever run `zig build -Dapp-runtime=win32` met `FAIL remote-test-client exists`:
a precondition that reads like the agent failed to build, and that two of the
six then `exit 1` on, taking their remaining assertions with them.

`test\win32\lib\TestClient.ps1` is the resolve-or-build half of the pre-flight:

```powershell
. (Join-Path $PSScriptRoot 'lib\TestClient.ps1')
$ClientExe = Resolve-RemoteTestClient -ClientExe $ClientExe
```

- **Resolve EARLY**, next to the `CleanSlate`/`BuildMode` dot-sources, before
  the script redirects `%LOCALAPPDATA%` or takes its isolated endpoint — this
  shells out to zig, and a build launched from inside a live fixture is a
  different experiment than the one the script is running.
- **Debug, and `ZIG_GLOBAL_CACHE_DIR` derived onto the repo's drive**, so the
  client matches the `zig-out` around it (T350) and the build cannot hit the
  cross-drive assert (T243).
- **A failure still names the command.** `Get-RemoteTestClientBuildCommand` is
  the single spelling of `zig build remote-test-client -Doptimize=Debug`, and
  every precondition message interpolates it: a precondition that cannot be
  acted on is half a message. `-NoBuild` is the hatch for a run that must not
  shell out.
- **The default build stays lean.** The prerequisite is declared at the point
  of use rather than bolted onto the install step — the same shape as the
  delivery launcher building its own staging release instead of assuming one.

Acceptance: `test\win32\test-client-build.ps1`, whose section D deletes the real
client and makes the helper put it back, and whose section E re-derives the
consumer list from the tree so a seventh script cannot regress to a bare
existence assert.

**And a script that can only run on the INPUT DESKTOP has to SAY so** (T272,
widened by T276).
T211–T218 moved the GUI suite onto a background desktop because the user's
complaint was that a test run kept stealing their focus, and the buckets closed
at 23 of 23 and 13 of 13 — with two scripts (`overlay-zorder`, `split-dim`) in
neither, still grabbing, because nothing counted the remainder. They were
migrated (T224/T225); what stops the property regrowing is that the *remaining*
exceptions are declared where the reader already is. `lib\TestDesktop.ps1`'s
header carries them as `# @input-desktop-exception: <script> -- <reason>` lines,
and `lib\ForegroundAudit.ps1` **parses that header** rather than restating the
list, so the prose a human reads and the set the check enforces cannot drift.
Three kinds, all enforced at zero: `undeclared` (a grab site on no list),
`stale-declaration` (a declared script that no longer grabs, or no longer
exists — a list naming scripts that need no naming is how a real miss gets waved
through), and `malformed-declaration` (including an empty list, which would turn
every violation into a pass). A grab site is **live code only** — a token that is
neither a PowerShell comment nor a `//` comment inside an `Add-Type`
here-string — because two thirds of the suite MENTIONS `SendInput` in a header
explaining that it is dead off the input desktop, and reading those as violations
would push 22 innocent scripts onto the exception list, which is the same rot
from the other direction. A hardcoded `New-TestDesktop -Interactive` counts too
(the hatch is for debugging by hand, never for scoring a run); forwarding the
switch does not.

**Stealing focus is one cause of being un-runnable in the loop, not the
definition of it** (T276), so a second family counts toward the same one list: a
read of the **composited screen** — `CopyFromScreen`, or `GetDC`/`GetWindowDC`/
`Graphics.FromHwnd` on a NULL or desktop hwnd — which DWM produces for the input
desktop only. T272's rule was written as "takes the foreground" and its sweep
therefore could not see `color-contrast.ps1`, which called neither watched API
and was input-desktop-only all the same; `split-dim.ps1` used the identical
mechanism and made the list only because it ALSO grabbed focus, which is luck,
not coverage. (Both are moot as findings today — T225 and T275 migrated them —
which is exactly why the check has to hold the property instead of the memory of
it.) The NULL is load-bearing: `GetDC($hwnd)` is a window DC, works fine off the
desktop, and is not a finding, so a P/Invoke *declaration* never trips the rule.
This family needs its own detection pass rather than a longer pattern, because a
screen-DC call site spans several PowerShell tokens (`[Drv]`, `::`, `GetDC`, `(`,
`[IntPtr]`, `::`, `Zero`, `)`) while every watched user32 name is a lone
identifier — it scans the whole source with comment spans blanked
*length-preservingly*, so offsets still name their line. Second reason to flag
one, beyond the desktop it needs: **where a probe reads is not what it reads.**
`split-dim`'s probe was carried as a terminal-content probe by three task files
because it sampled a point over the terminal; what it sampled was a layered
window in front of it. A window capture names its target, a screen DC names a
point.

Acceptance: `test\win32\foreground-audit.ps1`, whose `-TeethCheck` writes real
undeclared violators into the swept directory — one per family — rather than
synthesized findings, since the claim under test is that the sweep notices.

**A synthesized click routes the way Windows routes it** (T263).
`Send-TestMouse` asks the target `WM_NCHITTEST` at the point first and delivers
the `WM_NC*` family whenever the answer is not `HTCLIENT` — the same decision
`DefWindowProc`'s input path makes. Since T254 the caption band is client
PIXELS that the window claims back through its hit test, so the harness's
client-only `WM_LBUTTONDOWN` reached no handler there at all: T260 lost 17
assertions to it against a caption that was painting and hit-testing correctly,
and every script that met it grew a private `WM_NCHITTEST` + posted
`WM_NCLBUTTONDOWN` pair to work around it. Three answers are deliberately NOT
converted — `HTNOWHERE`, `HTTRANSPARENT` (the surface child returns it over the
split-divider grab band) and `HTERROR` — because all three mean "not me", which
is the z-order question this harness deliberately does not ask: it posts to the
hwnd you NAME. Two consequences worth knowing: a click at the window's last
column in the merged row is the CLOSE button and really closes the window, so a
probe whose subject is what the STRIP does with that column passes the
`-Client` escape hatch; and `Get-TestMouseRoute` reports the decision, so a
script can assert "this point is the minimize button" before clicking and read
a moved button as a moved button. `GHOZTTY_TEST_MOUSE_CLIENT=1` reproduces the
pre-T263 harness from the same tree, which is how a red script is told apart
from a routing regression. Acceptance: `test/win32/mouse-nc-routing.ps1`.

**A test sandbox can have an agent of its own** (T167). The local agent's
single-instance guard is per-user and per-LINEAGE, and the lineage is a
compile-time fact (`local-debug` for every debug build), so a debug agent
already running refuses a sandbox's agent with exit 183 — and the app then falls
back to plain exec panes *silently*, leaving a suite that reports on session
persistence while exercising the non-persistent path. That is why so many
scripts open by killing every `local-agent-debug` process, which takes the
loop's own panes with it and means two suites can never run at once.
`GHOZTTY_AGENT_INSTANCE=<suffix>` names a distinct lineage instead, and it moves
**every** derivation that spells the lineage out — the guard mutex, the lock and
heartbeat files, the app's state dir (`local-agent-debug-<suffix>`), its agent
pipe (`\\.\pipe\ghoztty-agent-debug-<suffix>-<user>`), the HKCU Run value name,
and the dir `+sessions` reads — because a *half*-isolated sandbox is the bug,
not the fix. Sanitized to a whitelist and capped at 24 characters, with an
over-long value rejected rather than truncated (truncation would silently merge
two sandboxes into one lineage). Unset — every production run — reproduces each
legacy name byte for byte. Rules: `src/remote/agent_lineage.zig`; acceptance:
`test/win32/agent-instance-lineage.ps1` (which carries a `-TeethCheck` self-test
for its own end-to-end arm). Converting the existing suites onto it is T691; the
Swift half is T692.

**Tests must never touch live user state.** The WebView2 live-runtime tests run
under `webview2.TestProfile`, which points `LOCALAPPDATA` at a private per-run
root so they cannot contend with — or corrupt — the `EBWebView[-debug]` profile
a real Ghoztty is using. And a test server thread blocked in `accept()` is woken
with a **real connection** before its listener is closed: on Windows
`closesocket` does not signal a blocking call pending in another thread, so
close-then-`join()` is an indefinite hang (`TestPage`/`ReloadPage` in
`ViewerPane.zig`, `keepalive.zig`, `link_control.zig`).

On Windows, behavior that unit tests cannot reach is covered by non-interactive
PowerShell acceptance scripts in `test/win32/` (80+ of them). The standing
regression floor is P1–P3, which must stay ALL PASS:

```powershell
powershell -NoProfile -File test\win32\ipc-p1.ps1   # +new-window, +list, +close
powershell -NoProfile -File test\win32\ipc-p2.ps1   # +split, +rename, +send-keys
powershell -NoProfile -File test\win32\ipc-p3.ps1   # +read, +set-state, OSC 7777, +rearrange
```

Each prints a single `ALL PASS` / `N FAILURE(S)` line at the end, so
`| Select-Object -Last 1` is enough to read the result. They default to
`-Exe D:\git\ghoztty\zig-out\bin\ghoztty.exe` and only ever touch ghoztty
processes running from that exact path, so they cannot disturb the user's
installed release.

**Everything gets tests**: pure logic → unit tests in the `none` lane;
behavior → an on-box acceptance script. Win32 chrome geometry belongs in the
pure geometry modules and must be asserted at 1.0, 1.25, 1.5 and 2.0 scaling
(see `docs/claude/win32-ui.md` and `docs/design/win32-design-system.md`).

**Every launch in an acceptance script declares its session persistence**
(T158). Persistence is ON by default, so a GUI launched without
`--session-persistence=false` restores whatever panes the last launch left —
and each section writes the manifest the next one restores, so a script
poisons itself on a clean box (T131, then T155, where two scripts failed
`default setup: 2 visible panes` against a build whose geometry was verified
correct by hand). But a third of the suite WANTS it on — the `session-*`,
`agent-*` and restore families — so the rule is not "always pass the flag", it
is **state which you want**: pass the flag, pass something built from it, have
every caller of your helper pass it, or write a `# persistence: <reason>`
marker for a site where none of those fit (a CLI verb, a throwaway-
`LOCALAPPDATA` launch, a forward-and-exit second instance). The value must be
one `parseBool` accepts (`1/t/T/true/on/yes`, `0/f/F/false/off/no`) — anything
else is logged, dropped, and leaves a launch that looks explicit and restores
anyway. Enumerator: `test/win32/lib/PersistenceSweep.ps1`; acceptance (and the
live control that the flag really stops a restore):
`test/win32/persistence-flag.ps1`.

**A restore test must prove the pane is LIVE, not painted** (T532, T652). A
pane that came back as a frozen picture is byte-identical to a working one for
every assertion that reads the screen or `+list --json` — a replayed marker is
by definition a recording, a restored banner is a picture of a banner, and the
agent's `alive`/`attached` rows describe a child that may be wired to nothing.
On 2026-08-06 a user hit exactly that, with the whole acceptance suite green
over it. So every script that restores or re-attaches a pane types into it and
requires an answer: `Test-PaneLive` in `test\win32\lib\PaneLiveness.ps1` (an
`echo <token>`, matched **twice** — once as the echoed input line, once as the
command's output, because one hit is only bytes going in). Re-running a script
with `GHOZTTY_TEST_LIVENESS_BREAK=1` makes every liveness arm in it go red and
nothing else move, which is how each arm was teeth-checked. A viewer pane has
no shell; its equivalent claim is that the PAGE still responds — see the
page-server oracle in `test\win32\viewer-restore.ps1`.

**A Debug pane's SCREEN runs about 12 KB/s, so never wait on it for a burst**
(T1116, T1142). Measured on 2026-08-23 with 20000 numbered lines (180 KB) piped
into a pane and `+read` polled for the highest line the app had reached: the app
ingests **12–15 KB/s** on a Debug build and **~1 MB/s** on a ReleaseFast one — a
~65x gap that is Debug codegen of the terminal parse path, not a defect in
anything the user runs (a release pane tracks its child to inside one poll
interval at 4.5 MB, against conhost's 1.9 MB/s on the identical payload). Two
consequences for harness authors, and the first one has already cost a turn:

- **The two pane paths differ in who absorbs the backlog, not in speed.** A
  local (`termio.Exec`) pane's ConPTY back-pressures the child down to the app's
  parse rate, so its screen is never more than a second behind. An agent-backed
  pane's inbound ring takes the whole burst and lets the child run on — child
  done at 2.6 s, screen caught up at 18.0 s in the same run. So a flood driven
  to "the marker appeared on screen" pushes **many times** the volume it meant
  to through an agent pane, which is exactly how T1116's marker got evicted from
  the very ring its assertion was about. Drive volume off the ring or the
  snapshot file, never off the app's screen.
- **Budget for it.** A 180 KB burst costs ~18 s of Debug wall clock before the
  screen agrees it happened; scale the timeout to the payload, not to intuition.

The standing measurement is `test\win32\pane-ingest-lag.ps1` (guard
`pane-ingest-lag`), which asserts the backlog DRAINS — a catch-up bound, an
ingest floor, and the pane still LIVE afterwards — with regression headroom over
the Debug numbers rather than a claim about how fast the product is. Its
`-NegativeControl` hunts for a line the payload never contains, so the catch-up
arms must go red while the setup arms stay green.

**A probe of the terminal GLASS asks the app, not the desktop** (T275). The
acceptance suite runs on a background desktop, where there is no composite to
`GetPixel` and `PrintWindow` of a `GhozttyTerminal` child returns a **flat
fill** — a perfectly valid bitmap, which is why T214 DROPPED three assertions
about rendered content rather than weaken them into something a blank fill
passes. The way around it is the debug-only **`capture-pane`** IPC action: the
pane's own renderer thread reads back its **offscreen** target (the readback
hero mode's carousel thumbnails already use — `Surface.heroSnap*` →
`OpenGL.captureThumb`), and the app writes a PNG. No desktop, no composite, no
window visibility: a pane hidden with `SW_HIDE` captures exactly as a focused
one does. Harness side: `Get-TestPaneCapture` in `test\win32\lib\PaneCapture.ps1`
(route 0 in TestDesktop.ps1's CAPTURE LIMIT header); the three dropped
assertions are back in `hero-mode.ps1` and `window-color.ps1`, and
`color-contrast.ps1` — the accessibility oracle — moved off the input desktop
onto it.

**There is deliberately no `ghoztty +capture-pane`.** `src/cli/ghostty.zig`'s
`Action` enum is shared by every apprt, so a verb there is a cross-platform CLI
surface and a Mac obligation — the T141 rule. This is instrumentation with one
consumer, so it is gated on `build_config.is_debug` and the harness frames the
request itself; a shipped ReleaseFast build answers `unknown action`, which
costs the suite nothing because T350 already requires every acceptance script to
run against a Debug build. It captures ONE PANE and therefore says nothing about
z-order or the strip of parent between two panes — a composited capture is
**T778**. Acceptance: `test\win32\pane-capture.ps1`, whose load-bearing oracle
is two panes with different tints each reporting its OWN tint (a flat fill
cannot answer both), plus section 4 of `test-desktop-harness.ps1`, which reads
the same pane at the same moment through both paths (94 distinct colors vs 1).

**A HOVERED frame needs the same treatment, for a different reason** (T282).
The pixels of the chrome were always capturable; the hovered *frame* was never
painted. On a background desktop there is no real cursor, so `TrackMouseEvent`
makes the OS post `WM_MOUSELEAVE` within a frame of every posted
`WM_MOUSEMOVE`, and `WM_PAINT` is the lowest-priority message in a thread's
queue — the leave is drained FIRST and what gets painted is the un-hovered
state. An ORDERING problem, not a race: T209 measured 300 posted moves in
bursts of 25, interleaved with captures, and never once caught a lit fill. So
every hover fill in the win32 chrome was a `SKIP` or a per-site workaround
through a state that happens to survive a leave (a drag, a press).

`capture-hover` moves the whole probe onto the app's GUI thread, where the
ordering is a property of who is on the stack: hit-test, SEND the move (a sent
message is a direct call to the window procedure when sender and target share a
thread), `RedrawWindow(RDW_UPDATENOW)` — also synchronous — then `PrintWindow`.
The message loop is never reached in between and a posted message is only ever
drained by the message loop, so the leave cannot interleave. Nothing is
un-done: the leave lands on the next pump exactly as before, which is why this
is a capture and not a "suppress the leave while a debug flag is set" switch
whose bad day is a hover stuck lit. Same gate and same no-CLI-verb rule as
`capture-pane`; harness side is `Get-TestHoverCapture`
(`test\win32\lib\HoverCapture.ps1`, route H in `TestDesktop.ps1`'s CAPTURE
LIMIT header). Acceptance: `test\win32\hover-capture.ps1`, whose load-bearing
oracle is two controls and two captures — hovering the "+" must light the "+"
and leave the tab's close "×" dark, and hovering the "×" must do the reverse,
which neither an un-hovered frame nor a latched hover can answer both ways.

One thing the skips were hiding, found by removing them: `T204_NEUTERED` was
consumed as a single global `universalHover()`, so flipping it took the fill
off EVERY icon button — including the "+", which the acceptance scripts
describe as their positive control ("+ lit, × dark" is a product defect;
"neither lit" is a broken control). It is `icon_button.lightsFill(glyph)` now,
answered per glyph. Same shape as the bug T209 found in `glyphCentered()`: a
negative control that answers a question no paint site asks is decoration.

