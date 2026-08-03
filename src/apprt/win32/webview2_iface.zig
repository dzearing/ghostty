//! The WebView2 COM interfaces we call, hand-declared (T373).
//!
//! `com.zig` is the floor for the objects **we** implement; this is the other
//! direction — the vtables Microsoft's browser process hands us. They live in
//! their own module because there is nothing to run here: no state, no window,
//! no allocation. It imports `std` and `com.zig` and nothing else, so a
//! mistake in a vtable is a compile-time or a `@offsetOf` failure rather than
//! something that only shows up under a live runtime.
//!
//! ## How these were derived, and how to check them
//!
//! Vtable ORDER is the whole contract: a slot in the wrong position calls a
//! different function with the wrong arguments, in someone else's process. So
//! none of this was written from memory or from the online reference (which
//! lists members alphabetically, not in vtable order). Each interface below
//! was transcribed from the `MIDL_INTERFACE` C vtable structs in the SDK's own
//! `WebView2.h` (`Microsoft.Web.WebView2` 1.0.3485.44), whose
//! `DECLSPEC_XFGVIRT(Interface, method)` annotations state, per slot, which
//! interface in the derivation chain contributed it. Nothing from that package
//! is vendored — it was read, and the slot counts recorded here are what
//! survived.
//!
//! Two rules follow from the COM versioning contract and both are load-bearing:
//!
//! 1. **A later revision is a different IID with its own vtable**, reached by
//!    `QueryInterface`, never by assuming trailing slots exist on the one you
//!    have. `ICoreWebView2Controller3` is not "a Controller with extra
//!    methods" you can cast to; it is its own interface whose vtable happens
//!    to start with Controller's.
//! 2. **A revision's vtable prefix is stable forever.** That is what makes
//!    declaring `ICoreWebView2_13` as "105 slots we never call, then
//!    `get_Profile`" safe against a runtime newer than the header: a QI for
//!    `_13` returns a pointer whose first 106 slots are `_13`'s, whatever the
//!    runtime's latest revision is.
//!
//! Slots we do not call are declared `*const anyopaque` (or, where there are
//! dozens in a row, one `[N]*const anyopaque` block). An opaque slot cannot be
//! called at all, which is exactly the property we want: an unused slot with a
//! *guessed* signature is a crash waiting for the day somebody calls it.
//!
//! The slot counts are asserted at the bottom of this file, and the ABI itself
//! is proven against a live runtime in `ViewerPane.zig`'s on-box test — the
//! T372 rule that an undocumented ABI is proven rather than believed.
const std = @import("std");
const com = @import("com.zig");

pub const GUID = com.GUID;
pub const HRESULT = com.HRESULT;

/// `std.os.windows.HWND`, not `win32.zig`'s alias, so this module needs no
/// OS-surface import of ours to compile.
pub const HWND = std.os.windows.HWND;
pub const BOOL = i32;

/// Win32 `RECT`. Declared here rather than imported from `win32.zig` for the
/// same reason; it is layout-identical (four `LONG`s).
pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// `COREWEBVIEW2_MOVE_FOCUS_REASON`.
pub const MoveFocusReason = enum(i32) {
    programmatic = 0,
    next = 1,
    previous = 2,
};

/// `COREWEBVIEW2_PREFERRED_COLOR_SCHEME`. `auto` follows the OS and is what an
/// older runtime without `ICoreWebView2_13` degrades to (T90a design §14).
pub const PreferredColorScheme = enum(i32) {
    auto = 0,
    light = 1,
    dark = 2,
};

// ------------------------------------------------------------------- IIDs

// {B96D755E-0319-4E92-A296-23436F46A1FC}
pub const IID_ICoreWebView2Environment: GUID = .{
    .Data1 = 0xB96D755E,
    .Data2 = 0x0319,
    .Data3 = 0x4E92,
    .Data4 = .{ 0xA2, 0x96, 0x23, 0x43, 0x6F, 0x46, 0xA1, 0xFC },
};

// {6C4819F3-C9B7-4260-8127-C9F5BDE7F68C}
pub const IID_ControllerCompletedHandler: GUID = .{
    .Data1 = 0x6C4819F3,
    .Data2 = 0xC9B7,
    .Data3 = 0x4260,
    .Data4 = .{ 0x81, 0x27, 0xC9, 0xF5, 0xBD, 0xE7, 0xF6, 0x8C },
};

