//! Activity monitor process control: Kill and New Process.
//!
//! Split out of `ActivityMonitor.zig` (T299). Both verbs are the same shape —
//! confirm or collect input in a modal dialog, run the RPC, then re-sample so
//! the table reflects what just happened — and both are the only places in the
//! monitor that MUTATE the machine they are watching, which is why they live
//! together and away from the painter and the connection plane.
//!
//! The dangerous detail here is the nested message pump: a modal dialog pumps
//! messages, so a sample can land and free `self.snap` while a dialog is open.
//! Everything the batch needs is copied out of the snapshot BEFORE the dialog
//! opens (T292) — see `actions.copyNames`.
//!
//! The commentary this file inherited from the panel's header:
//!
//! ## Process control (T286)
//! Kill and New Process run against `remote/agent/proc_control.zig` and
//! `proc_spawn.zig` — the same two functions the agent's remote provider calls,
//! so a local panel and a remote one cannot drift. Both are destructive or
//! creative enough to be MODAL: `ConfirmDialog` / `NewProcessDialog` run a
//! nested pump. That pump dispatches the panel's own posted messages, so
//! sampling and adoption CARRY ON behind an open dialog and the gauges keep
//! advancing — as they do on Mac (T292). What that costs is a copy: the
//! confirmation quotes row names, and a poll landing mid-dialog retires the
//! snapshot they came from, so `actions.copyNames` marshals the batch into a
//! stack arena before the dialog opens. All wording, the failure aggregation,
//! the empty state and the selection pruning are pure in `activity_actions.zig`.

const std = @import("std");

