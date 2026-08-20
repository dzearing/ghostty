//! What a SELECTED ROW looks like in a win32 list, and the one place that
//! answers it (T828, generalized by T1008).
//!
//! Windows 11 marks a list selection with a quiet NEUTRAL fill at two weights
//! plus one small accent indicator bar at the leading edge — never an
//! accent-tinted fill, and never an accent perimeter. The user reported the old
//! treatment on the machine chooser as *"a bright purple pill with a thick
//! purple outline"*, T828 replaced it there, and then the Activity Monitor's
//! process table was found still wearing it: the same kind of surface, a list of
//! selectable rows, disagreeing with the chooser about what "selected" looks
//! like.
//!
//! So the vocabulary lives here rather than inside either painter. It was
//! `chooser_rows.zig`'s, which is why `chooser_rows` re-exports every name below
//! — a module called "chooser rows" is the wrong place for a rule that binds
//! every list on the platform, and a second copy of the weights is how two
//! panels drift apart one wash at a time.
//!
//! Pure: no `win32.zig` import, so it runs in every app-runtime lane. Geometry
//! stays with each list — the chooser's rows are inset pills
//! (`chooser_rows.rowMetrics`), the process table's are full-bleed bands
//! (`activity_layout.rowIndicator`) — because the shape of a row is that list's
//! business and its COLORS are not.
//!
//! Floors, from `docs/design/win32-design-system.md`:
//!   - meaningful marks (the indicator, the focus rim)  >= 3.0:1  (WCAG 1.4.11)

const std = @import("std");

const color_math = @import("color_math.zig");
pub const Rgb = color_math.Rgb;

const chrome_theme = @import("chrome_theme.zig");

/// Hover wash: Mac's `Color.primary.opacity(0.06)`. `Color.primary` is white on
/// a dark surface and BLACK on a light one, so this is `color_math.wash`, not a
/// blend toward a hardcoded white — that literal was the same defect as the tab
/// strip's `background + 20`, one surface further in.
pub const hover_wash: f32 = 0.06;

/// The selection fill is a NEUTRAL wash at two weights (T828), never an accent
/// tint. Ordered against the hover wash so the three list states read as one
/// ramp: hover < unfocused selection < focused selection.
///
/// Why neutral at all: the accent used to be the fill (Mac's 0.25 tint) and the
/// perimeter (0.7), and on a dark system accent the 3:1 chrome floor brightens
/// that accent before it is ever composited — so the row the user picked came
/// out a vivid violet pill with a violet outline, louder than both the Mac
/// original and the Windows 11 list it sits next to. Windows 11 marks a list
/// selection with a subtle neutral fill and puts the accent in a small indicator
/// bar; that is what these weights and `selectionIndicator` are.
pub const selection_wash_unfocused: f32 = 0.10;
pub const selection_wash_focused: f32 = 0.16;

/// Hover fill for a row the pointer is over.
pub fn hoverFill(bg: Rgb) Rgb {
    return color_math.wash(bg, hover_wash);
}

/// Selection fill for the list that HAS keyboard focus.
pub fn selectionFillFocused(bg: Rgb) Rgb {
    return color_math.wash(bg, selection_wash_focused);
}

/// Selection fill for a list that does not have keyboard focus — macOS's
/// `unemphasizedSelectedContentBackgroundColor`, and the "neutral unemphasized"
/// half of §3.2's focus rule.
pub fn selectionFillUnfocused(bg: Rgb) Rgb {
    return color_math.wash(bg, selection_wash_unfocused);
}

/// The selection indicator bar — WinUI's `ListViewItem` accent mark, in the
/// user's accent, floored to the 3:1 chrome boundary against the FILL it sits on
/// (WCAG 1.4.11) rather than against the row background it never touches.
///
/// This is where the accent lives on a selected row, and it is the whole of it:
/// a small capsule instead of a full-perimeter outline plus a tinted fill.
pub fn selectionIndicator(on: Rgb, accent: Rgb) Rgb {
    return chrome_theme.accentOn(on, accent);
}

/// The same bar when the list does NOT hold keyboard focus: neutral, so the
/// accent still means *this control is the one you are driving*. A selection
/// that keeps its accent while the caret is somewhere else tells the user the
/// list has focus when it does not, which is the defect T312's finding 10 names.
/// It keeps the 3:1 chrome floor either way — it is a meaningful mark, not
/// decoration.
pub fn selectionIndicatorUnfocused(on: Rgb) Rgb {
    return color_math.contrastAdjustedTo(
        color_math.wash(on, 0.5),
        on,
        chrome_theme.ui_contrast_target,
    );
}