// {4D00C0D1-9434-4EB6-8078-8697A560334F}
pub const IID_ICoreWebView2Controller: GUID = .{
    .Data1 = 0x4D00C0D1,
    .Data2 = 0x9434,
    .Data3 = 0x4EB6,
    .Data4 = .{ 0x80, 0x78, 0x86, 0x97, 0xA5, 0x60, 0x33, 0x4F },
};

// {F9614724-5D2B-41DC-AEF7-73D62B51543B}
pub const IID_ICoreWebView2Controller3: GUID = .{
    .Data1 = 0xF9614724,
    .Data2 = 0x5D2B,
    .Data3 = 0x41DC,
    .Data4 = .{ 0xAE, 0xF7, 0x73, 0xD6, 0x2B, 0x51, 0x54, 0x3B },
};

// {76ECEACB-0462-4D94-AC83-423A6793775E}
pub const IID_ICoreWebView2: GUID = .{
    .Data1 = 0x76ECEACB,
    .Data2 = 0x0462,
    .Data3 = 0x4D94,
    .Data4 = .{ 0xAC, 0x83, 0x42, 0x3A, 0x67, 0x93, 0x77, 0x5E },
};

// {F75F09A8-667E-4983-88D6-C8773F315E84}
pub const IID_ICoreWebView2_13: GUID = .{
    .Data1 = 0xF75F09A8,
    .Data2 = 0x667E,
    .Data3 = 0x4983,
    .Data4 = .{ 0x88, 0xD6, 0xC8, 0x77, 0x3F, 0x31, 0x5E, 0x84 },
};

// {79110AD3-CD5D-4373-8BC3-C60658F17A5F}
pub const IID_ICoreWebView2Profile: GUID = .{
    .Data1 = 0x79110AD3,
    .Data2 = 0xCD5D,
    .Data3 = 0x4373,
    .Data4 = .{ 0x8B, 0xC3, 0xC6, 0x06, 0x58, 0xF1, 0x7A, 0x5F },
};

// {D4C185FE-C81C-4989-97AF-2D3FA7AB5651}
pub const IID_NewWindowRequestedHandler: GUID = .{
    .Data1 = 0xD4C185FE,
    .Data2 = 0xC81C,
    .Data3 = 0x4989,
    .Data4 = .{ 0x97, 0xAF, 0x2D, 0x3F, 0xA7, 0xAB, 0x56, 0x51 },
};

// {34ACB11C-FC37-4418-9132-F9C21D1EAFB9}
pub const IID_ICoreWebView2NewWindowRequestedEventArgs: GUID = .{
    .Data1 = 0x34ACB11C,
    .Data2 = 0xFC37,
    .Data3 = 0x4418,
    .Data4 = .{ 0x91, 0x32, 0xF9, 0xC2, 0x1D, 0x1E, 0xAF, 0xB9 },
};

// {B99369F3-9B11-47B5-BC6F-8E7895FCEA17}
// `ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler`.
pub const IID_AddScriptCompletedHandler: GUID = .{
    .Data1 = 0xB99369F3,
    .Data2 = 0x9B11,
    .Data3 = 0x47B5,
    .Data4 = .{ 0xBC, 0x6F, 0x8E, 0x78, 0x95, 0xFC, 0xEA, 0x17 },
};

// {57213F19-00E6-49FA-8E07-898EA01ECBD2}
pub const IID_WebMessageReceivedHandler: GUID = .{
    .Data1 = 0x57213F19,
    .Data2 = 0x00E6,
    .Data3 = 0x49FA,
    .Data4 = .{ 0x8E, 0x07, 0x89, 0x8E, 0xA0, 0x1E, 0xCB, 0xD2 },
};

// {0F99A40C-E962-4207-9E92-E3D542EFF849}
pub const IID_ICoreWebView2WebMessageReceivedEventArgs: GUID = .{
    .Data1 = 0x0F99A40C,
    .Data2 = 0xE962,
    .Data3 = 0x4207,
    .Data4 = .{ 0x9E, 0x92, 0xE3, 0xD5, 0x42, 0xEF, 0xF8, 0x49 },
};

/// `EventRegistrationToken` (winrt's `eventtoken.h`), the out-parameter every
/// `add_*` writes. We keep no tokens — a handler lives exactly as long as the
/// web view it was added to, and `Close` tears both down — but the slot has to
/// be the right SIZE and the pointer non-null, or the runtime writes eight
/// bytes somewhere we did not intend.
pub const EventRegistrationToken = extern struct { value: i64 = 0 };

