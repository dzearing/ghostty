//! The T64 injected-keyboard policy, the pure half (T222).
//!
//! Two decisions sit on the injected-character path, and both lived as bare
//! `if`s — one buried in the message loop, one a third of the way down a long
//! key handler:
//!
//! 1. `App.run` must NOT call TranslateMessage for keys aimed at a terminal
//!    surface: `handleKeyEvent` calls ToUnicode itself, and TranslateMessage's
//!    internal ToUnicodeEx mutates the same per-queue dead-key state (racing it
//!    broke ABNT2 composition). VK_PROCESSKEY (IME) and VK_PACKET (SendInput
//!    with KEYEVENTF_UNICODE — screen readers, on-screen keyboards,
//!    automation) are **exempt**, because translation is the only thing that
//!    turns either into the WM_CHAR that carries its text.
//! 2. `Surface.handleKeyEvent` must not hand either of those synthetic keys to
//!    the terminal as a key, and for a packet must additionally clear the
//!    produced-text flag or the injected WM_CHAR is dropped as a duplicate.
//!
//! Neither is reachable from an automated run: a real
//! `SendInput(KEYEVENTF_UNICODE)` is refused off the input desktop (T207), and
//! a POSTED `WM_KEYDOWN` carrying VK_PACKET is never translated — a real packet
//! carries its 16-bit character out of band and a posted lParam has only the
//! 8-bit scan-code field to put it in (measured; recorded as "MECHANISM LIMIT -
//! VK_PACKET" in `test/win32/lib/TestDesktop.ps1`). So the policy lives here as
//! pure functions asserted in the unit lane, instead of in an `if` that only an
//! interactive by-hand run can reach.
//!
//! No OS imports, so the Win32 values are literals; `App.zig` carries the drift
//! guard that compares each one against the real `w32.*` constant.

const std = @import("std");

pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_SYSKEYDOWN: u32 = 0x0104;
pub const WM_SYSKEYUP: u32 = 0x0105;

pub const VK_PROCESSKEY: u16 = 0xE5;
pub const VK_PACKET: u16 = 0xE7;

/// Whether this is one of the raw key messages the policy has anything to say
/// about. The message loop gates its class-atom syscall on this, so that
/// lookup stays off the path of every mouse move and timer tick; `skipTranslate`
/// answers `false` for anything this rejects, which the unit lane asserts.
pub fn isKeyMessage(message: u32) bool {
    return switch (message) {
        WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP => true,
        else => false,
    };
}

/// Whether `App.run` should SKIP `TranslateMessage` for this message.
///
/// `class_atom` is the window class atom of the message's target window, or 0
/// when the message has no HWND or its class could not be read — the same
/// "unknown" `GetClassLongW(h, GCW_ATOM)` reports, and never a terminal.
pub fn skipTranslate(
    message: u32,
    wparam: usize,
    class_atom: u16,
    terminal_class_atom: u16,
) bool {
    // Everything else — WM_CHAR, mouse, IME composition — is translated
    // normally. Only the raw key messages ever reach ToUnicode twice.
    if (!isKeyMessage(message)) return false;

    // Same low-word read `handleKeyEvent` does, so the two halves of the
    // policy cannot disagree about what the virtual key is.
    const vk: u16 = @truncate(wparam & 0xFFFF);
    if (vk == VK_PROCESSKEY or vk == VK_PACKET) return false;

    return class_atom != 0 and class_atom == terminal_class_atom;
}

/// What `Surface.handleKeyEvent` does with a virtual key before the terminal
/// ever sees it.
pub const KeyDisposition = enum {
    /// An ordinary key: the terminal handles it.
    key,

    /// VK_PROCESSKEY — the IME owns this press and will deliver the composed
    /// text through WM_IME_COMPOSITION. Feeding the key to the terminal as
    /// well would type garbage next to the composition.
    ime_pending,

    /// VK_PACKET — a character injected by SendInput, arriving as its own
    /// WM_CHAR. There is no key here to send.
    injected_text,

    /// Whether the key is dropped rather than handed to the terminal.
    pub fn dropsKey(self: KeyDisposition) bool {
        return self != .key;
    }

    /// Whether the produced-text flag must be cleared first. Under the
    /// translate skip an ordinary key never gets a WM_CHAR of its own, so the
    /// flag is still set from the last text-producing keydown — left alone, it
    /// would swallow the injected character as a duplicate. An IME press must
    /// NOT clear it: its own WM_CHAR suppression is what keeps composition
    /// from double-typing.
    pub fn clearsProducedText(self: KeyDisposition) bool {
        return self == .injected_text;
    }
};