const ActivityMonitor = @import("ActivityMonitor.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const NewProcessDialog = @import("NewProcessDialog.zig");
const actions = @import("activity_actions.zig");
const rows_mod = @import("activity_rows.zig");
const proc_control = @import("../../remote/agent/proc_control.zig");
const proc_spawn = @import("../../remote/agent/proc_spawn.zig");

const log = ActivityMonitor.log;
const max_rows = ActivityMonitor.max_rows;
const rpc_timeout_ns = ActivityMonitor.rpc_timeout_ns;

// ---------------------------------------------------------------------
// Process control (Kill / New Process)
// ---------------------------------------------------------------------

/// UTF-8 → NUL-terminated UTF-16 in `buf`, or null when it does not fit.
pub fn utf16z(buf: []u16, text: []const u8) ?[:0]const u16 {
    if (text.len + 1 > buf.len) return null;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return null;
    buf[n] = 0;
    return buf[0..n :0];
}

/// Kill every selected row, behind a mandatory confirmation
/// (`RemoteActivityMonitorView.swift:940-952` + :762-780).
///
/// The kills run inline on the GUI thread rather than on a worker, unlike Mac's
/// background hop: `killProc` is `OpenProcess` + `TerminateProcess`, two
/// syscalls that do not block, and hopping threads would mean copying the
/// targets to keep them alive across the hop for no gain. What DOES need care is
/// the snapshot: `targetsFor` points each name into `snap`, and the dialog's
/// nested pump adopts samples like any other, so the batch is COPIED out of the
/// snapshot before the dialog opens (T292) — see `actions.copyNames`.
pub fn onKill(self: *ActivityMonitor) void {
    if (self.sel_len == 0) return;
    const snap = self.snap orelse return;

    var target_buf: [max_rows]actions.Target = undefined;
    const targets = actions.targetsFor(self.sel_pids[0..self.sel_len], snap.rows, &target_buf);
    if (targets.len == 0) return;

    // Everything below outlives `snap`: the dialog pumps, a poll lands behind
    // it, and `adoptPending` retires the arena these names point into. Own them.
    var name_arena: [actions.name_arena_bytes]u8 = undefined;
    actions.copyNames(targets, &name_arena);

    var title_utf8: [192]u8 = undefined;
    var title_w: [224]u16 = undefined;
    const title = utf16z(&title_w, actions.killConfirmTitle(&title_utf8, targets)) orelse
        std.unicode.utf8ToUtf16LeStringLiteral("Kill process?");

    var body_w: [256]u16 = undefined;
    const body = utf16z(&body_w, actions.killConfirmBody(targets.len)) orelse
        std.unicode.utf8ToUtf16LeStringLiteral("This terminates the process immediately.");

    var label_utf8: [32]u8 = undefined;
    var label_w: [40]u16 = undefined;
    const ok_label = utf16z(&label_w, actions.killButtonLabel(&label_utf8, targets.len)) orelse
        std.unicode.utf8ToUtf16LeStringLiteral("Kill");

    const choice = ConfirmDialog.show(self.app, self.hwnd, self.scale, self.filter, .{
        .title = title.ptr,
        .text = body,
        .style = .ok_cancel,
        .icon = .warning,
        // MB_DEFBUTTON2: an accidental Enter must never kill anything.
        .default_cancel = true,
        .ok_label = ok_label,
    });

    log.info("activity monitor: kill dialog n={d} choice={s}", .{
        targets.len,
        if (choice == .ok) "ok" else "cancel",
    });
    // Nothing was touched, and any sample that landed behind the dialog was
    // already adopted by its pump — there is nothing deferred to catch up on.
    if (choice != .ok) return;

    var failed_buf: [max_rows]actions.Target = undefined;
    var nfail: usize = 0;
    for (targets) |t| {
        if (!killOne(self, t.pid)) {
            failed_buf[nfail] = t;
            nfail += 1;
        }
    }
    log.info("activity monitor: kill result total={d} killed={d} failed={d}", .{
        targets.len,
        targets.len - nfail,
        nfail,
    });

    var err_utf8: [256]u8 = undefined;
    if (actions.killFailureText(&err_utf8, targets.len, failed_buf[0..nfail])) |text| {
        self.setError(text);
    } else {
        // Mac clears the selection only on a clean sweep (:592-594): rows that
        // survived are still there, and still the ones the user meant.
        self.clearSelection();
        self.clearError();
    }

    // Force a fresh sample so the casualties leave the table without waiting out
    // the poll interval.
    self.refreshChrome();
    self.kickSample();
}

/// Terminate one pid on THIS panel's source, returning whether it died. The
/// local and remote calls are the same request to two transports — the agent
/// answers `PROC_KILL` with the very `proc_control.killProc` the local branch
/// calls in-process — so a local panel and a remote one cannot drift.
pub fn killOne(self: *ActivityMonitor, pid: i64) bool {
    if (self.remote_conn) |rc| {
        var out = rc.conn.killProc(pid, "TERM", rpc_timeout_ns) catch |err| {
            log.warn("activity monitor: remote kill pid={d} err={}", .{ pid, err });
            return false;
        };
        defer out.deinit();
        if (!out.ok) {
            log.warn("activity monitor: remote kill pid={d} failed err={s}", .{
                pid,
                out.error_msg orelse "unknown",
            });
        }
        return out.ok;
    }

    const r = proc_control.killProc(pid, "TERM");
    if (!r.ok) {
        log.warn("activity monitor: kill pid={d} failed err={s}", .{
            pid,
            r.@"error" orelse "unknown",
        });
    }
    return r.ok;
}

/// Start a process on this panel's source (Mac's `NewProcessSheet` +
/// `spawn(cmd:cwd:)`, :781-786 and :603-630).
pub fn onNewProcess(self: *ActivityMonitor) void {
    var cmd_buf: [NewProcessDialog.MAX_VALUE_LEN]u8 = undefined;
    var cwd_buf: [NewProcessDialog.MAX_VALUE_LEN]u8 = undefined;

    // Nothing here borrows the snapshot — the fields are the caller's buffers
    // and `source.label()` is the panel's own identity — so this dialog never
    // needed adoption held off either (T292).
    const res = NewProcessDialog.prompt(
        self.app,
        self.hwnd,
        self.scale,
        self.filter,
        self.source.label(),
        &cmd_buf,
        &cwd_buf,
    );

    const r = res orelse {
        log.info("activity monitor: spawn dialog choice=cancel", .{});
        return;
    };
    // The dialog reports its fields verbatim (the `ConfirmDialog.prompt`
    // contract); trimming is ours.
    const cmd = rows_mod.trim(r.command);
    const cwd = rows_mod.trim(r.working_directory);
    if (cmd.len == 0) return;
    log.info("activity monitor: spawn dialog choice=start cmd=\"{s}\"", .{cmd});

    if (spawnOne(self, cmd, if (cwd.len == 0) null else cwd)) {
        self.clearError();
    } else {
        var err_utf8: [256]u8 = undefined;
        self.setError(actions.spawnFailureText(&err_utf8, cmd));
    }

    self.kickSample();
}

/// Start `cmd` on THIS panel's source, returning whether it started. Remote
/// goes through `PROC_SPAWN`, whose agent-side handler is the same
/// `proc_spawn.spawnDetached` the local branch calls.
pub fn spawnOne(self: *ActivityMonitor, cmd: []const u8, cwd: ?[]const u8) bool {
    const alloc = self.app.core_app.alloc;

    if (self.remote_conn) |rc| {
        var out = rc.conn.spawnProc(cmd, cwd, rpc_timeout_ns) catch |err| {
            log.warn("activity monitor: remote spawn err={}", .{err});
            return false;
        };
        defer out.deinit();
        if (out.ok) {
            log.info("activity monitor: remote spawn ok=true pid={?d}", .{out.pid});
        } else {
            log.warn("activity monitor: remote spawn ok=false err={s}", .{out.error_msg orelse "unknown"});
        }
        return out.ok;
    }

    const out = proc_spawn.spawnDetached(alloc, cmd, cwd);
    // The Windows branch may hand back an ALLOCATED diagnostic note even on
    // success (`SpawnOutcome.free_error`), so this is not a failure-only free.
    defer if (out.free_error) {
        if (out.@"error") |e| alloc.free(e);
    };
    if (out.ok) {
        log.info("activity monitor: spawn result ok=true pid={?d} note={s}", .{
            out.pid,
            out.@"error" orelse "",
        });
    } else {
        log.warn("activity monitor: spawn result ok=false err={s}", .{out.@"error" orelse "unknown"});
    }
    return out.ok;
}