// ---------------------------- ICoreWebView2NewWindowRequestedEventArgs
/// The `window.open()` / target=_blank request. We answer exactly two of its
/// eight slots: read the URI, and mark the request handled.
///
/// **`GetDeferral` is deliberately NOT declared.** Taking a deferral and
/// dropping it wedges the requesting page forever, and T163 (adopting popups
/// as real ghoztty windows) is the task that will need one — declaring it now
/// would be an unused slot with a guessed signature, which this file's header
/// calls a crash waiting for the day somebody calls it. Handing the URL to the
/// default browser needs no deferral at all: it is synchronous.
pub const ICoreWebView2NewWindowRequestedEventArgs = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2NewWindowRequestedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2NewWindowRequestedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2NewWindowRequestedEventArgs) callconv(.winapi) u32,
        get_Uri: *const fn (*ICoreWebView2NewWindowRequestedEventArgs, *?[*:0]u16) callconv(.winapi) HRESULT,
        put_NewWindow: *const anyopaque,
        get_NewWindow: *const anyopaque,
        put_Handled: *const fn (*ICoreWebView2NewWindowRequestedEventArgs, BOOL) callconv(.winapi) HRESULT,
    };

    /// The requested URL. Caller frees it with `CoTaskMemFree`.
    pub fn uriRaw(self: *ICoreWebView2NewWindowRequestedEventArgs) ?[*:0]u16 {
        var raw: ?[*:0]u16 = null;
        if (com.failed(self.vtable.get_Uri(self, &raw))) return null;
        return raw;
    }

    /// "We dealt with it; do not open a WebView2 popup window."
    pub fn setHandled(self: *ICoreWebView2NewWindowRequestedEventArgs, handled: bool) bool {
        return !com.failed(self.vtable.put_Handled(self, if (handled) 1 else 0));
    }
};

// ------------------------- ICoreWebView2WebMessageReceivedEventArgs

/// What `window.chrome.webview.postMessage(obj)` arrives as. Six slots, all
/// declared because there are so few.
///
/// `get_WebMessageAsJson` is the one T375 calls, and the choice matters:
/// `TryGetWebMessageAsString` fails outright unless the page posted a bare
/// string, and every message the shared viewer JS posts is an OBJECT. The JSON
/// it returns is the same shape Mac's `WKScriptMessage.body` dictionary carries,
/// which is what lets `viewer_bridge.parse` be a straight port of
/// `handleTOCMessage` rather than a second protocol.
pub const ICoreWebView2WebMessageReceivedEventArgs = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2WebMessageReceivedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2WebMessageReceivedEventArgs) callconv(.winapi) u32,
        get_Source: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *?[*:0]u16) callconv(.winapi) HRESULT,
        get_WebMessageAsJson: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *?[*:0]u16) callconv(.winapi) HRESULT,
        TryGetWebMessageAsString: *const anyopaque,
    };

    /// The message, as JSON. Caller frees it with `CoTaskMemFree`.
    pub fn jsonRaw(self: *ICoreWebView2WebMessageReceivedEventArgs) ?[*:0]u16 {
        var raw: ?[*:0]u16 = null;
        if (com.failed(self.vtable.get_WebMessageAsJson(self, &raw))) return null;
        return raw;
    }

    /// The URI of the document that posted it. Caller frees it with
    /// `CoTaskMemFree`.
    pub fn sourceRaw(self: *ICoreWebView2WebMessageReceivedEventArgs) ?[*:0]u16 {
        var raw: ?[*:0]u16 = null;
        if (com.failed(self.vtable.get_Source(self, &raw))) return null;
        return raw;
    }
};

// ------------------------------------------------------- ICoreWebView2Profile

/// The per-profile settings object. We reach it only for
/// `put_PreferredColorScheme`, which is what drives the page's
/// `prefers-color-scheme` (T90a design §14) — 10 slots, all of them declared
/// because there are so few.
pub const ICoreWebView2Profile = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Profile, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2Profile) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2Profile) callconv(.winapi) u32,
        get_ProfileName: *const anyopaque,
        get_IsInPrivateModeEnabled: *const anyopaque,
        get_ProfilePath: *const anyopaque,
        get_DefaultDownloadFolderPath: *const anyopaque,
        put_DefaultDownloadFolderPath: *const anyopaque,
        get_PreferredColorScheme: *const fn (*ICoreWebView2Profile, *PreferredColorScheme) callconv(.winapi) HRESULT,
        put_PreferredColorScheme: *const fn (*ICoreWebView2Profile, PreferredColorScheme) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ICoreWebView2Profile) void {
        _ = self.vtable.Release(self);
    }

    pub fn setPreferredColorScheme(self: *ICoreWebView2Profile, scheme: PreferredColorScheme) bool {
        return !com.failed(self.vtable.put_PreferredColorScheme(self, scheme));
    }

    pub fn preferredColorScheme(self: *ICoreWebView2Profile) ?PreferredColorScheme {
        var out: PreferredColorScheme = .auto;
        if (com.failed(self.vtable.get_PreferredColorScheme(self, &out))) return null;
        return out;
    }
};