pub fn keyDisposition(vk: u16) KeyDisposition {
    return switch (vk) {
        VK_PROCESSKEY => .ime_pending,
        VK_PACKET => .injected_text,
        else => .key,
    };
}

const testing = std.testing;
const term_atom: u16 = 0xC0DE;

test "T64: an ordinary terminal keydown skips translation" {
    // The rule the whole switch exists for: ToUnicode is called by
    // handleKeyEvent, so TranslateMessage must not run it a second time.
    try testing.expect(skipTranslate(WM_KEYDOWN, 'A', term_atom, term_atom));
    try testing.expect(skipTranslate(WM_KEYUP, 'A', term_atom, term_atom));
    try testing.expect(skipTranslate(WM_SYSKEYDOWN, 0x73, term_atom, term_atom));
    try testing.expect(skipTranslate(WM_SYSKEYUP, 0x73, term_atom, term_atom));
}

test "T64: VK_PACKET is translated even on a terminal surface" {
    // The exemption itself. TranslateMessage is the ONLY thing that turns the
    // packet into the WM_CHAR carrying the injected character, so a skip here
    // makes every screen reader / on-screen keyboard / SendInput Unicode
    // client type nothing at all.
    for ([_]u32{ WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP }) |msg| {
        try testing.expect(!skipTranslate(msg, VK_PACKET, term_atom, term_atom));
    }
}

test "T64: VK_PROCESSKEY is translated even on a terminal surface" {
    // Skipping it made CJK input dead: translation is what forwards the press
    // to the IME and drives the candidate window.
    for ([_]u32{ WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP }) |msg| {
        try testing.expect(!skipTranslate(msg, VK_PROCESSKEY, term_atom, term_atom));
    }
}

test "the exemption reads the low word, as handleKeyEvent does" {
    // A message queue hands wParam as a machine word; the virtual key is its
    // low half. Both halves of the policy must agree on that or a packet is a
    // packet to one of them and an ordinary key to the other.
    try testing.expect(!skipTranslate(WM_KEYDOWN, 0xFFFF0000 | @as(usize, VK_PACKET), term_atom, term_atom));
    try testing.expectEqual(KeyDisposition.injected_text, keyDisposition(VK_PACKET));
}

test "non-terminal windows keep their translation" {
    // Edit controls — search, the command palette, tab rename — need
    // TranslateMessage to get their WM_CHARs at all.
    try testing.expect(!skipTranslate(WM_KEYDOWN, 'A', 0xBEEF, term_atom));
    // No HWND, or a class we could not read: never a terminal.
    try testing.expect(!skipTranslate(WM_KEYDOWN, 'A', 0, term_atom));
}

test "only the raw key messages are ever skipped" {
    // WM_CHAR must always translate-and-dispatch: it is the message the whole
    // injected path is trying to produce.
    try testing.expect(!skipTranslate(0x0102, 'A', term_atom, term_atom)); // WM_CHAR
    try testing.expect(!skipTranslate(0x0201, 0, term_atom, term_atom)); // WM_LBUTTONDOWN
    try testing.expect(!skipTranslate(0x010F, 0, term_atom, term_atom)); // WM_IME_COMPOSITION

    // The message loop skips its class-atom syscall for anything
    // `isKeyMessage` rejects, so a message the policy would answer "skip" for
    // and that gate would filter out is a silent divergence. Sweep the whole
    // documented WM_ range rather than a hand-picked few.
    for (0..0x1000) |m_usize| {
        const m: u32 = @intCast(m_usize);
        if (isKeyMessage(m)) continue;
        try testing.expect(!skipTranslate(m, 'A', term_atom, term_atom));
    }
}

test "T64: a packet drops the key AND clears the produced-text flag" {
    const packet = keyDisposition(VK_PACKET);
    try testing.expectEqual(KeyDisposition.injected_text, packet);
    try testing.expect(packet.dropsKey());
    try testing.expect(packet.clearsProducedText());
}

test "an IME press drops the key and leaves the flag alone" {
    const ime = keyDisposition(VK_PROCESSKEY);
    try testing.expectEqual(KeyDisposition.ime_pending, ime);
    try testing.expect(ime.dropsKey());
    try testing.expect(!ime.clearsProducedText());
}

test "every other virtual key reaches the terminal untouched" {
    for (0..256) |vk_usize| {
        const vk: u16 = @intCast(vk_usize);
        if (vk == VK_PACKET or vk == VK_PROCESSKEY) continue;
        const d = keyDisposition(vk);
        try testing.expectEqual(KeyDisposition.key, d);
        try testing.expect(!d.dropsKey());
        try testing.expect(!d.clearsProducedText());
    }
}
