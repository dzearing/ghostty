//! The COM primitives the win32 apprt implements *from our side of the ABI*:
//! the IIDs, the HRESULT helpers, and — the reason this file exists — one
//! generic **callback object** (T376).
//!
//! ## Why a generic
//!
//! WebView2 hands every asynchronous answer back through a COM object that
//! *we* implement: create-completed, navigation-completed, new-window-
//! requested, accelerator-key-pressed, web-message-received. Each one is a
//! vtable of `QueryInterface` / `AddRef` / `Release` / `Invoke` where only
//! `Invoke` differs — the other three are the same forty lines of interface
//! matching and reference counting, and a reference count that is subtly
//! wrong in the fourth copy is a use-after-free with no symptom near the
//! typo.
//!
//! T372 shipped exactly one of them by hand and filed this task before the
//! second existed, which is the same argument T257 made for hoisting the
//! chrome datum: four copies mean four chances to be wrong and no way to
//! notice. `Callback` is that one implementation; a new handler is now its
//! `Invoke` body and nothing else.
//!
//! ## The three rules it encodes
//!
//! 1. **The vtable pointer is the first field.** It is the only part of the
//!    object COM ever dereferences, so the type is an `extern struct` — the
//!    default layout is free to reorder fields, and a reordered vtable
//!    pointer is an immediate crash in someone else's process.
//! 2. **The object owns itself.** It is born with one reference (the
//!    creator's), the runtime takes its own if it keeps it, and the object
//!    frees itself when the count reaches zero. The allocator it frees
//!    through is the one it was created with, carried as its two words
//!    because `std.mem.Allocator` is not extern-compatible.
//! 3. **`QueryInterface` answers for `IUnknown` and for its own IID, and
//!    nothing else.** Every handler interface is a distinct IID; answering
//!    for another one is how a caller ends up holding a pointer whose
//!    `Invoke` has a different signature.
//!
//! Scope: this module knows nothing about WebView2. It imports only `std`,
//! so it stays checkable next to the pure geometry modules rather than
//! needing an OS surface to compile.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GUID = std.os.windows.GUID;
pub const HRESULT = std.os.windows.HRESULT;

pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x8000_4002));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x8000_4003));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x8000_4005));

/// COM's own success test: the sign bit, not equality with `S_OK`. A method
/// that returns `S_FALSE` (1) succeeded.
pub fn failed(hr: HRESULT) bool {
    return hr < 0;
}