// ------------------------------------------------------------ ICoreWebView2

/// The web view itself. T373 needed exactly one thing from it — a
/// `QueryInterface` to `ICoreWebView2_13` for the profile — and declared only
/// `IUnknown`. T374 added the two slots web mode calls: `Navigate` (slot 5) and
/// `add_NewWindowRequested` (slot 44). T375 adds the bridge's two:
/// `AddScriptToExecuteOnDocumentCreated` (slot 27) and
/// `add_WebMessageReceived` (slot 34), which is why what used to be one
/// 38-slot opaque block is now three shorter ones.
///
/// Declaring 45 slots of an interface that has 61 is safe and deliberate: the
/// vtable pointer is the runtime's, we only ever index the ones named here,
/// and a slot that is not declared cannot be called by mistake. The ones we do
/// not call are opaque — individually where a named neighbor makes the
/// position readable, and as one length-only block where there are dozens in a
/// row (`ICoreWebView2_13`'s rule, applied here).
pub const ICoreWebView2 = extern struct {
    vtable: *const Vtbl,

    /// Slots 6..26: `NavigateToString` through `remove_ProcessFailed`.
    pub const nav_events_slots = 21;
    /// Slots 28..33: `RemoveScriptToExecuteOnDocumentCreated` through
    /// `PostWebMessageAsString`.
    pub const script_slots = 6;
    /// Slots 35..43: `remove_WebMessageReceived` through `Stop`.
    pub const history_slots = 9;

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2) callconv(.winapi) u32,
        get_Settings: *const anyopaque,
        get_Source: *const fn (*ICoreWebView2, *?[*:0]u16) callconv(.winapi) HRESULT,
        Navigate: *const fn (*ICoreWebView2, [*:0]const u16) callconv(.winapi) HRESULT,
        nav_events: [nav_events_slots]*const anyopaque,
        AddScriptToExecuteOnDocumentCreated: *const fn (*ICoreWebView2, [*:0]const u16, *anyopaque) callconv(.winapi) HRESULT,
        script: [script_slots]*const anyopaque,
        add_WebMessageReceived: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        history: [history_slots]*const anyopaque,
        add_NewWindowRequested: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ICoreWebView2) void {
        _ = self.vtable.Release(self);
    }

    /// Point the view at `uri`. Asynchronous: success means the navigation
    /// STARTED, and the page arrives later on the message loop.
    pub fn navigate(self: *ICoreWebView2, uri: [*:0]const u16) bool {
        return !com.failed(self.vtable.Navigate(self, uri));
    }

    /// Where the view actually IS — the browser's answer, not ours. Caller
    /// frees it with `CoTaskMemFree`. This is what makes `navigate` verifiable:
    /// a `Navigate` at the wrong vtable slot can still return `S_OK`, and only
    /// reading the source back proves the page moved.
    pub fn sourceRaw(self: *ICoreWebView2) ?[*:0]u16 {
        var raw: ?[*:0]u16 = null;
        if (com.failed(self.vtable.get_Source(self, &raw))) return null;
        return raw;
    }

    /// Subscribe to `window.open()` / target=_blank. `handler` is one of OUR
    /// objects (a `com.Callback` instantiation), so it is typed as the opaque
    /// pointer COM needs and nothing more — same rule as
    /// `CreateCoreWebView2Controller`.
    pub fn addNewWindowRequested(self: *ICoreWebView2, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_NewWindowRequested(self, handler, &token));
    }

    /// Run `js` at document-created time in every page this view loads, from
    /// the next navigation on (design P2). `handler` is one of OUR objects and
    /// is NOT optional: the runtime dereferences it to report the script id.
    ///
    /// Success here means "the request was accepted", not "the script is
    /// installed" — the completed handler is what says that, and a navigation
    /// started before it fires may load without the script.
    pub fn addScriptToExecuteOnDocumentCreated(
        self: *ICoreWebView2,
        js: [*:0]const u16,
        handler: *anyopaque,
    ) bool {
        return !com.failed(self.vtable.AddScriptToExecuteOnDocumentCreated(self, js, handler));
    }

    /// Subscribe to `window.chrome.webview.postMessage` (design P1).
    pub fn addWebMessageReceived(self: *ICoreWebView2, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_WebMessageReceived(self, handler, &token));
    }

    /// The `ICoreWebView2_13` view of this object, or null on a runtime that
    /// predates it. Caller owns the reference.
    pub fn queryV13(self: *ICoreWebView2) ?*ICoreWebView2_13 {
        var out: ?*anyopaque = null;
        if (com.failed(self.vtable.QueryInterface(self, &IID_ICoreWebView2_13, &out))) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }
};