/// §2.2's focus rim, in the NEUTRAL high-contrast ink Windows draws a focus
/// visual in (WinUI's `FocusStrokeColorOuter`: near-white on a dark surface,
/// near-black on a light one) rather than in the accent.
///
/// The amendment §2.2 carries for list rows (T828): a row already spends the
/// accent on its selection indicator, so an accent rim around the same row is a
/// second accent mark on one control — which is exactly the doubled purple
/// outline that was reported. Neutral also reads on top of ANY accent, which is
/// what a focus visual has to do.
pub fn focusRim(on: Rgb) Rgb {
    return chrome_theme.textOn(on);
}

// ---------------------------------------------------------------------
// Row state (T312)
// ---------------------------------------------------------------------

/// The three questions a row painter has to ask, and they are three, not two.
///
/// `selected` is `ODS_SELECTED`; `focused` is `ODS_FOCUS` — the LIST holds
/// keyboard focus and this is its caret row. Before T312 the chooser's painter
/// read only the first, so a focused-but-unselected row drew nothing at all and
/// a selected row looked identical whether the user was driving the list or had
/// tabbed away. `hovered` is the pointer, tracked by the control itself.
pub const RowState = struct {
    selected: bool = false,
    focused: bool = false,
    hovered: bool = false,
    /// Whether the focus VISUAL should be drawn at all (T828). Windows keeps
    /// focus rectangles hidden until the user navigates by keyboard and then
    /// shows them for the rest of the session — the UI-state mechanism behind
    /// `UISF_HIDEFOCUS`, which an owner-drawn control reads as
    /// `ODS_NOFOCUSRECT`. Clicking a row therefore selects it without painting
    /// a rim around it, exactly as a Windows 11 list behaves.
    ///
    /// Defaults to true: a caller that does not know must show focus, because a
    /// missing focus ring is an accessibility defect (§2.2) and a spurious one
    /// is only noise.
    focus_visible: bool = true,
};

/// Everything a row's selection draws, resolved together — the same argument
/// `chrome_theme.Palette` makes: these colors are only correct relative to each
/// other (the rim's floor is taken against the fill it lands on, not against the
/// row background it never touches).
pub const RowPaint = struct {
    /// The row's fill. Null means the row paints none. Always a neutral wash
    /// since T828 — the fill has no outline of its own, so a painter that draws
    /// it as a rounded rect pens the shape with this same color.
    fill: ?Rgb = null,
    /// The leading-edge selection indicator bar (T828). Null means the row is
    /// not selected; this is the only place a row's accent appears.
    indicator: ?Rgb = null,
    /// §2.2's focus rim, drawn INSIDE the fill in neutral ink. Null when the
    /// list does not hold keyboard focus, or when Windows is hiding focus
    /// visuals because the user is driving with the pointer.
    ring: ?Rgb = null,
};

/// Resolve a row's selection paint from its state. `accent` is the user's,
/// already floored against `bg` by the caller (`chrome_theme.accentOn`), exactly
/// as the chooser's rows have taken it since T305.
pub fn rowPaint(bg: Rgb, accent: Rgb, st: RowState) RowPaint {
    var p: RowPaint = .{};

    if (st.selected) {
        // Neutral fill at two weights, and the accent spent on the indicator —
        // Windows 11's list selection, not Mac's tinted pill (T828).
        p.fill = if (st.focused) selectionFillFocused(bg) else selectionFillUnfocused(bg);
        const on = p.fill.?;
        p.indicator = if (st.focused)
            selectionIndicator(on, accent)
        else
            selectionIndicatorUnfocused(on);
    } else if (st.hovered) {
        // §2.2: hover is a fill, and only a fill. An outline here would make a
        // pointer passing over the list read as a second selection.
        p.fill = hoverFill(bg);
    }

    if (st.focused and st.focus_visible) {
        // Floored against what the rim actually sits on — the fill when there is
        // one, the row background when there is not.
        p.ring = focusRim(p.fill orelse bg);
    }

    return p;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(
        color_math.wcagLuminance(a),
        color_math.wcagLuminance(b),
    );
}

test "the three selection weights are one ramp, and none of them is a tint (T828)" {
    const bg: Rgb = .{ .r = 32, .g = 32, .b = 32 };
    const hov = hoverFill(bg);
    const unfocused = selectionFillUnfocused(bg);
    const focused = selectionFillFocused(bg);

    // hover < unfocused selection < focused selection, and every one of them
    // is a lift off the row rather than nothing.
    try testing.expect(hov.r > bg.r);
    try testing.expect(unfocused.r > hov.r);
    try testing.expect(focused.r > unfocused.r);

    // Neutral: a wash on a neutral surface stays neutral. A selected row that
    // came out tinted is the defect T828 reported.
    try testing.expectEqual(focused.r, focused.b);
    try testing.expectEqual(unfocused.r, unfocused.b);
}

