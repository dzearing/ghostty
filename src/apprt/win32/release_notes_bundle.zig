//! The bundled release notes as they reach the running app (T624).
//!
//! `release_notes_data` is generated at build time by
//! `src/build/GhosttyReleaseNotes.zig`, which enumerates
//! `release-notes/{client,agent}/*.json` and `@embedFile`s each one. This is
//! the one-line bridge from that generated module to `release_notes.Entry`,
//! kept out of `release_notes.zig` so the parser stays pure and its unit
//! tests run in every lane on literals rather than on whatever the repo
//! happens to hold today.
//!
//! macOS reads these from `Contents/Resources/ghostty/release-notes/` at
//! runtime; a Windows exe has no Resources directory and the portable ZIP is
//! a flat folder, so the equivalent of "inside the app bundle" here is
//! "inside the exe" — the call `GhosttyAssets.zig` already made for the
//! skill and hook assets.

const data = @import("release_notes_data");
const release_notes = @import("release_notes.zig");

const Entry = release_notes.Entry;

/// The generated module declares its own structurally identical `Entry`, so
/// the two are distinct nominal types to Zig and the arrays are re-formed
/// here at comptime. That is the whole cost of keeping the generator free of
/// any dependency on this source tree's module graph.
fn convert(comptime src: anytype) [src.len]Entry {
    var out: [src.len]Entry = undefined;
    for (src, 0..) |e, i| out[i] = .{ .version = e.version, .json = e.json };
    const frozen = out;
    return frozen;
}

const client_entries = convert(data.client);
const agent_entries = convert(data.agent);

/// App/UI/viewer/banner news — Mac's `clientNotesDirectory`.
pub const client: []const Entry = &client_entries;

/// Session-persistence / background-agent news — Mac's
/// `agentNotesDirectory`.
pub const agent: []const Entry = &agent_entries;