pub const IID_IUnknown: GUID = .{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

pub fn guidEql(a: *const GUID, b: *const GUID) bool {
    return a.Data1 == b.Data1 and a.Data2 == b.Data2 and
        a.Data3 == b.Data3 and std.mem.eql(u8, &a.Data4, &b.Data4);
}

/// A COM callback object we implement and hand to a runtime.
///
/// `impl` is the whole of a handler: a plain Zig function taking the context
/// pointer and the interface's two `Invoke` parameters, returning `HRESULT`.
/// Its signature IS the interface's — the vtable slot, the context type and
/// the argument types are all read back off it, so the declaration cannot
/// disagree with the implementation:
///
/// ```zig
/// const ControllerCompleted = com.Callback(IID_ControllerCompleted, onController);
///
/// fn onController(pane: *ViewerPane, hr: HRESULT, c: ?*ICoreWebView2Controller) HRESULT {
///     ...
///     return com.S_OK;
/// }
/// ```
///
/// **One or two `Invoke` parameters.** Almost every WebView2 handler
/// interface has two — `(HRESULT, result)` for the create-completed pair,
/// `(sender, args)` for the events — and the arity is read off `impl`, so a
/// handler cannot be declared with one shape and implemented with another.
/// `ICoreWebView2CapturePreviewCompletedHandler` is the one-parameter case
/// (`Invoke(HRESULT)`, nothing to hand back — the bytes went into the caller's
/// stream), and T397 is why this is not pinned at two any more.
///
/// Threading: the reference count is atomic. WebView2 invokes handlers on
/// the thread that created the environment (ours), but a COM object that has
/// been handed across an apartment boundary can be `AddRef`ed from the
/// proxy's thread, and this is now the ONE implementation — paying for the
/// interlocked op once here is cheaper than reasoning about it per handler.
pub fn Callback(comptime iid: GUID, comptime impl: anytype) type {
    return CallbackOwning(iid, impl, {});
}

/// `Callback`, plus a hook that runs when the LAST reference is dropped —
/// immediately before the object frees itself, and only ever once.
///
/// It exists because of an ownership question a one-shot completed-handler
/// never has to answer. A completed handler is invoked once and released; an
/// EVENT handler is registered on a web view and lives as long as the runtime
/// keeps it, which is not a moment our code can name. So a handler whose
/// context is refcounted (T373's `Pending` token, shared by every hop and
/// nulled when the pane dies) cannot have that reference dropped by the pane:
/// the runtime might still invoke the handler afterwards and read a freed
/// token. The reference has to die WITH the object that borrowed it, and this
/// is the only place that can be.
///
/// Pass `{}` for none, which is what `Callback` does.
pub fn CallbackOwning(
    comptime iid: GUID,
    comptime impl: anytype,
    comptime on_zero: anytype,
) type {
    const fn_info = switch (@typeInfo(@TypeOf(impl))) {
        .@"fn" => |f| f,
        else => @compileError("com.Callback needs a function: fn (*Ctx, A0, A1) HRESULT"),
    };
    if (fn_info.params.len != 2 and fn_info.params.len != 3) @compileError(
        "com.Callback's implementation takes a context pointer plus the " ++
            "interface's ONE or TWO Invoke parameters: fn (*Ctx, A0[, A1]) HRESULT",
    );
    if (fn_info.return_type != HRESULT) @compileError(
        "com.Callback's implementation must return HRESULT",
    );
    const CtxPtr = fn_info.params[0].type.?;
    switch (@typeInfo(CtxPtr)) {
        .pointer => |p| if (p.size != .one) @compileError(
            "com.Callback's first parameter must be a single-item context pointer",
        ),
        else => @compileError("com.Callback's first parameter must be a context pointer"),
    }
    // How many parameters the interface's `Invoke` takes, context aside.
    const arity = fn_info.params.len - 1;
    const A0 = fn_info.params[1].type.?;
    const A1 = if (arity == 2) fn_info.params[2].type.? else void;

    return extern struct {
        const Self = @This();

        /// Must stay first: see rule 1 in this file's header.
        vtable: *const Vtbl,
        refs: i32,
        ctx: CtxPtr,
        /// `std.mem.Allocator` cannot be a field of an `extern struct`, so
        /// the interface is carried as its two words and rebuilt in
        /// `allocator()`. Storing it at all is what lets an object free
        /// itself without reaching into its context for an allocator the
        /// context may not have.
        alloc_ptr: *anyopaque,
        alloc_vtable: *const Allocator.VTable,

        /// The interface this object answers for, alongside `IUnknown`.
        pub const IID: GUID = iid;
        pub const Ctx = @typeInfo(CtxPtr).pointer.child;

        pub const Vtbl = extern struct {
            QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*Self) callconv(.winapi) u32,
            Release: *const fn (*Self) callconv(.winapi) u32,
            Invoke: if (arity == 1)
                *const fn (*Self, A0) callconv(.winapi) HRESULT
            else
                *const fn (*Self, A0, A1) callconv(.winapi) HRESULT,
        };

        const vtable_impl: Vtbl = .{
            .QueryInterface = comQueryInterface,
            .AddRef = comAddRef,
            .Release = comRelease,
            .Invoke = if (arity == 1) comInvoke1 else comInvoke2,
        };

        /// Create with a reference count of 1 — the reference the caller
        /// owns and must drop once the runtime has had its chance to take
        /// its own.
        pub fn create(alloc: Allocator, ctx: CtxPtr) Allocator.Error!*Self {
            const self = try alloc.create(Self);
            self.* = .{
                .vtable = &vtable_impl,
                .refs = 1,
                .ctx = ctx,
                .alloc_ptr = alloc.ptr,
                .alloc_vtable = alloc.vtable,
            };
            return self;
        }

        pub fn allocator(self: *Self) Allocator {
            return .{ .ptr = self.alloc_ptr, .vtable = self.alloc_vtable };
        }

        /// Plain-Zig wrappers, so our own code never has to spell
        /// `x.vtable.Release(x)`. The vtable slots stay the oracle in tests.
        pub fn addRef(self: *Self) void {
            _ = comAddRef(self);
        }

        pub fn release(self: *Self) void {
            _ = comRelease(self);
        }

        fn comQueryInterface(
            self: *Self,
            riid: *const GUID,
            out: *?*anyopaque,
        ) callconv(.winapi) HRESULT {
            if (guidEql(riid, &IID_IUnknown) or guidEql(riid, &IID)) {
                _ = comAddRef(self);
                out.* = @ptrCast(self);
                return S_OK;
            }
            out.* = null;
            return E_NOINTERFACE;
        }

        fn comAddRef(self: *Self) callconv(.winapi) u32 {
            const prev = @atomicRmw(i32, &self.refs, .Add, 1, .monotonic);
            return @intCast(prev + 1);
        }

        fn comRelease(self: *Self) callconv(.winapi) u32 {
            // `acq_rel` so the freeing thread sees every write the other
            // references made before they were dropped.
            const prev = @atomicRmw(i32, &self.refs, .Sub, 1, .acq_rel);
            const remaining = prev - 1;
            if (remaining <= 0) {
                // Before the free, and inside the branch that can only be
                // taken once: whatever this object borrowed goes back here.
                if (@TypeOf(on_zero) != void) on_zero(self.ctx);
                const alloc = self.allocator();
                alloc.destroy(self);
                return 0;
            }
            return @intCast(remaining);
        }

        // Only the arity the implementation actually has is referenced by
        // `vtable_impl`, and Zig analyzes a function only when something
        // reaches it — so the other one never has to typecheck.
        fn comInvoke1(self: *Self, a0: A0) callconv(.winapi) HRESULT {
            return impl(self.ctx, a0);
        }

        fn comInvoke2(self: *Self, a0: A0, a1: A1) callconv(.winapi) HRESULT {
            return impl(self.ctx, a0, a1);
        }
    };
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

/// A stand-in for the two shapes a WebView2 handler arrives in: a completed
/// handler `(HRESULT, result)` and an event handler `(sender, args)`.
const TestCtx = struct {
    calls: u32 = 0,
    last_hr: HRESULT = 0,
    last_ptr: ?*anyopaque = null,
    answer: HRESULT = S_OK,
};

const Sender = opaque {};
const Args = opaque {};

// {11111111-2222-3333-4444-555555555555}
const IID_TestCompleted: GUID = .{
    .Data1 = 0x11111111,
    .Data2 = 0x2222,
    .Data3 = 0x3333,
    .Data4 = .{ 0x44, 0x44, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55 },
};

// {66666666-7777-8888-9999-AAAAAAAAAAAA}
const IID_TestEvent: GUID = .{
    .Data1 = 0x66666666,
    .Data2 = 0x7777,
    .Data3 = 0x8888,
    .Data4 = .{ 0x99, 0x99, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA },
};

fn onCompleted(ctx: *TestCtx, hr: HRESULT, result: ?*Args) HRESULT {
    ctx.calls += 1;
    ctx.last_hr = hr;
    ctx.last_ptr = @ptrCast(result);
    return ctx.answer;
}

fn onEvent(ctx: *TestCtx, sender: ?*Sender, args: ?*Args) HRESULT {
    ctx.calls += 1;
    ctx.last_ptr = @ptrCast(sender);
    _ = args;
    return ctx.answer;
}

/// The one-parameter shape: `ICoreWebView2CapturePreviewCompletedHandler`
/// hands back only an HRESULT (T397).
fn onOneArg(ctx: *TestCtx, hr: HRESULT) HRESULT {
    ctx.calls += 1;
    ctx.last_hr = hr;
    return ctx.answer;
}

// {BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF}
const IID_TestOneArg: GUID = .{
    .Data1 = 0xBBBBBBBB,
    .Data2 = 0xCCCC,
    .Data3 = 0xDDDD,
    .Data4 = .{ 0xEE, 0xEE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
};

const TestCompleted = Callback(IID_TestCompleted, onCompleted);
const TestEvent = Callback(IID_TestEvent, onEvent);
const TestOneArg = Callback(IID_TestOneArg, onOneArg);

test "failed() tests the sign bit, not equality with S_OK" {
    try testing.expect(!failed(S_OK));
    try testing.expect(!failed(1)); // S_FALSE is a success
    try testing.expect(failed(E_FAIL));
    try testing.expect(failed(E_NOINTERFACE));
}

test "guidEql" {
    try testing.expect(guidEql(&IID_IUnknown, &IID_IUnknown));
    try testing.expect(!guidEql(&IID_IUnknown, &IID_TestCompleted));
    // Differs in the last byte of Data4 only — the half a naive comparison
    // that stopped at Data3 would miss.
    var near = IID_TestCompleted;
    near.Data4[7] = 0x00;
    try testing.expect(!guidEql(&IID_TestCompleted, &near));
}

test "the vtable pointer is the first field" {
    // The whole reason the type is an `extern struct`. COM dereferences this
    // and nothing else about our layout.
    try testing.expectEqual(@as(usize, 0), @offsetOf(TestCompleted, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(TestEvent, "vtable"));
}

test "a callback is a well-behaved COM object" {
    var ctx: TestCtx = .{};
    const h = try TestCompleted.create(testing.allocator, &ctx);

    // QueryInterface for IUnknown and for its own IID both succeed and both
    // take a reference; `Release` reports the count AFTER the decrement, so
    // 1→2→1 reads as 1.
    var out: ?*anyopaque = null;
    try testing.expectEqual(S_OK, h.vtable.QueryInterface(h, &IID_IUnknown, &out));
    try testing.expectEqual(@as(*anyopaque, @ptrCast(h)), out.?);
    try testing.expectEqual(@as(u32, 1), h.vtable.Release(h));

    out = null;
    try testing.expectEqual(S_OK, h.vtable.QueryInterface(h, &IID_TestCompleted, &out));
    try testing.expectEqual(@as(*anyopaque, @ptrCast(h)), out.?);
    try testing.expectEqual(@as(u32, 1), h.vtable.Release(h));

    // Anything else is E_NOINTERFACE with a nulled out-param — including
    // another handler's IID, which is the mistake that hands a caller a
    // pointer whose Invoke has a different signature.
    out = @ptrFromInt(0xDEAD);
    try testing.expectEqual(E_NOINTERFACE, h.vtable.QueryInterface(h, &IID_TestEvent, &out));
    try testing.expect(out == null);

    // AddRef/Release count symmetrically, and the last Release frees (the
    // testing allocator is the oracle for that: a leak fails the test).
    try testing.expectEqual(@as(u32, 2), h.vtable.AddRef(h));
    try testing.expectEqual(@as(u32, 3), h.vtable.AddRef(h));
    try testing.expectEqual(@as(u32, 2), h.vtable.Release(h));
    try testing.expectEqual(@as(u32, 1), h.vtable.Release(h));
    try testing.expectEqual(@as(u32, 0), h.vtable.Release(h));
}

test "Invoke forwards both arguments and returns what the implementation returns" {
    var ctx: TestCtx = .{ .answer = E_FAIL };
    const h = try TestCompleted.create(testing.allocator, &ctx);
    defer h.release();

    const args: *Args = @ptrFromInt(0x1234);
    try testing.expectEqual(E_FAIL, h.vtable.Invoke(h, E_NOINTERFACE, args));
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    try testing.expectEqual(E_NOINTERFACE, ctx.last_hr);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(args)), ctx.last_ptr);

    // Null is a value the runtime really passes (a failed create hands back
    // a null result), so it must reach the implementation as null.
    ctx.answer = S_OK;
    try testing.expectEqual(S_OK, h.vtable.Invoke(h, S_OK, null));
    try testing.expectEqual(@as(u32, 2), ctx.calls);
    try testing.expectEqual(@as(?*anyopaque, null), ctx.last_ptr);
}

test "a one-parameter Invoke is the interface's shape, not a padded two" {
    // The arity is read off the implementation, so the vtable slot has ONE
    // parameter — a handler declared with a spare trailing argument would
    // read garbage off the stack for it in someone else's process.
    const Slot = @FieldType(TestOneArg.Vtbl, "Invoke");
    const params = @typeInfo(@typeInfo(Slot).pointer.child).@"fn".params;
    try testing.expectEqual(@as(usize, 2), params.len); // self + HRESULT
    try testing.expectEqual(HRESULT, params[1].type.?);
    // The two-parameter shape is unchanged next to it.
    const Slot2 = @FieldType(TestCompleted.Vtbl, "Invoke");
    try testing.expectEqual(
        @as(usize, 3),
        @typeInfo(@typeInfo(Slot2).pointer.child).@"fn".params.len,
    );

    var ctx: TestCtx = .{ .answer = E_FAIL };
    const h = try TestOneArg.create(testing.allocator, &ctx);
    defer h.release();
    try testing.expectEqual(E_FAIL, h.vtable.Invoke(h, E_NOINTERFACE));
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    try testing.expectEqual(E_NOINTERFACE, ctx.last_hr);
    try testing.expectEqual(@as(usize, 0), @offsetOf(TestOneArg, "vtable"));
}

test "each instantiation has its own IID and its own Invoke signature" {
    // The event shape takes two pointers where the completed shape takes an
    // HRESULT first; both compile off the same helper, which is the whole
    // claim of the parameterization.
    try testing.expect(!guidEql(&TestCompleted.IID, &TestEvent.IID));
    try testing.expectEqual(TestCtx, TestCompleted.Ctx);

    var ctx: TestCtx = .{};
    const h = try TestEvent.create(testing.allocator, &ctx);
    defer h.release();

    const sender: *Sender = @ptrFromInt(0xBEEF);
    try testing.expectEqual(S_OK, h.vtable.Invoke(h, sender, null));
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(sender)), ctx.last_ptr);

    // And it does not answer for the other handler's interface.
    var out: ?*anyopaque = null;
    try testing.expectEqual(E_NOINTERFACE, h.vtable.QueryInterface(h, &IID_TestCompleted, &out));
    try testing.expectEqual(S_OK, h.vtable.QueryInterface(h, &IID_TestEvent, &out));
    try testing.expectEqual(@as(u32, 1), h.vtable.Release(h));
}