/// `ICoreWebView2_13` — revision 13, whose one addition is `get_Profile`.
///
/// It inherits 105 slots (3 `IUnknown` + 58 from `ICoreWebView2` + the
/// additions of revisions 2 through 12) and adds `get_Profile` as slot 105,
/// the last. Naming those 102 middle slots individually would be 102 chances
/// to typo a name that is never used; the block is one declaration whose only
/// contract is its LENGTH, and `@offsetOf` asserts that below.
pub const ICoreWebView2_13 = extern struct {
    vtable: *const Vtbl,

    /// Slots 3..104: every method from `ICoreWebView2` through
    /// `ICoreWebView2_12`, in vtable order. We call none of them.
    pub const inherited_slots = 102;

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2_13, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2_13) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2_13) callconv(.winapi) u32,
        inherited: [inherited_slots]*const anyopaque,
        get_Profile: *const fn (*ICoreWebView2_13, *?*ICoreWebView2Profile) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ICoreWebView2_13) void {
        _ = self.vtable.Release(self);
    }

    /// This web view's profile. Caller owns the reference.
    pub fn profile(self: *ICoreWebView2_13) ?*ICoreWebView2Profile {
        var out: ?*ICoreWebView2Profile = null;
        if (com.failed(self.vtable.get_Profile(self, &out))) return null;
        return out;
    }
};

// -------------------------------------------------- ICoreWebView2Controller

/// The host-side handle on a web view: where it sits, whether it is visible,
/// where its keyboard focus goes, and when to tear it down (T90a design §4).
/// Every slot is declared in order; the ones we do not call are opaque.
pub const ICoreWebView2Controller = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Controller, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2Controller) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2Controller) callconv(.winapi) u32,
        get_IsVisible: *const fn (*ICoreWebView2Controller, *BOOL) callconv(.winapi) HRESULT,
        put_IsVisible: *const fn (*ICoreWebView2Controller, BOOL) callconv(.winapi) HRESULT,
        get_Bounds: *const fn (*ICoreWebView2Controller, *RECT) callconv(.winapi) HRESULT,
        /// Takes the RECT **by value** (the x64 ABI passes a 16-byte aggregate
        /// indirectly; `callconv(.winapi)` on an extern struct gets that right,
        /// and passing a pointer here instead would put a pointer where the
        /// callee reads a rectangle).
        put_Bounds: *const fn (*ICoreWebView2Controller, RECT) callconv(.winapi) HRESULT,
        get_ZoomFactor: *const anyopaque,
        put_ZoomFactor: *const anyopaque,
        add_ZoomFactorChanged: *const anyopaque,
        remove_ZoomFactorChanged: *const anyopaque,
        SetBoundsAndZoomFactor: *const anyopaque,
        MoveFocus: *const fn (*ICoreWebView2Controller, MoveFocusReason) callconv(.winapi) HRESULT,
        add_MoveFocusRequested: *const anyopaque,
        remove_MoveFocusRequested: *const anyopaque,
        add_GotFocus: *const anyopaque,
        remove_GotFocus: *const anyopaque,
        add_LostFocus: *const anyopaque,
        remove_LostFocus: *const anyopaque,
        /// T90a design §11 wires this in T375 (a bound chord must keep working
        /// while Chromium holds focus); declared opaque until it has a handler.
        add_AcceleratorKeyPressed: *const anyopaque,
        remove_AcceleratorKeyPressed: *const anyopaque,
        get_ParentWindow: *const anyopaque,
        put_ParentWindow: *const anyopaque,
        NotifyParentWindowPositionChanged: *const fn (*ICoreWebView2Controller) callconv(.winapi) HRESULT,
        Close: *const fn (*ICoreWebView2Controller) callconv(.winapi) HRESULT,
        get_CoreWebView2: *const fn (*ICoreWebView2Controller, *?*ICoreWebView2) callconv(.winapi) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Controller) void {
        _ = self.vtable.AddRef(self);
    }

    pub fn release(self: *ICoreWebView2Controller) void {
        _ = self.vtable.Release(self);
    }

    pub fn setBounds(self: *ICoreWebView2Controller, r: RECT) bool {
        return !com.failed(self.vtable.put_Bounds(self, r));
    }

    pub fn bounds(self: *ICoreWebView2Controller) ?RECT {
        var out: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (com.failed(self.vtable.get_Bounds(self, &out))) return null;
        return out;
    }

    pub fn setVisible(self: *ICoreWebView2Controller, visible: bool) bool {
        return !com.failed(self.vtable.put_IsVisible(self, if (visible) 1 else 0));
    }

    pub fn isVisible(self: *ICoreWebView2Controller) ?bool {
        var out: BOOL = 0;
        if (com.failed(self.vtable.get_IsVisible(self, &out))) return null;
        return out != 0;
    }

    pub fn moveFocus(self: *ICoreWebView2Controller, reason: MoveFocusReason) bool {
        return !com.failed(self.vtable.MoveFocus(self, reason));
    }

    pub fn notifyParentWindowPositionChanged(self: *ICoreWebView2Controller) void {
        _ = self.vtable.NotifyParentWindowPositionChanged(self);
    }

    pub fn close(self: *ICoreWebView2Controller) void {
        _ = self.vtable.Close(self);
    }

    /// The web view this controller hosts. Caller owns the reference.
    pub fn coreWebView(self: *ICoreWebView2Controller) ?*ICoreWebView2 {
        var out: ?*ICoreWebView2 = null;
        if (com.failed(self.vtable.get_CoreWebView2(self, &out))) return null;
        return out;
    }

    /// The `ICoreWebView2Controller3` view of this controller, or null on a
    /// runtime that predates it. Caller owns the reference.
    pub fn queryV3(self: *ICoreWebView2Controller) ?*ICoreWebView2Controller3 {
        var out: ?*anyopaque = null;
        if (com.failed(self.vtable.QueryInterface(self, &IID_ICoreWebView2Controller3, &out))) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }
};

