# T476 — zig 0.15.2 self-hosted x86_64 backend crashes on uucode's generated tables

This is the **reduction** for T476: a standalone project, with no ghoztty
source in it at all, that makes `zig.exe` 0.15.2 die while compiling a test
binary with the self-hosted backend (`use_llvm = false`).

It exists so the bug can be reported upstream, and so the next zig the repo
moves to can be re-checked in one command instead of by rebuilding ghoztty.

## What it is

Three files (`build.zig`, `build.zig.zon`, `src/main.zig`) plus a copy of
ghoztty's own `src/build/uucode_config.zig`. The only dependency is
[`uucode`](https://github.com/jacobsandlund/uucode) 0.2.0, pinned to the same
tarball `build.zig.zon` at the repo root pins.

`src/main.zig` is fifteen lines: it calls
`uucode.get(.case_folding_full, cp).with(&buffer, cp)`, which is exactly what
`input.Binding.Trigger.foldedCodepoint` does.

## How to run it

The project must live on the same drive as `ZIG_GLOBAL_CACHE_DIR` (zig 0.15.2
asserts otherwise — see `docs/claude/build.md`), so copy it somewhere on the
repo's drive first:

```powershell
$env:ZIG_GLOBAL_CACHE_DIR = 'D:\zig-global-cache'
robocopy test\zig-repro\t476-selfhosted-backend D:\t476repro /E | Out-Null
cd D:\t476repro

zig build                                             # -> STATUS_BREAKPOINT, silent
zig build -Dtarget=native-native-msvc -Dcpu=baseline  # -> STATUS_ACCESS_VIOLATION
```

Both are `zig.exe` dying, reported by `zig build` only as `error: the
following command exited with error code 3` / `code 5` — `std.process.Child`
truncating an NTSTATUS to a byte (T444). Read the real exception back with:

```powershell
. scripts\lib\CrashDiag.ps1
Get-ProcessCrashEvent -Since (Get-Date).AddMinutes(-5) -NameLike 'zig.exe'
```

**Exit 0 from both commands means the compiler bug is gone** — that is the
signal to drop `-Dtest-llvm` from `build.zig` and delete this directory.

## What was measured (2026-09-04, zig 0.15.2)

| what | result |
|---|---|
| `zig build` (default target) | `0x80000003` STATUS_BREAKPOINT at `zig.exe+0x4016f2`, **no diagnostic at all** |
| `zig build -Dtarget=native-native-msvc -Dcpu=baseline` | `0xC0000005` STATUS_ACCESS_VIOLATION at `zig.exe+0x1d9fd1` |
| ghoztty's own `ghostty-test` (`-Dtest-llvm=false`) | `0xC0000005` at `zig.exe+0xfcb364` |

The offsets differ between the reduction and the full build, so this is a
family of failures in the same backend rather than provably one instruction —
what is common is that the self-hosted backend cannot compile a module that
reaches uucode's generated tables, and that it says nothing on the way down.

## How the reduction was found

Bisected downwards, each step re-measured:

1. `src/main.zig` test root → `src/main_ghostty.zig`'s test block. Removing
   every `_ = @import(...)` from it compiles clean, so the crash is in a
   subsystem, not in the root.
2. Of those imports, `Command.zig`, `font/main.zig`, `apprt.zig`,
   `renderer.zig`, `termio.zig` and `input.zig` each crash alone;
   `pty.zig`, `CommandCore.zig` and `cli.zig` do not.
3. `input.zig` → `input/command.zig` → `input/Binding.zig`. Truncating
   `Binding.zig` just before its first `test` compiles clean.
4. Within its tests, the first crashing one is
   `test "set: parseAndPut typical binding"`; reduced to `Set.put`, then to
   `Trigger.hash()`, then to the single `uucode.get(.case_folding_full, ...)`
   call inside `foldedCodepoint`.
5. Reproduced outside ghoztty with this project.

The generated table's **shape matters**: a `uucode_config.zig` carrying only
the `runtime` table (`case_folding_full`, `is_emoji_presentation`) compiles
clean, and so does one with a second table holding a single plain field. The
crash needs ghoztty's real config — the `buildtime` table with its `wcwidth`,
`grapheme_break_no_control`, `width` and `is_symbol` extensions — which is why
the config file is copied here verbatim rather than trimmed.

## Keeping the config copy honest

`src/uucode_config.zig` here is a byte-for-byte copy of
`src/build/uucode_config.zig`. If that file changes and this one does not, the
reduction stops describing the build it came from;
`test\win32\zig-repro-t476.ps1` compares the two and fails when they drift.
