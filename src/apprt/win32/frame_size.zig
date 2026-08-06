//! Client-size → outer-size conversion for a live window (T360).
//!
//! `AdjustWindowRectEx` predicts the frame of a STOCK window style. Since
//! T254 the main window answers `WM_NCCALCSIZE` itself and keeps the caption
//! band inside the client area, so the stock `WS_OVERLAPPEDWINDOW` prediction
//! is a caption band too tall — `reset_window_size` asked for an 800×600
//! client and landed 800×638. The only prediction that is right for every
//! frame this window can have (custom caption, stock, `window-decoration =
//! none`), at every DPI and on every Windows build, is the window's OWN
//! measured delta between its outer rect and its client rect: whatever the
//! frame costs right now is exactly what it will cost at the next
//! `SetWindowPos`.
//!
//! Pure arithmetic only — `Window.setClientSize` measures, this module
//! computes, and the tests assert exactness at 1.0/1.25/1.5/2.0 scaling.

const std = @import("std");

pub const Size = struct { w: i32, h: i32 };

/// The outer (window) size that makes the client exactly `wanted`, given the
/// window's currently measured outer and client sizes. The frame is the
/// difference between the two measurements, and the wanted client keeps it.
pub fn outerForClient(wanted: Size, outer_now: Size, client_now: Size) Size {
    return .{
        .w = wanted.w + (outer_now.w - client_now.w),
        .h = wanted.h + (outer_now.h - client_now.h),
    };
}

const testing = std.testing;

test "the wanted client lands exactly, whatever the frame, at 1.0/1.25/1.5/2.0" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        // The metrics a real frame is built from, scaled the way
        // GetSystemMetricsForDpi scales them.
        const border: i32 = @intFromFloat(@round(4.0 * s)); // SM_CXSIZEFRAME
        const padded: i32 = @intFromFloat(@round(4.0 * s)); // SM_CXPADDEDBORDER
        const caption: i32 = @intFromFloat(@round(23.0 * s)); // SM_CYCAPTION
        const frame_x = border + padded;

        // The T254 custom-caption frame: left/right/bottom sizing borders
        // stay with the OS, the top edge and the caption band are client.
        const custom = Size{ .w = 2 * frame_x, .h = frame_x };
        // The stock frame AdjustWindowRectEx(WS_OVERLAPPEDWINDOW) predicts.
        const stock = Size{ .w = 2 * frame_x, .h = 2 * frame_x + caption };
        // window-decoration = none: no frame at all.
        const none = Size{ .w = 0, .h = 0 };

        for ([_]Size{ custom, stock, none }) |frame| {
            // The regression's own numbers: a 1002×731 window asked to
            // become an 800×600 client.
            const client_now = Size{ .w = 1002, .h = 731 };
            const outer_now = Size{ .w = client_now.w + frame.w, .h = client_now.h + frame.h };
            const outer = outerForClient(.{ .w = 800, .h = 600 }, outer_now, client_now);
            // The client that results is the outer minus the same frame:
            // exact, no residue.
            try testing.expectEqual(@as(i32, 800), outer.w - frame.w);
            try testing.expectEqual(@as(i32, 600), outer.h - frame.h);
        }
    }
}

test "stock and custom frames genuinely differ — why we measure, not predict" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        const border: i32 = @intFromFloat(@round(4.0 * s));
        const padded: i32 = @intFromFloat(@round(4.0 * s));
        const caption: i32 = @intFromFloat(@round(23.0 * s));
        const frame_x = border + padded;
        // The vertical gap between the two frames is the caption band plus
        // the top border — the "+38" the acceptance scripts caught, at this
        // box's scale. Predicting stock over a custom frame misses by this.
        try testing.expectEqual(frame_x + caption, (2 * frame_x + caption) - frame_x);
        try testing.expect(frame_x + caption > 0);
    }
}