/// Revision 3 of the controller: DPI. Its vtable is `ICoreWebView2Controller`'s
/// 26 slots, then revision 2's two background-color slots, then its own eight.
///
/// This is the interface that lets the host own scaling. Per-monitor-v2 is a
/// house rule (the window already tracks its own DPI and lays panes out in
/// physical pixels), so the pane pushes `RasterizationScale` itself with
/// `ShouldDetectMonitorScaleChanges` off — two sources of truth for scale is
/// how a pane ends up rendering at 1.25 inside bounds computed for 1.0.
pub const ICoreWebView2Controller3 = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Controller3, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2Controller3) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2Controller3) callconv(.winapi) u32,
        /// Slots 3..25: `ICoreWebView2Controller`'s own methods. Reached
        /// through the base interface, never through this one.
        controller: [23]*const anyopaque,
        /// Slots 26..27: `ICoreWebView2Controller2`.
        get_DefaultBackgroundColor: *const anyopaque,
        put_DefaultBackgroundColor: *const anyopaque,
        get_RasterizationScale: *const fn (*ICoreWebView2Controller3, *f64) callconv(.winapi) HRESULT,
        put_RasterizationScale: *const fn (*ICoreWebView2Controller3, f64) callconv(.winapi) HRESULT,
        get_ShouldDetectMonitorScaleChanges: *const fn (*ICoreWebView2Controller3, *BOOL) callconv(.winapi) HRESULT,
        put_ShouldDetectMonitorScaleChanges: *const fn (*ICoreWebView2Controller3, BOOL) callconv(.winapi) HRESULT,
        add_RasterizationScaleChanged: *const anyopaque,
        remove_RasterizationScaleChanged: *const anyopaque,
        get_BoundsMode: *const anyopaque,
        put_BoundsMode: *const anyopaque,
    };

    pub fn release(self: *ICoreWebView2Controller3) void {
        _ = self.vtable.Release(self);
    }

    pub fn setRasterizationScale(self: *ICoreWebView2Controller3, scale: f64) bool {
        return !com.failed(self.vtable.put_RasterizationScale(self, scale));
    }

    pub fn rasterizationScale(self: *ICoreWebView2Controller3) ?f64 {
        var out: f64 = 0;
        if (com.failed(self.vtable.get_RasterizationScale(self, &out))) return null;
        return out;
    }

    pub fn setShouldDetectMonitorScaleChanges(self: *ICoreWebView2Controller3, value: bool) bool {
        return !com.failed(self.vtable.put_ShouldDetectMonitorScaleChanges(self, if (value) 1 else 0));
    }

    pub fn shouldDetectMonitorScaleChanges(self: *ICoreWebView2Controller3) ?bool {
        var out: BOOL = 0;
        if (com.failed(self.vtable.get_ShouldDetectMonitorScaleChanges(self, &out))) return null;
        return out != 0;
    }
};