test "selectionFillUnfocused: neutral, and it follows the surface's direction" {
    const dark: Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 };
    const light: Rgb = .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 };
    // Lifts on a dark surface, darkens on a light one — `wash`, not a blend
    // toward a hardcoded white.
    try testing.expect(selectionFillUnfocused(dark).r > dark.r);
    try testing.expect(selectionFillUnfocused(light).r < light.r);
    // Stronger than hover, weaker than the focused selection carries.
    try testing.expect(ratio(selectionFillUnfocused(dark), dark) > ratio(hoverFill(dark), dark));
    try testing.expect(ratio(selectionFillFocused(dark), dark) > ratio(selectionFillUnfocused(dark), dark));
    // Neutral: a wash, never a tint that could be mistaken for the accent.
    const u = selectionFillUnfocused(.{ .r = 0x1E, .g = 0x1E, .b = 0x2E });
    try testing.expect(u.b > u.r);
    try testing.expectEqual(u.r, u.g);
}

test "rowPaint: the three list states are mutually distinguishable (T312)" {
    // Finding 10: a selected row drew the same fill whether the list had
    // keyboard focus or not, so Tabbing onto the list gave no feedback at all.
    // These three must differ from each other AND from the bare row.
    for ([_]Rgb{
        .{ .r = 0x20, .g = 0x20, .b = 0x20 },
        .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 },
        .{ .r = 0x1E, .g = 0x1E, .b = 0x2E },
    }) |bg| {
        for ([_]Rgb{
            .{ .r = 0x68, .g = 0x00, .b = 0x81 },
            chrome_theme.default_accent,
        }) |raw| {
            const accent = chrome_theme.accentOn(bg, raw);

            const sel_focus = rowPaint(bg, accent, .{ .selected = true, .focused = true });
            const sel_only = rowPaint(bg, accent, .{ .selected = true });
            const hover = rowPaint(bg, accent, .{ .hovered = true });
            const rest = rowPaint(bg, accent, .{});

            // A resting row paints nothing — the fill is state, not decoration.
            try testing.expect(rest.fill == null and rest.indicator == null and rest.ring == null);

            // Three fills, three different colors.
            try testing.expect(!sel_focus.fill.?.eql(sel_only.fill.?));
            try testing.expect(!sel_only.fill.?.eql(hover.fill.?));
            try testing.expect(!sel_focus.fill.?.eql(hover.fill.?));
            for ([_]Rgb{ sel_focus.fill.?, sel_only.fill.?, hover.fill.? }) |f| {
                try testing.expect(!f.eql(bg));
            }

            // Ordered by weight: hover is the lightest touch, the focused
            // selection the heaviest.
            try testing.expect(ratio(hover.fill.?, bg) < ratio(sel_only.fill.?, bg));

            // NO fill carries the accent any more (T828) — it is a neutral wash
            // whichever accent the user picked, and the accent lives in the
            // indicator bar instead.
            const other = chrome_theme.accentOn(bg, .{ .r = 0xFF, .g = 0xF0, .b = 0x00 });
            try testing.expect(sel_only.fill.?.eql(
                rowPaint(bg, other, .{ .selected = true }).fill.?,
            ));
            try testing.expect(sel_focus.fill.?.eql(
                rowPaint(bg, other, .{ .selected = true, .focused = true }).fill.?,
            ));

            // ...and the FOCUSED indicator is the one that tracks it, so the
            // user's color is still what says "you are driving this list".
            try testing.expect(!sel_focus.indicator.?.eql(
                rowPaint(bg, other, .{ .selected = true, .focused = true }).indicator.?,
            ));
            try testing.expect(sel_only.indicator.?.eql(
                rowPaint(bg, other, .{ .selected = true }).indicator.?,
            ));

            // Every meaningful mark clears the 3:1 chrome floor against the
            // surface it actually sits on (WCAG 1.4.11).
            try testing.expect(ratio(sel_focus.ring.?, sel_focus.fill.?) >= 2.95);
            try testing.expect(ratio(sel_focus.indicator.?, sel_focus.fill.?) >= 2.95);
            try testing.expect(ratio(sel_only.indicator.?, sel_only.fill.?) >= 2.95);

            // §2.2: hover is a fill and only a fill; a mark here would read as a
            // second selection following the pointer.
            try testing.expect(hover.indicator == null and hover.ring == null);

            // Selection is never fill alone: a bar marks it in both states, so
            // it survives a color-blind reading and a low-contrast accent.
            try testing.expect(sel_only.indicator != null and sel_focus.indicator != null);
        }
    }
}

