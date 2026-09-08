//! Why a dial to a machine did not produce a connection, in the vocabulary the
//! USER is answered in (T628) — and the one place each of those sentences is
//! written.
//!
//! Every remote entry point dials: the machine chooser's roster and its open
//! action, `+new-remote-window`, a window's inheriting re-dial, the pooled
//! connection behind the session list, and the per-window reconnect ladder.
//! Until T628 all of them collapsed every failure into "couldn't reach that
//! machine", which is a WRONG ANSWER for two of the three shapes a dial fails
//! in:
//!
//!   - **unreachable** — the box is off, the agent is down, the network is out.
//!     "Is its agent running?" is the right question, and retrying can fix it.
//!   - **unauthorized** — the relay rejected our bearer. The fix is signing in,
//!     not the network (the split T319 drew for the roster), and retrying
//!     cannot sign anyone in.
//!   - **incompatible** — the two ends parsed each other's HELLO and disagreed
//!     about the protocol. The machine is awake, the agent is running and the
//!     network is fine; the only fix is updating one side. Telling the user to
//!     check the network sends them to chase four things that are all healthy,
//!     and the reconnect ladder spends its whole budget on something no attempt
//!     can change.
//!
//! No OS imports and no allocations: every sentence is a comptime string, so
//! this module builds and tests in every lane.
//!
//! ## Why the sentence lives here and not at each call site
//!
//! Because there are eight call sites and they were already three different
//! sentences for the same fact. A wording fixed in one and not the others is
//! how "couldn't reach that machine" survived on the resume path after the open
//! path had learned better.

const std = @import("std");
const testing = std.testing;

/// The three answers a failed dial can carry. Deliberately about the USER's
/// next move rather than about the transport: two different transport errors
/// that lead to the same next move are the same kind here.
pub const Kind = enum {
    /// The machine did not answer, or answered in a way we could not use.
    /// Retrying may fix it.
    unreachable_machine,
    /// The relay refused our bearer. Retrying cannot fix it; signing in can.
    unauthorized,
    /// The two ends disagree about the protocol. Retrying cannot fix it;
    /// updating one side can.
    incompatible,
};

/// Classify a dial error. Anything not specifically recognized is
/// `unreachable_machine`, which is both the honest default (we do not know why
/// the machine is not usable) and the only one of the three whose advice is
/// harmless when it is wrong.
pub fn classify(err: anyerror) Kind {
    return switch (err) {
        // Raised by `tcp_dial.classifyHandshakeError` — and, since T628, by the
        // relay dialer through the same function.
        error.ProtocolIncompatible => .incompatible,
        error.WebSocketUnauthorized => .unauthorized,
        else => .unreachable_machine,
    };
}

/// Can retrying this dial ever succeed without the user doing something first?
/// The reconnect ladder asks exactly this before spending its budget.
pub fn isRetryable(kind: Kind) bool {
    return kind == .unreachable_machine;
}

// =============================================================================
// The sentences
// =============================================================================

/// The one-line hint the machine chooser puts in its footer. Present tense,
/// names the fix, and never asks the user to check something that is already
/// known to be fine.
pub const unreachable_hint = "Couldn't reach that machine \u{2014} is its agent running?";
pub const unauthorized_hint = "Session expired \u{2014} sign in again above.";
pub const incompatible_hint = "That machine runs a different version of Ghoztty \u{2014} update one side.";

pub fn hint(kind: Kind) []const u8 {
    return switch (kind) {
        .unreachable_machine => unreachable_hint,
        .unauthorized => unauthorized_hint,
        .incompatible => incompatible_hint,
    };
}

/// What the CLI says when a `+new-remote-window` dial fails. The endpoint is
/// the caller's to append (it is what makes the message actionable in a script
/// log), so these are the CAUSE half only.
pub const unreachable_cli = "failed to reach";
pub const incompatible_cli = "incompatible Ghoztty version on";

/// The lead used by the CLI/IPC error for `kind`, so a script's log says which
/// of the three happened rather than one sentence for all of them.
pub fn cliLead(kind: Kind) []const u8 {
    return switch (kind) {
        // A rejected bearer reaches the CLI as a sign-in refusal before any
        // dial is attempted, so it never needs a lead of its own here.
        .unreachable_machine, .unauthorized => unreachable_cli,
        .incompatible => incompatible_cli,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "classify: the three shapes, and an unknown error defaults to unreachable" {
    try testing.expectEqual(Kind.incompatible, classify(error.ProtocolIncompatible));
    try testing.expectEqual(Kind.unauthorized, classify(error.WebSocketUnauthorized));
    try testing.expectEqual(Kind.unreachable_machine, classify(error.HandshakeFailed));
    try testing.expectEqual(Kind.unreachable_machine, classify(error.HandshakeTimeout));
    try testing.expectEqual(Kind.unreachable_machine, classify(error.ConnectionRefused));
    try testing.expectEqual(Kind.unreachable_machine, classify(error.OutOfMemory));
}

test "isRetryable: only an unreachable machine is worth another attempt" {
    try testing.expect(isRetryable(.unreachable_machine));
    try testing.expect(!isRetryable(.unauthorized));
    // The whole point of T628: retrying a skew cannot change it, so the ladder
    // must not spend five attempts and ~30s discovering that.
    try testing.expect(!isRetryable(.incompatible));
}

test "hint: every kind has its own sentence, and none of them blames the network wrongly" {
    var seen: [3][]const u8 = undefined;
    var i: usize = 0;
    for ([_]Kind{ .unreachable_machine, .unauthorized, .incompatible }) |k| {
        const h = hint(k);
        try testing.expect(h.len > 0);
        // Distinct: a state that reads identically to another state is the
        // defect this task exists to fix.
        for (seen[0..i]) |prev| try testing.expect(!std.mem.eql(u8, prev, h));
        seen[i] = h;
        i += 1;
    }

    // The two sentences that must NOT send the user to the network say so.
    try testing.expect(std.mem.indexOf(u8, hint(.incompatible), "version") != null);
    try testing.expect(std.mem.indexOf(u8, hint(.incompatible), "agent running") == null);
    try testing.expect(std.mem.indexOf(u8, hint(.unauthorized), "agent running") == null);
    try testing.expect(std.mem.indexOf(u8, hint(.unreachable_machine), "agent running") != null);
}

test "cliLead: a skew is not reported as a failure to reach" {
    try testing.expectEqualStrings(unreachable_cli, cliLead(.unreachable_machine));
    try testing.expectEqualStrings(incompatible_cli, cliLead(.incompatible));
    try testing.expect(!std.mem.eql(u8, cliLead(.unreachable_machine), cliLead(.incompatible)));
}