// ------------------------------------------------------ ICoreWebView2Environment

/// The shared environment (T372 owns its creation; this is its declaration).
/// `CreateCoreWebView2Controller` is the one slot T373 added a signature to.
pub const ICoreWebView2Environment = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Environment, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2Environment) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2Environment) callconv(.winapi) u32,
        /// `(HWND parentWindow, ICoreWebView2CreateCoreWebView2Controller-
        /// CompletedHandler *handler)`. The handler is one of OUR objects (a
        /// `com.Callback` instantiation), and COM only ever needs its address,
        /// so the parameter is typed as the opaque pointer it is — that keeps
        /// this module from having to know the handler's Zig type.
        CreateCoreWebView2Controller: *const fn (*ICoreWebView2Environment, HWND, *anyopaque) callconv(.winapi) HRESULT,
        CreateWebResourceResponse: *const anyopaque,
        get_BrowserVersionString: *const fn (*ICoreWebView2Environment, *?[*:0]u16) callconv(.winapi) HRESULT,
        add_NewBrowserVersionAvailable: *const anyopaque,
        remove_NewBrowserVersionAvailable: *const anyopaque,
    };

    pub fn addRef(self: *ICoreWebView2Environment) void {
        _ = self.vtable.AddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment) void {
        _ = self.vtable.Release(self);
    }

    /// Start creating a controller parented to `hwnd`. Success means
    /// "creation is under way"; `handler` finishes it.
    pub fn createController(
        self: *ICoreWebView2Environment,
        hwnd: HWND,
        handler: *anyopaque,
    ) HRESULT {
        return self.vtable.CreateCoreWebView2Controller(self, hwnd, handler);
    }

    /// The browser version this environment is actually running, as UTF-8.
    /// Caller owns the result.
    ///
    /// The cheapest possible proof that the environment is a live COM object
    /// and not a pointer that merely came back non-null: the string is
    /// produced by the browser process and has to match what the registry
    /// advertised. Freeing it needs `CoTaskMemFree`, which lives on the
    /// caller's side of the OS boundary — see `webview2.browserVersion`.
    pub fn browserVersionRaw(self: *ICoreWebView2Environment) ?[*:0]u16 {
        var raw: ?[*:0]u16 = null;
        if (com.failed(self.vtable.get_BrowserVersionString(self, &raw))) return null;
        return raw;
    }
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "vtable slot counts match the SDK's own layout" {
    // The only contract these declarations have is their LENGTH and the
    // position of the slots we call. A wrong count silently shifts every slot
    // after it, so it is asserted rather than trusted, per interface, in the
    // one place the numbers live.
    const ptr = @sizeOf(*const anyopaque);
    try testing.expectEqual(10 * ptr, @sizeOf(ICoreWebView2Profile.Vtbl));
    // 45 of ICoreWebView2's 61: everything through `add_NewWindowRequested`.
    // Declaring a PREFIX is the point — the runtime's vtable is longer and the
    // slots past the last one we name are simply never indexed.
    try testing.expectEqual(45 * ptr, @sizeOf(ICoreWebView2.Vtbl));
    try testing.expectEqual(7 * ptr, @sizeOf(ICoreWebView2NewWindowRequestedEventArgs.Vtbl));
    try testing.expectEqual(6 * ptr, @sizeOf(ICoreWebView2WebMessageReceivedEventArgs.Vtbl));
    try testing.expectEqual(106 * ptr, @sizeOf(ICoreWebView2_13.Vtbl));
    try testing.expectEqual(26 * ptr, @sizeOf(ICoreWebView2Controller.Vtbl));
    try testing.expectEqual(36 * ptr, @sizeOf(ICoreWebView2Controller3.Vtbl));
    try testing.expectEqual(8 * ptr, @sizeOf(ICoreWebView2Environment.Vtbl));
}