test "rowPaint: a focused row is visible even when it is not selected (T312)" {
    // The other half of finding 10, and the one that was literally invisible:
    // the caret row with no selection drew nothing whatsoever.
    const bg: Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 };
    const accent = chrome_theme.accentOn(bg, .{ .r = 0x68, .g = 0x00, .b = 0x81 });

    const p = rowPaint(bg, accent, .{ .focused = true });
    try testing.expect(p.ring != null);
    // Drawn straight onto the row background, so that is what it is floored
    // against — not against a fill that is not there.
    try testing.expect(p.fill == null);
    try testing.expect(ratio(p.ring.?, bg) >= 2.95);

    // And a focused row that is also hovered keeps the hover fill under it.
    const h = rowPaint(bg, accent, .{ .focused = true, .hovered = true });
    try testing.expect(h.fill.?.eql(hoverFill(bg)));
    try testing.expect(ratio(h.ring.?, h.fill.?) >= 2.95);
}

test "rowPaint: clicking a row selects it without painting a focus rim (T828)" {
    // Windows hides focus visuals until the user navigates by keyboard
    // (`UISF_HIDEFOCUS` -> `ODS_NOFOCUSRECT`). A row picked with the mouse
    // therefore shows the quiet selection and nothing else — the rim appearing
    // on a click is half of what read as "a thick outline".
    const bg: Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 };
    const accent = chrome_theme.accentOn(bg, .{ .r = 0x68, .g = 0x00, .b = 0x81 });

    const mouse = rowPaint(bg, accent, .{ .selected = true, .focused = true, .focus_visible = false });
    try testing.expect(mouse.ring == null);
    // ...but it is still unmistakably the selected row.
    try testing.expect(mouse.fill.?.eql(selectionFillFocused(bg)));
    try testing.expect(mouse.indicator != null);
    try testing.expect(ratio(mouse.indicator.?, mouse.fill.?) >= 2.95);

    // Keyboard focus then brings the rim back, on the same selection.
    const kbd = rowPaint(bg, accent, .{ .selected = true, .focused = true });
    try testing.expect(kbd.ring != null);
    try testing.expect(kbd.fill.?.eql(mouse.fill.?));

    // The default is "show it": a caller that never learned the UI state must
    // not silently drop the focus indicator (§2.2).
    const st: RowState = .{ .focused = true };
    try testing.expect(st.focus_visible);
}

test "focusRim: neutral ink, never the accent (T828)" {
    // The §2.2 amendment for list rows: the accent is already spent on the
    // indicator bar, so the rim is a focus VISUAL in Windows' own neutral ink.
    for ([_]Rgb{
        .{ .r = 0x20, .g = 0x20, .b = 0x20 },
        .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 },
        .{ .r = 0x1E, .g = 0x1E, .b = 0x2E },
    }) |bg| {
        const purple: Rgb = .{ .r = 0x68, .g = 0x00, .b = 0x81 };
        const accent = chrome_theme.accentOn(bg, purple);
        const rim = focusRim(bg);
        try testing.expect(!rim.eql(accent));
        // Independent of whatever accent the user picked...
        try testing.expect(rim.eql(focusRim(bg)));
        // ...and it reads: a focus visual is a meaningful boundary (WCAG
        // 1.4.11), so it clears the chrome floor with room to spare.
        try testing.expect(ratio(rim, bg) >= 4.4);
    }
}

test "rowPaint: every floor holds across the background x accent space (T312)" {
    // The sweep, for the same reason `chrome_theme`'s exists: one hand-picked
    // pair is exactly how a fixed color survives a review.
    const accents = [_]Rgb{
        .{ .r = 0x68, .g = 0x00, .b = 0x81 },
        chrome_theme.default_accent,
        .{ .r = 0x00, .g = 0x00, .b = 0x00 },
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .{ .r = 0xFF, .g = 0xF0, .b = 0x00 },
    };
    var v: u16 = 0;
    while (v <= 255) : (v += 8) {
        const c: u8 = @intCast(v);
        for ([_]Rgb{
            .{ .r = c, .g = c, .b = c },
            .{ .r = c, .g = @intCast(255 - v), .b = 0x40 },
            .{ .r = 0x20, .g = c, .b = @intCast(255 - v) },
        }) |bg| {
            for (accents) |raw| {
                const accent = chrome_theme.accentOn(bg, raw);
                const sf = rowPaint(bg, accent, .{ .selected = true, .focused = true });
                const so = rowPaint(bg, accent, .{ .selected = true });
                const fo = rowPaint(bg, accent, .{ .focused = true });

                try testing.expect(ratio(sf.ring.?, sf.fill.?) >= 2.95);
                try testing.expect(ratio(fo.ring.?, bg) >= 2.95);
                try testing.expect(ratio(sf.indicator.?, sf.fill.?) >= 2.95);
                try testing.expect(ratio(so.indicator.?, so.fill.?) >= 2.95);
                // The two selections never collapse onto each other, on any
                // background — including the light end, where a wash that
                // headed for white unconditionally would.
                try testing.expect(!sf.fill.?.eql(so.fill.?));
                try testing.expect(!so.fill.?.eql(bg));
            }
        }
    }
}