test "CallbackOwning drops what it borrowed exactly once, at zero" {
    // The hazard it exists for: an EVENT handler outlives the pane that
    // registered it, so the refcounted context it borrowed must be released by
    // the handler's own death — not by the pane's.
    const Borrowed = struct {
        var released: u32 = 0;
        fn give(ctx: *TestCtx) void {
            _ = ctx;
            released += 1;
        }
    };
    Borrowed.released = 0;

    const Owning = CallbackOwning(IID_TestEvent, onEvent, Borrowed.give);
    var ctx: TestCtx = .{};
    const h = try Owning.create(testing.allocator, &ctx);

    // Intermediate releases do NOT run it: only the transition to zero does.
    h.addRef();
    h.release();
    try testing.expectEqual(@as(u32, 0), Borrowed.released);

    h.release();
    try testing.expectEqual(@as(u32, 1), Borrowed.released);

    // And a plain Callback has no hook at all, which is why `{}` compiles.
    const h2 = try TestEvent.create(testing.allocator, &ctx);
    h2.release();
    try testing.expectEqual(@as(u32, 1), Borrowed.released);
}

test "the object frees through the allocator it was created with" {
    // The oracle for carrying the allocator as its two words. A handler
    // whose context has no allocator (T373's panes reach theirs through the
    // window) still has to be freeable, and freeing through some ambient
    // allocator instead would be a heap corruption that no leak check sees.
    var counting: CountingAllocator = .{ .parent = testing.allocator };
    var ctx: TestCtx = .{};

    const h = try TestCompleted.create(counting.allocator(), &ctx);
    try testing.expectEqual(@as(u32, 1), counting.allocs);
    try testing.expectEqual(@as(u32, 0), counting.frees);

    h.release();
    try testing.expectEqual(@as(u32, 1), counting.frees);
}

/// Counts through to a parent allocator. Small enough to be obvious, which
/// matters for a test whose whole job is to prove *which* allocator ran.
const CountingAllocator = struct {
    parent: Allocator,
    allocs: u32 = 0,
    frees: u32 = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.parent.rawAlloc(len, a, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(buf, a, new_len, ra);
    }

    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawRemap(buf, a, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.parent.rawFree(buf, a, ra);
    }
};