test "the slots we actually call sit where the header puts them" {
    const ptr = @sizeOf(*const anyopaque);

    // ICoreWebView2Controller: the four the pane drives every frame.
    try testing.expectEqual(3 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "get_IsVisible"));
    try testing.expectEqual(4 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "put_IsVisible"));
    try testing.expectEqual(6 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "put_Bounds"));
    try testing.expectEqual(12 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "MoveFocus"));
    try testing.expectEqual(23 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "NotifyParentWindowPositionChanged"));
    try testing.expectEqual(24 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "Close"));
    try testing.expectEqual(25 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "get_CoreWebView2"));

    // Controller3's DPI pair sits AFTER Controller's 26 and Controller2's 2.
    try testing.expectEqual(29 * ptr, @offsetOf(ICoreWebView2Controller3.Vtbl, "put_RasterizationScale"));
    try testing.expectEqual(31 * ptr, @offsetOf(ICoreWebView2Controller3.Vtbl, "put_ShouldDetectMonitorScaleChanges"));

    // ICoreWebView2: the four slots we call. `Navigate` sits third among the
    // interface's own methods (after get_Settings/get_Source); the other three
    // sit behind opaque blocks whose LENGTHS exist to hold these numbers in
    // place. `add_NewWindowRequested` at 44 is the load-bearing one — it was
    // already asserted before the block was split into three, so it is the
    // check that says the split did not move anything.
    try testing.expectEqual(4 * ptr, @offsetOf(ICoreWebView2.Vtbl, "get_Source"));
    try testing.expectEqual(5 * ptr, @offsetOf(ICoreWebView2.Vtbl, "Navigate"));
    try testing.expectEqual(27 * ptr, @offsetOf(ICoreWebView2.Vtbl, "AddScriptToExecuteOnDocumentCreated"));
    try testing.expectEqual(34 * ptr, @offsetOf(ICoreWebView2.Vtbl, "add_WebMessageReceived"));
    try testing.expectEqual(44 * ptr, @offsetOf(ICoreWebView2.Vtbl, "add_NewWindowRequested"));

    // The new-window args: read the URI, then say we handled it.
    try testing.expectEqual(3 * ptr, @offsetOf(ICoreWebView2NewWindowRequestedEventArgs.Vtbl, "get_Uri"));
    try testing.expectEqual(6 * ptr, @offsetOf(ICoreWebView2NewWindowRequestedEventArgs.Vtbl, "put_Handled"));

    // The web-message args: the source URI, then the JSON. Reading the JSON out
    // of slot 4 is the whole bridge; slot 5 (`TryGetWebMessageAsString`) fails
    // on an object payload and would look like "the page sent nothing".
    try testing.expectEqual(3 * ptr, @offsetOf(ICoreWebView2WebMessageReceivedEventArgs.Vtbl, "get_Source"));
    try testing.expectEqual(4 * ptr, @offsetOf(ICoreWebView2WebMessageReceivedEventArgs.Vtbl, "get_WebMessageAsJson"));

    // The one slot in ICoreWebView2_13 that is not opaque is its last.
    try testing.expectEqual(105 * ptr, @offsetOf(ICoreWebView2_13.Vtbl, "get_Profile"));

    // And the environment's controller factory is slot 3, right after IUnknown.
    try testing.expectEqual(3 * ptr, @offsetOf(ICoreWebView2Environment.Vtbl, "CreateCoreWebView2Controller"));
}

test "every interface puts its vtable pointer first" {
    // COM dereferences this and nothing else about the layout, which is why
    // each of these is an `extern struct` rather than a plain one.
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2Profile, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2_13, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2Controller, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2Controller3, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2Environment, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2NewWindowRequestedEventArgs, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2WebMessageReceivedEventArgs, "vtable"));
}

test "EventRegistrationToken is the 64-bit value the add_* slots write" {
    // The runtime writes through this pointer. Eight bytes, and nothing else
    // in the struct to shift them.
    try testing.expectEqual(@as(usize, 8), @sizeOf(EventRegistrationToken));
    try testing.expectEqual(@as(usize, 0), @offsetOf(EventRegistrationToken, "value"));
}

test "RECT is layout-compatible with the OS one" {
    // `put_Bounds` takes it BY VALUE. If this drifts from win32.zig's RECT the
    // browser process reads a rectangle out of the wrong 16 bytes.
    try testing.expectEqual(@sizeOf(std.os.windows.RECT), @sizeOf(RECT));
    try testing.expectEqual(@as(usize, 0), @offsetOf(RECT, "left"));
    try testing.expectEqual(@sizeOf(i32), @offsetOf(RECT, "top"));
    try testing.expectEqual(2 * @sizeOf(i32), @offsetOf(RECT, "right"));
    try testing.expectEqual(3 * @sizeOf(i32), @offsetOf(RECT, "bottom"));
}

test "the enums carry the values the runtime expects" {
    try testing.expectEqual(@as(i32, 0), @intFromEnum(MoveFocusReason.programmatic));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(PreferredColorScheme.auto));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(PreferredColorScheme.light));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(PreferredColorScheme.dark));
}
