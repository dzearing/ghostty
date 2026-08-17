//! The sliver of RichEdit's Text Object Model the composer needs (T644):
//! `ITextDocument.Undo(tomSuspend / tomResume)`.
//!
//! ## Why it exists
//!
//! RichEdit records every `EM_SETCHARFORMAT` / `EM_SETPARAFORMAT` as an
//! undoable action. The composer formats programmatically all the time —
//! `ensurePlainAtCaret` before every keystroke, the quote wash sweep after
//! every insert — so the undo stack filled with records that change no text,
//! and Ctrl+Z popped those instead of the user's edit (one press per
//! character, looking dead). The message API has no "don't record this"
//! flag; the TOM does: `Undo(tomSuspend)` turns the recorder off,
//! `Undo(tomResume)` turns it back on, and neither touches the records
//! already on the stack.
//!
//! ## Shape
//!
//! `ITextDocument` reaches us through `EM_GETOLEINTERFACE` (an `IUnknown`
//! out-param) plus a `QueryInterface` — RichEdit implements the object, we
//! only call it, so unlike `com.zig`'s callbacks there is nothing to
//! implement here, just the vtable layout to get right. It is a dual
//! interface: three `IUnknown` slots, four `IDispatch` slots, then the
//! document's own methods in tom.h order. Only `Undo` is typed; every slot
//! before it exists to make `Undo` land at slot 22, and the layout test
//! below is what keeps that arithmetic honest.
const std = @import("std");
const w32 = @import("win32.zig");
const com = @import("com.zig");

/// tom.h's magic longs. `tomFalse`/`tomTrue` are the ones NOT to confuse
/// these with: `Undo(tomFalse)` CLEARS the stack, which is the opposite of
/// what suspending wants.
pub const tomSuspend: i32 = -9999995;
pub const tomResume: i32 = -9999994;

/// {8CC497C0-A1DF-11CE-8098-00AA0047BE5D}
pub const IID_ITextDocument: com.GUID = .{
    .Data1 = 0x8CC497C0,
    .Data2 = 0xA1DF,
    .Data3 = 0x11CE,
    .Data4 = .{ 0x80, 0x98, 0x00, 0xAA, 0x00, 0x47, 0xBE, 0x5D },
};

/// The three slots every COM interface starts with — the shape
/// `EM_GETOLEINTERFACE` hands back before we ask it for anything better.
pub const IUnknown = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IUnknown, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };
};

pub const ITextDocument = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ITextDocument) callconv(.winapi) u32,
        // IDispatch — never called from here, present only for their slots.
        GetTypeInfoCount: *const anyopaque,
        GetTypeInfo: *const anyopaque,
        GetIDsOfNames: *const anyopaque,
        Invoke: *const anyopaque,
        // ITextDocument, in tom.h order.
        GetName: *const anyopaque,
        GetSelection: *const anyopaque,
        GetStoryCount: *const anyopaque,
        GetStoryRanges: *const anyopaque,
        GetSaved: *const anyopaque,
        SetSaved: *const anyopaque,
        GetDefaultTabStop: *const anyopaque,
        SetDefaultTabStop: *const anyopaque,
        New: *const anyopaque,
        Open: *const anyopaque,
        Save: *const anyopaque,
        Freeze: *const anyopaque,
        Unfreeze: *const anyopaque,
        BeginEditCollection: *const anyopaque,
        EndEditCollection: *const anyopaque,
        Undo: *const fn (*ITextDocument, i32, ?*i32) callconv(.winapi) com.HRESULT,
        Redo: *const anyopaque,
        Range: *const anyopaque,
        RangeFromPoint: *const anyopaque,
    };

    /// Turn the undo recorder off. True when it actually suspended — the
    /// caller pairs every true with a `resumeUndo`, and a false means the
    /// formatting simply stays undoable, which is the pre-T644 behaviour
    /// rather than a failure.
    pub fn suspendUndo(self: *ITextDocument) bool {
        return !com.failed(self.vtable.Undo(self, tomSuspend, null));
    }

    pub fn resumeUndo(self: *ITextDocument) void {
        _ = self.vtable.Undo(self, tomResume, null);
    }

    pub fn release(self: *ITextDocument) void {
        _ = self.vtable.Release(self);
    }
};

/// The control's `ITextDocument`, or null on a RichEdit too old to have one
/// (Msftedit always does; the null path is honesty, not an expected branch).
/// The caller owns the reference and releases it when the control goes.
pub fn fromEdit(edit: w32.HWND) ?*ITextDocument {
    var unk: ?*IUnknown = null;
    if (w32.SendMessageW(edit, w32.EM_GETOLEINTERFACE, 0, @bitCast(@intFromPtr(&unk))) == 0)
        return null;
    const u = unk orelse return null;
    // The intermediate reference goes regardless of whether the QI answers.
    defer _ = u.vtable.Release(u);
    var out: ?*anyopaque = null;
    if (com.failed(u.vtable.QueryInterface(u, &IID_ITextDocument, &out))) return null;
    return @ptrCast(@alignCast(out orelse return null));
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "the vtable pointer is the first field" {
    // The only part of the layout COM dereferences from our side; see
    // com.zig rule 1.
    try testing.expectEqual(@as(usize, 0), @offsetOf(IUnknown, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ITextDocument, "vtable"));
}

test "Undo sits at slot 22, where tom.h puts it" {
    // 3 IUnknown + 4 IDispatch + 15 document methods before it. A padding
    // slot dropped or doubled above would call some OTHER method in
    // RichEdit with Undo's arguments, so the arithmetic is pinned here.
    try testing.expectEqual(22 * @sizeOf(usize), @offsetOf(ITextDocument.Vtbl, "Undo"));
    try testing.expectEqual(2 * @sizeOf(usize), @offsetOf(ITextDocument.Vtbl, "Release"));
    // 22 slots before Undo, then Undo/Redo/Range/RangeFromPoint = 26 total.
    try testing.expectEqual(
        26 * @sizeOf(usize),
        @sizeOf(ITextDocument.Vtbl),
    );
}

test "the suspend/resume longs are tom.h's, and not the stack-clearing ones" {
    // tomFalse (0) clears the stack; tomTrue (-1) re-enables after a clear.
    // The pair below only pauses the recorder — mixing them up is the
    // difference between "formatting is not undoable" and "undo is gone".
    try testing.expectEqual(@as(i32, -9999995), tomSuspend);
    try testing.expectEqual(@as(i32, -9999994), tomResume);
    try testing.expect(tomSuspend != 0 and tomResume != -1);
}
