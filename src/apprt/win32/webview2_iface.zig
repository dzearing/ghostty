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

/// `COREWEBVIEW2_KEY_EVENT_KIND`: which window message an
/// `AcceleratorKeyPressed` event stands for (T394). `system_key_down` is
/// WM_SYSKEYDOWN — an Alt chord — and counts as a press for forwarding.
pub const KeyEventKind = enum(i32) {
    key_down = 0,
    key_up = 1,
    system_key_down = 2,
    system_key_up = 3,
    /// The SDK enum is open-ended across runtime versions; an unknown kind
    /// must decode rather than trap, and is simply not a press.
    _,
};

/// `COREWEBVIEW2_PHYSICAL_KEY_STATUS`: the key-message LPARAM, unpacked by
/// the runtime so nobody re-derives bit 24 by hand.
pub const PhysicalKeyStatus = extern struct {
    RepeatCount: u32,
    ScanCode: u32,
    IsExtendedKey: BOOL,
    IsMenuKeyDown: BOOL,
    WasKeyDown: BOOL,
    IsKeyReleased: BOOL,
};

/// `COREWEBVIEW2_PREFERRED_COLOR_SCHEME`. `auto` follows the OS and is what an
/// older runtime without `ICoreWebView2_13` degrades to (T90a design §14).
pub const PreferredColorScheme = enum(i32) {
    auto = 0,
    light = 1,
    dark = 2,
};

/// `COREWEBVIEW2_WEB_RESOURCE_CONTEXT`. Only `all` is used: the bundled
/// template asks for a document, stylesheets, scripts and images, and one
/// filter that covers every kind is a smaller contract than five that have to
/// stay in sync with the page.
pub const WebResourceContext = enum(i32) {
    all = 0,
    document = 1,
    stylesheet = 2,
    image = 3,
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

// {AB00B74C-15F1-4646-80E8-E76341D25D71}
// `ICoreWebView2WebResourceRequestedEventHandler`.
pub const IID_WebResourceRequestedHandler: GUID = .{
    .Data1 = 0xAB00B74C,
    .Data2 = 0x15F1,
    .Data3 = 0x4646,
    .Data4 = .{ 0x80, 0xE8, 0xE7, 0x63, 0x41, 0xD2, 0x5D, 0x71 },
};

// {9ADBE429-F36D-432B-9DDC-F8881FBD76E3}
// `ICoreWebView2NavigationStartingEventHandler` (T392). Like every handler IID
// here, proven by the live test: the runtime QIs the handler for exactly this
// GUID before invoking it, so a wrong one is an event that never fires.
pub const IID_NavigationStartingHandler: GUID = .{
    .Data1 = 0x9ADBE429,
    .Data2 = 0xF36D,
    .Data3 = 0x432B,
    .Data4 = .{ 0x9D, 0xDC, 0xF8, 0x88, 0x1F, 0xBD, 0x76, 0xE3 },
};

// {DDFFE494-4942-4BD2-AB73-35B8FF40E19F}
// `ICoreWebView2NavigationStartingEventArgs3` — the revision that carries
// `NavigationKind`, QI'd for from the base args (T392). A runtime that
// predates it answers E_NOINTERFACE and the caller degrades to "kind
// unknown".
pub const IID_ICoreWebView2NavigationStartingEventArgs3: GUID = .{
    .Data1 = 0xDDFFE494,
    .Data2 = 0x4942,
    .Data3 = 0x4BD2,
    .Data4 = .{ 0xAB, 0x73, 0x35, 0xB8, 0xFF, 0x40, 0xE1, 0x9F },
};

// {D33A35BF-1C49-4F98-93AB-006E0533FE1C}
// `ICoreWebView2NavigationCompletedEventHandler`.
pub const IID_NavigationCompletedHandler: GUID = .{
    .Data1 = 0xD33A35BF,
    .Data2 = 0x1C49,
    .Data3 = 0x4F98,
    .Data4 = .{ 0x93, 0xAB, 0x00, 0x6E, 0x05, 0x33, 0xFE, 0x1C },
};

// {F5F2B923-953E-4042-9F95-F3A118E1AFD4}
// `ICoreWebView2DocumentTitleChangedEventHandler`. Its `Invoke` takes
// `(sender, args)` where the args are a bare `IUnknown` — the event carries no
// payload, and the title is read back off the sender.
pub const IID_DocumentTitleChangedHandler: GUID = .{
    .Data1 = 0xF5F2B923,
    .Data2 = 0x953E,
    .Data3 = 0x4042,
    .Data4 = .{ 0x9F, 0x95, 0xF3, 0xA1, 0x18, 0xE1, 0xAF, 0xD4 },
};

// {3C067F9F-5388-4772-8B48-79F7EF1AB37C}
// `ICoreWebView2SourceChangedEventHandler`. Its `Invoke` args carry only
// `IsNewDocument`, which we never read — the source itself is read back off
// the sender. Like every handler IID here, its correctness is PROVEN by the
// live test (the runtime QIs the handler for exactly this IID before ever
// invoking it, so a wrong GUID is an event that never fires).
pub const IID_SourceChangedHandler: GUID = .{
    .Data1 = 0x3C067F9F,
    .Data2 = 0x5388,
    .Data3 = 0x4772,
    .Data4 = .{ 0x8B, 0x48, 0x79, 0xF7, 0xEF, 0x1A, 0xB3, 0x7C },
};

// {C79A420C-EFD9-4058-9295-3E8B4BCAB645}
// `ICoreWebView2HistoryChangedEventHandler`. Args are a bare `IUnknown` — the
// event carries no payload; CanGoBack/CanGoForward are read off the sender.
pub const IID_HistoryChangedHandler: GUID = .{
    .Data1 = 0xC79A420C,
    .Data2 = 0xEFD9,
    .Data3 = 0x4058,
    .Data4 = .{ 0x92, 0x95, 0x3E, 0x8B, 0x4B, 0xCA, 0xB6, 0x45 },
};

// {49511172-CC67-4BCA-9923-137112F4C4CC}
// `ICoreWebView2ExecuteScriptCompletedHandler`.
pub const IID_ExecuteScriptCompletedHandler: GUID = .{
    .Data1 = 0x49511172,
    .Data2 = 0xCC67,
    .Data3 = 0x4BCA,
    .Data4 = .{ 0x99, 0x23, 0x13, 0x71, 0x12, 0xF4, 0xC4, 0xCC },
};

// {B29C7E28-FA79-41A8-8E44-65811C76DCB2}
// `ICoreWebView2AcceleratorKeyPressedEventHandler` (T394). Registered on the
// CONTROLLER, not the web view — its `Invoke` sender is the controller.
pub const IID_AcceleratorKeyPressedHandler: GUID = .{
    .Data1 = 0xB29C7E28,
    .Data2 = 0xFA79,
    .Data3 = 0x41A8,
    .Data4 = .{ 0x8E, 0x44, 0x65, 0x81, 0x1C, 0x76, 0xDC, 0xB2 },
};

// {9F760F8A-FB79-42BE-9990-7B56900FA9C7}
pub const IID_ICoreWebView2AcceleratorKeyPressedEventArgs: GUID = .{
    .Data1 = 0x9F760F8A,
    .Data2 = 0xFB79,
    .Data3 = 0x42BE,
    .Data4 = .{ 0x99, 0x90, 0x7B, 0x56, 0x90, 0x0F, 0xA9, 0xC7 },
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

// ------------------------------------------------------------------ IStream

/// `IStream`, the only shape `CreateWebResourceResponse` accepts for a
/// response body. Declared here rather than in `win32.zig` because this is the
/// only thing on the box that needs one, and it exists purely to hand bytes to
/// the browser process.
///
/// Fourteen slots: `IUnknown`, then `ISequentialStream`'s `Read`/`Write`, then
/// `IStream`'s own nine. Only `Write`, `Seek` and `Release` are called.
pub const IStream = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IStream, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IStream) callconv(.winapi) u32,
        Release: *const fn (*IStream) callconv(.winapi) u32,
        Read: *const anyopaque,
        Write: *const fn (*IStream, [*]const u8, u32, ?*u32) callconv(.winapi) HRESULT,
        /// `(LARGE_INTEGER move, DWORD origin, ULARGE_INTEGER *newPosition)`.
        /// The 64-bit displacement is a single register under the x64 ABI.
        Seek: *const fn (*IStream, i64, u32, ?*u64) callconv(.winapi) HRESULT,
        SetSize: *const anyopaque,
        CopyTo: *const anyopaque,
        Commit: *const anyopaque,
        Revert: *const anyopaque,
        LockRegion: *const anyopaque,
        UnlockRegion: *const anyopaque,
        Stat: *const anyopaque,
        Clone: *const anyopaque,
    };

    /// `STREAM_SEEK_SET`.
    pub const seek_set: u32 = 0;

    pub fn release(self: *IStream) void {
        _ = self.vtable.Release(self);
    }

    /// Append `bytes`. Partial writes are a failure here: a truncated response
    /// body renders as a corrupt page, which is worse than no page.
    pub fn writeAll(self: *IStream, bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        if (bytes.len > std.math.maxInt(u32)) return false;
        var written: u32 = 0;
        if (com.failed(self.vtable.Write(self, bytes.ptr, @intCast(bytes.len), &written))) return false;
        return written == bytes.len;
    }

    /// Rewind to the start. Non-optional: `CreateStreamOnHGlobal` leaves the
    /// seek pointer where `Write` left it — at the END — and a response whose
    /// stream starts there is a zero-byte body that reports success.
    pub fn rewind(self: *IStream) bool {
        return !com.failed(self.vtable.Seek(self, 0, seek_set, null));
    }
};

// ------------------------------------------ ICoreWebView2WebResourceRequest

/// The request being intercepted. We read the URI and nothing else — the
/// template only ever issues GETs for its own origin.
pub const ICoreWebView2WebResourceRequest = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebResourceRequest, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2WebResourceRequest) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2WebResourceRequest) callconv(.winapi) u32,
        get_Uri: *const fn (*ICoreWebView2WebResourceRequest, *?[*:0]u16) callconv(.winapi) HRESULT,
        put_Uri: *const anyopaque,
        get_Method: *const anyopaque,
        put_Method: *const anyopaque,
        get_Content: *const anyopaque,
        put_Content: *const anyopaque,
        get_Headers: *const anyopaque,
    };

    pub fn release(self: *ICoreWebView2WebResourceRequest) void {
        _ = self.vtable.Release(self);
    }

    /// The requested URL. Caller frees it with `CoTaskMemFree`.
    pub fn uriRaw(self: *ICoreWebView2WebResourceRequest) ?[*:0]u16 {
        var raw: ?[*:0]u16 = null;
        if (com.failed(self.vtable.get_Uri(self, &raw))) return null;
        return raw;
    }
};

// ----------------------------------------- ICoreWebView2WebResourceResponse

/// A response we built with `ICoreWebView2Environment::CreateWebResourceResponse`
/// and are about to hand back. Nothing is read off it; it is carried from the
/// factory to `put_Response` and released.
pub const ICoreWebView2WebResourceResponse = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebResourceResponse, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2WebResourceResponse) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2WebResourceResponse) callconv(.winapi) u32,
        get_Content: *const anyopaque,
        put_Content: *const anyopaque,
        get_Headers: *const anyopaque,
        get_StatusCode: *const anyopaque,
        put_StatusCode: *const anyopaque,
        get_ReasonPhrase: *const anyopaque,
        put_ReasonPhrase: *const anyopaque,
    };

    pub fn release(self: *ICoreWebView2WebResourceResponse) void {
        _ = self.vtable.Release(self);
    }
};

// ------------------------------- ICoreWebView2WebResourceRequestedEventArgs

/// One intercepted request. `GetDeferral` is declared opaque deliberately, for
/// the reason the new-window args give: an unused slot with a guessed
/// signature is a crash waiting for the day somebody calls it, and everything
/// this handler does is synchronous (read a file, build a response) so there
/// is nothing to defer.
pub const ICoreWebView2WebResourceRequestedEventArgs = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2WebResourceRequestedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2WebResourceRequestedEventArgs) callconv(.winapi) u32,
        get_Request: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, *?*ICoreWebView2WebResourceRequest) callconv(.winapi) HRESULT,
        get_Response: *const anyopaque,
        put_Response: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, *ICoreWebView2WebResourceResponse) callconv(.winapi) HRESULT,
        GetDeferral: *const anyopaque,
        get_ResourceContext: *const anyopaque,
    };

    /// The request. Caller owns the reference.
    pub fn request(self: *ICoreWebView2WebResourceRequestedEventArgs) ?*ICoreWebView2WebResourceRequest {
        var out: ?*ICoreWebView2WebResourceRequest = null;
        if (com.failed(self.vtable.get_Request(self, &out))) return null;
        return out;
    }

    /// Answer the request ourselves. Leaving this unset lets the request go to
    /// the network, which for our synthetic origin means a DNS failure.
    pub fn setResponse(
        self: *ICoreWebView2WebResourceRequestedEventArgs,
        response: *ICoreWebView2WebResourceResponse,
    ) bool {
        return !com.failed(self.vtable.put_Response(self, response));
    }
};

// --------------------------------- ICoreWebView2NavigationStartingEventArgs

/// `COREWEBVIEW2_NAVIGATION_KIND` (T392): what KIND of navigation is starting.
/// Lives on the Args3 revision; `viewer_content.NavKind` is its COM-free twin.
pub const NavigationKind = enum(i32) {
    reload = 0,
    back_or_forward = 1,
    new_document = 2,
    _,
};

/// A top-level navigation about to happen — the interception point link
/// routing lives on (T392). Ten slots; four are read/written: the URI, the
/// two provenance bits, and `put_Cancel`, which is what makes this event a
/// POLICY rather than a notification.
pub const ICoreWebView2NavigationStartingEventArgs = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2NavigationStartingEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2NavigationStartingEventArgs) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2NavigationStartingEventArgs) callconv(.winapi) u32,
        get_Uri: *const fn (*ICoreWebView2NavigationStartingEventArgs, *?[*:0]u16) callconv(.winapi) HRESULT,
        get_IsUserInitiated: *const fn (*ICoreWebView2NavigationStartingEventArgs, *BOOL) callconv(.winapi) HRESULT,
        get_IsRedirected: *const fn (*ICoreWebView2NavigationStartingEventArgs, *BOOL) callconv(.winapi) HRESULT,
        get_RequestHeaders: *const anyopaque,
        get_Cancel: *const anyopaque,
        put_Cancel: *const fn (*ICoreWebView2NavigationStartingEventArgs, BOOL) callconv(.winapi) HRESULT,
        get_NavigationId: *const anyopaque,
    };

    /// Where the navigation is going. Caller frees it with `CoTaskMemFree`.
    pub fn uriRaw(self: *ICoreWebView2NavigationStartingEventArgs) ?[*:0]u16 {
        var raw: ?[*:0]u16 = null;
        if (com.failed(self.vtable.get_Uri(self, &raw))) return null;
        return raw;
    }

    pub fn isUserInitiated(self: *ICoreWebView2NavigationStartingEventArgs) bool {
        var out: BOOL = 0;
        if (com.failed(self.vtable.get_IsUserInitiated(self, &out))) return false;
        return out != 0;
    }

    pub fn isRedirected(self: *ICoreWebView2NavigationStartingEventArgs) bool {
        var out: BOOL = 0;
        if (com.failed(self.vtable.get_IsRedirected(self, &out))) return false;
        return out != 0;
    }

    /// "Do not perform this navigation." The routed replacement (a browser, a
    /// split, a default app) is the handler's business, not the runtime's.
    pub fn setCancel(self: *ICoreWebView2NavigationStartingEventArgs, cancel: bool) bool {
        return !com.failed(self.vtable.put_Cancel(self, if (cancel) 1 else 0));
    }

    /// The Args3 view of this object, or null on a runtime that predates it.
    /// Caller owns the reference.
    pub fn queryArgs3(
        self: *ICoreWebView2NavigationStartingEventArgs,
    ) ?*ICoreWebView2NavigationStartingEventArgs3 {
        var out: ?*anyopaque = null;
        if (com.failed(self.vtable.QueryInterface(
            self,
            &IID_ICoreWebView2NavigationStartingEventArgs3,
            &out,
        ))) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }
};

/// The Args3 revision: the base ten slots, Args2's ancestor pair, then
/// `get_NavigationKind` — the one slot this exists for, because the KIND is
/// what separates a link activation from the pane's own reloads and history
/// walks (`viewer_content.routesAsLink`).
pub const ICoreWebView2NavigationStartingEventArgs3 = extern struct {
    vtable: *const Vtbl,

    /// Slots 3..9: the base interface's members past `IUnknown`.
    pub const base_slots = 7;
    /// Slots 10..11: Args2's `get_`/`put_AdditionalAllowedFrameAncestors`.
    pub const args2_slots = 2;

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2NavigationStartingEventArgs3, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2NavigationStartingEventArgs3) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2NavigationStartingEventArgs3) callconv(.winapi) u32,
        base: [base_slots]*const anyopaque,
        args2: [args2_slots]*const anyopaque,
        get_NavigationKind: *const fn (*ICoreWebView2NavigationStartingEventArgs3, *NavigationKind) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ICoreWebView2NavigationStartingEventArgs3) void {
        _ = self.vtable.Release(self);
    }

    pub fn navigationKind(self: *ICoreWebView2NavigationStartingEventArgs3) ?NavigationKind {
        var out: NavigationKind = .new_document;
        if (com.failed(self.vtable.get_NavigationKind(self, &out))) return null;
        return out;
    }
};

// -------------------------------- ICoreWebView2NavigationCompletedEventArgs

/// Whether the navigation that just finished actually loaded. Three slots
/// past `IUnknown`; only the first is read, because the file content injection
/// must not run on a page that failed to load.
pub const ICoreWebView2NavigationCompletedEventArgs = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2NavigationCompletedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2NavigationCompletedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2NavigationCompletedEventArgs) callconv(.winapi) u32,
        get_IsSuccess: *const fn (*ICoreWebView2NavigationCompletedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        get_WebErrorStatus: *const fn (*ICoreWebView2NavigationCompletedEventArgs, *u32) callconv(.winapi) HRESULT,
        get_NavigationId: *const anyopaque,
    };

    pub fn isSuccess(self: *ICoreWebView2NavigationCompletedEventArgs) bool {
        var out: BOOL = 0;
        if (com.failed(self.vtable.get_IsSuccess(self, &out))) return false;
        return out != 0;
    }

    /// WHY a failed navigation failed (`COREWEBVIEW2_WEB_ERROR_STATUS`, as
    /// its raw ordinal). Read for the log line alone: a navigation aborted
    /// by a newer one is routine, a genuine load failure is a defect, and a
    /// warn that cannot tell them apart sent T159's first live run chasing
    /// the wrong one.
    pub fn webErrorStatus(self: *ICoreWebView2NavigationCompletedEventArgs) ?u32 {
        var out: u32 = 0;
        if (com.failed(self.vtable.get_WebErrorStatus(self, &out))) return null;
        return out;
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
/// Declaring 58 slots of an interface that has 61 is safe and deliberate: the
/// vtable pointer is the runtime's, we only ever index the ones named here,
/// and a slot that is not declared cannot be called by mistake. The ones we do
/// not call are opaque — individually where a named neighbor makes the
/// position readable, and as one length-only block where there are dozens in a
/// row (`ICoreWebView2_13`'s rule, applied here).
///
/// T90e added the four file-mode slots — `add_NavigationCompleted` (15),
/// `ExecuteScript` (29), `add_WebResourceRequested` (55) and
/// `AddWebResourceRequestedFilter` (57) — which is why the opaque runs are
/// shorter again. T390 added `+reload`'s two: `Reload` (31) and
/// `CallDevToolsProtocolMethod` (36), T383 the title pair
/// `add_DocumentTitleChanged` (46) and `get_DocumentTitle` (48), and T392 the
/// link-routing interception `add_NavigationStarting` (7). Every block's
/// LENGTH is what holds the named slots in place, and `@offsetOf` asserts all
/// of them at the bottom of this file.
pub const ICoreWebView2 = extern struct {
    vtable: *const Vtbl,

    /// Slot 6: `NavigateToString`.
    pub const pre_nav_starting_slots = 1;
    /// Slots 8..10: `remove_NavigationStarting` through
    /// `remove_ContentLoading`.
    pub const post_nav_starting_slots = 3;
    /// Slot 12: `remove_SourceChanged`.
    pub const remove_source_slots = 1;
    /// Slot 14: `remove_HistoryChanged`.
    pub const remove_history_slots = 1;
    /// Slots 16..26: `remove_NavigationCompleted` through
    /// `remove_ProcessFailed`.
    pub const post_nav_slots = 11;
    /// Slot 28: `RemoveScriptToExecuteOnDocumentCreated`.
    pub const remove_script_slots = 1;
    /// Slot 30: `CapturePreview`.
    pub const capture_slots = 1;
    /// Slots 32..33: `PostWebMessageAsJson`, `PostWebMessageAsString`.
    pub const post_reload_slots = 2;
    /// Slot 35: `remove_WebMessageReceived`.
    pub const remove_message_slots = 1;
    /// Slot 37: `get_BrowserProcessId`.
    pub const browser_pid_slots = 1;
    /// Slots 42..43: `GetDevToolsProtocolEventReceiver`, `Stop`.
    pub const post_forward_slots = 2;
    /// Slot 45: `remove_NewWindowRequested`.
    pub const remove_new_window_slots = 1;
    /// Slot 47: `remove_DocumentTitleChanged`.
    pub const remove_title_slots = 1;
    /// Slots 49..54: `AddHostObjectToScript` through
    /// `get_ContainsFullScreenElement`.
    pub const post_title_slots = 6;
    /// Slot 56: `remove_WebResourceRequested`.
    pub const remove_resource_slots = 1;

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2) callconv(.winapi) u32,
        get_Settings: *const anyopaque,
        get_Source: *const fn (*ICoreWebView2, *?[*:0]u16) callconv(.winapi) HRESULT,
        Navigate: *const fn (*ICoreWebView2, [*:0]const u16) callconv(.winapi) HRESULT,
        pre_nav_starting: [pre_nav_starting_slots]*const anyopaque,
        add_NavigationStarting: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        post_nav_starting: [post_nav_starting_slots]*const anyopaque,
        add_SourceChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_source: [remove_source_slots]*const anyopaque,
        add_HistoryChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_history: [remove_history_slots]*const anyopaque,
        add_NavigationCompleted: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        post_nav: [post_nav_slots]*const anyopaque,
        AddScriptToExecuteOnDocumentCreated: *const fn (*ICoreWebView2, [*:0]const u16, *anyopaque) callconv(.winapi) HRESULT,
        remove_script: [remove_script_slots]*const anyopaque,
        ExecuteScript: *const fn (*ICoreWebView2, [*:0]const u16, ?*anyopaque) callconv(.winapi) HRESULT,
        capture: [capture_slots]*const anyopaque,
        Reload: *const fn (*ICoreWebView2) callconv(.winapi) HRESULT,
        post_reload: [post_reload_slots]*const anyopaque,
        add_WebMessageReceived: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_message: [remove_message_slots]*const anyopaque,
        CallDevToolsProtocolMethod: *const fn (
            *ICoreWebView2,
            [*:0]const u16,
            [*:0]const u16,
            ?*anyopaque,
        ) callconv(.winapi) HRESULT,
        browser_pid: [browser_pid_slots]*const anyopaque,
        get_CanGoBack: *const fn (*ICoreWebView2, *BOOL) callconv(.winapi) HRESULT,
        get_CanGoForward: *const fn (*ICoreWebView2, *BOOL) callconv(.winapi) HRESULT,
        GoBack: *const fn (*ICoreWebView2) callconv(.winapi) HRESULT,
        GoForward: *const fn (*ICoreWebView2) callconv(.winapi) HRESULT,
        post_forward: [post_forward_slots]*const anyopaque,
        add_NewWindowRequested: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_new_window: [remove_new_window_slots]*const anyopaque,
        add_DocumentTitleChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_title: [remove_title_slots]*const anyopaque,
        get_DocumentTitle: *const fn (*ICoreWebView2, *?[*:0]u16) callconv(.winapi) HRESULT,
        post_title: [post_title_slots]*const anyopaque,
        add_WebResourceRequested: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_resource: [remove_resource_slots]*const anyopaque,
        AddWebResourceRequestedFilter: *const fn (*ICoreWebView2, [*:0]const u16, WebResourceContext) callconv(.winapi) HRESULT,
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

    /// Subscribe to the Source property changing — every top-level document
    /// change, including back/forward and same-document moves. The win32
    /// analog of Mac's KVO on `webView.url`: what keeps the address field and
    /// the pane's mode honest about where the view actually IS (T159).
    pub fn addSourceChanged(self: *ICoreWebView2, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_SourceChanged(self, handler, &token));
    }

    /// Subscribe to the joint back/forward list changing — the runtime's own
    /// "re-read CanGoBack/CanGoForward now" signal (T159).
    pub fn addHistoryChanged(self: *ICoreWebView2, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_HistoryChanged(self, handler, &token));
    }

    /// Whether there is a page to go Back to. Null on failure — which the
    /// caller treats as false, a disabled button being the honest degrade.
    pub fn canGoBack(self: *ICoreWebView2) ?bool {
        var out: BOOL = 0;
        if (com.failed(self.vtable.get_CanGoBack(self, &out))) return null;
        return out != 0;
    }

    pub fn canGoForward(self: *ICoreWebView2) ?bool {
        var out: BOOL = 0;
        if (com.failed(self.vtable.get_CanGoForward(self, &out))) return null;
        return out != 0;
    }

    /// Navigate one entry back in this view's own history. A no-op (S_OK)
    /// when there is nowhere to go, per the API contract.
    pub fn goBack(self: *ICoreWebView2) bool {
        return !com.failed(self.vtable.GoBack(self));
    }

    pub fn goForward(self: *ICoreWebView2) bool {
        return !com.failed(self.vtable.GoForward(self));
    }

    /// Subscribe to `window.open()` / target=_blank. `handler` is one of OUR
    /// objects (a `com.Callback` instantiation), so it is typed as the opaque
    /// pointer COM needs and nothing more — same rule as
    /// `CreateCoreWebView2Controller`.
    pub fn addNewWindowRequested(self: *ICoreWebView2, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_NewWindowRequested(self, handler, &token));
    }

    /// Subscribe to `document.title` changing — including the title a page
    /// carries when it first loads, which arrives as a change from the empty
    /// string. This is the ONLY way a viewer learns a website's name; there is
    /// no "the load finished, go read the title" moment that beats it, because
    /// a page can retitle itself long after `NavigationCompleted`.
    pub fn addDocumentTitleChanged(self: *ICoreWebView2, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_DocumentTitleChanged(self, handler, &token));
    }

    /// The page's current `document.title`. Caller frees it with
    /// `CoTaskMemFree`, like every other string the runtime hands back.
    pub fn documentTitleRaw(self: *ICoreWebView2) ?[*:0]u16 {
        var raw: ?[*:0]u16 = null;
        if (com.failed(self.vtable.get_DocumentTitle(self, &raw))) return null;
        return raw;
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

    /// Subscribe to "a top-level navigation is about to start" — the policy
    /// point where file-mode link routing cancels and redirects (T392, Mac's
    /// `decidePolicyFor`).
    pub fn addNavigationStarting(self: *ICoreWebView2, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_NavigationStarting(self, handler, &token));
    }

    /// Subscribe to "a navigation finished". File mode injects the viewed
    /// file's content from here: the page's `window.__viewer` API does not
    /// exist until its own script has run.
    pub fn addNavigationCompleted(self: *ICoreWebView2, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_NavigationCompleted(self, handler, &token));
    }

    /// Subscribe to intercepted resource requests. Only requests matching a
    /// filter added by `addWebResourceRequestedFilter` are delivered — with no
    /// filter the event never fires, which is a silent no-op rather than an
    /// error, so the two calls belong together.
    pub fn addWebResourceRequested(self: *ICoreWebView2, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_WebResourceRequested(self, handler, &token));
    }

    /// Ask for `uri` (a `*` wildcard pattern) to be routed to the handler.
    pub fn addWebResourceRequestedFilter(
        self: *ICoreWebView2,
        uri: [*:0]const u16,
        context: WebResourceContext,
    ) bool {
        return !com.failed(self.vtable.AddWebResourceRequestedFilter(self, uri, context));
    }

    /// Run `js` in the current document. Asynchronous; `handler` may be null
    /// when the result and the failure are both uninteresting.
    pub fn executeScript(self: *ICoreWebView2, js: [*:0]const u16, handler: ?*anyopaque) bool {
        return !com.failed(self.vtable.ExecuteScript(self, js, handler));
    }

    /// A NORMAL reload — the browser revalidates and may serve its cache. Kept
    /// as the FALLBACK for `callDevToolsProtocolMethod` (design P8) rather than
    /// as the reload: `+reload` exists to pick up changes at the origin, and a
    /// cache hit is a wrong answer that is indistinguishable from a right one.
    pub fn reload(self: *ICoreWebView2) bool {
        return !com.failed(self.vtable.Reload(self));
    }

    /// Call one Chrome DevTools Protocol method (`Page.reload`, …) with its
    /// parameters as a JSON object. Asynchronous, and `handler` is optional the
    /// way `ExecuteScript`'s is — every caller here wants the side effect, not
    /// the return object.
    ///
    /// A failed HRESULT means the CALL was refused (an unknown method, a
    /// malformed parameter object); it is the caller's cue to fall back.
    pub fn callDevToolsProtocolMethod(
        self: *ICoreWebView2,
        method: [*:0]const u16,
        params_json: [*:0]const u16,
        handler: ?*anyopaque,
    ) bool {
        return !com.failed(self.vtable.CallDevToolsProtocolMethod(
            self,
            method,
            params_json,
            handler,
        ));
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

// ------------------------ ICoreWebView2AcceleratorKeyPressedEventArgs

/// One accelerator chord the browser saw before the page did (T394). The
/// slots are the IDL's, in order; `put_Handled(TRUE)` is what keeps the
/// browser from also acting on the key, and it must be decided inside the
/// `Invoke` — the browser process is blocked waiting on it.
pub const ICoreWebView2AcceleratorKeyPressedEventArgs = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs) callconv(.winapi) u32,
        get_KeyEventKind: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, *KeyEventKind) callconv(.winapi) HRESULT,
        get_VirtualKey: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, *u32) callconv(.winapi) HRESULT,
        get_KeyEventLParam: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, *i32) callconv(.winapi) HRESULT,
        get_PhysicalKeyStatus: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, *PhysicalKeyStatus) callconv(.winapi) HRESULT,
        get_Handled: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, *BOOL) callconv(.winapi) HRESULT,
        put_Handled: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, BOOL) callconv(.winapi) HRESULT,
    };

    pub fn keyEventKind(self: *ICoreWebView2AcceleratorKeyPressedEventArgs) ?KeyEventKind {
        var out: KeyEventKind = .key_down;
        if (com.failed(self.vtable.get_KeyEventKind(self, &out))) return null;
        return out;
    }

    pub fn virtualKey(self: *ICoreWebView2AcceleratorKeyPressedEventArgs) ?u32 {
        var out: u32 = 0;
        if (com.failed(self.vtable.get_VirtualKey(self, &out))) return null;
        return out;
    }

    pub fn physicalKeyStatus(self: *ICoreWebView2AcceleratorKeyPressedEventArgs) ?PhysicalKeyStatus {
        var out: PhysicalKeyStatus = std.mem.zeroes(PhysicalKeyStatus);
        if (com.failed(self.vtable.get_PhysicalKeyStatus(self, &out))) return null;
        return out;
    }

    pub fn setHandled(self: *ICoreWebView2AcceleratorKeyPressedEventArgs, handled: bool) bool {
        return !com.failed(self.vtable.put_Handled(self, if (handled) 1 else 0));
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
        get_ZoomFactor: *const fn (*ICoreWebView2Controller, *f64) callconv(.winapi) HRESULT,
        /// Host-driven page zoom (T161): the keyboard ctrl+plus/minus/0
        /// chords land here. 1.0 is 100%.
        put_ZoomFactor: *const fn (*ICoreWebView2Controller, f64) callconv(.winapi) HRESULT,
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
        /// T90a design §11's "bound chords keep working while Chromium holds
        /// focus" seam, wired by T394 (viewer app-keybind forwarding).
        add_AcceleratorKeyPressed: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_AcceleratorKeyPressed: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.winapi) HRESULT,
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

    /// Set the page-zoom factor (T161). 1.0 is 100%.
    pub fn setZoomFactor(self: *ICoreWebView2Controller, factor: f64) bool {
        return !com.failed(self.vtable.put_ZoomFactor(self, factor));
    }

    /// The current page-zoom factor, or null on failure.
    pub fn zoomFactor(self: *ICoreWebView2Controller) ?f64 {
        var out: f64 = 0;
        if (com.failed(self.vtable.get_ZoomFactor(self, &out))) return null;
        return out;
    }

    /// Register an `AcceleratorKeyPressed` handler (T394). The token is
    /// discarded for the same reason every other `add_*` here discards it:
    /// the handler lives exactly as long as the controller, and `Close`
    /// tears both down.
    pub fn addAcceleratorKeyPressed(self: *ICoreWebView2Controller, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_AcceleratorKeyPressed(self, handler, &token));
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
        /// `(IStream *content, int statusCode, LPCWSTR reasonPhrase,
        /// LPCWSTR headers, ICoreWebView2WebResourceResponse **response)`.
        CreateWebResourceResponse: *const fn (
            *ICoreWebView2Environment,
            ?*IStream,
            i32,
            [*:0]const u16,
            [*:0]const u16,
            *?*ICoreWebView2WebResourceResponse,
        ) callconv(.winapi) HRESULT,
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

    /// Build a response for an intercepted request. `headers` is a CRLF-joined
    /// block ("Content-Type: text/css"), which is the shape the runtime parses
    /// — not a single header and not a JSON object. Caller owns the result.
    pub fn createWebResourceResponse(
        self: *ICoreWebView2Environment,
        content: ?*IStream,
        status: i32,
        reason: [*:0]const u16,
        headers: [*:0]const u16,
    ) ?*ICoreWebView2WebResourceResponse {
        var out: ?*ICoreWebView2WebResourceResponse = null;
        if (com.failed(self.vtable.CreateWebResourceResponse(
            self,
            content,
            status,
            reason,
            headers,
            &out,
        ))) return null;
        return out;
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
    // 58 of ICoreWebView2's 61: everything through
    // `AddWebResourceRequestedFilter`. Declaring a PREFIX is the point — the
    // runtime's vtable is longer and the slots past the last one we name are
    // simply never indexed.
    try testing.expectEqual(58 * ptr, @sizeOf(ICoreWebView2.Vtbl));
    try testing.expectEqual(7 * ptr, @sizeOf(ICoreWebView2NewWindowRequestedEventArgs.Vtbl));
    try testing.expectEqual(6 * ptr, @sizeOf(ICoreWebView2WebMessageReceivedEventArgs.Vtbl));
    try testing.expectEqual(8 * ptr, @sizeOf(ICoreWebView2WebResourceRequestedEventArgs.Vtbl));
    try testing.expectEqual(10 * ptr, @sizeOf(ICoreWebView2WebResourceRequest.Vtbl));
    try testing.expectEqual(10 * ptr, @sizeOf(ICoreWebView2WebResourceResponse.Vtbl));
    try testing.expectEqual(6 * ptr, @sizeOf(ICoreWebView2NavigationCompletedEventArgs.Vtbl));
    try testing.expectEqual(14 * ptr, @sizeOf(IStream.Vtbl));
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
    // T161: the zoom pair drives keyboard page zoom.
    try testing.expectEqual(7 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "get_ZoomFactor"));
    try testing.expectEqual(8 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "put_ZoomFactor"));
    try testing.expectEqual(12 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "MoveFocus"));
    try testing.expectEqual(19 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "add_AcceleratorKeyPressed"));
    try testing.expectEqual(20 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "remove_AcceleratorKeyPressed"));
    try testing.expectEqual(23 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "NotifyParentWindowPositionChanged"));
    try testing.expectEqual(24 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "Close"));
    try testing.expectEqual(25 * ptr, @offsetOf(ICoreWebView2Controller.Vtbl, "get_CoreWebView2"));

    // Controller3's DPI pair sits AFTER Controller's 26 and Controller2's 2.
    try testing.expectEqual(29 * ptr, @offsetOf(ICoreWebView2Controller3.Vtbl, "put_RasterizationScale"));
    try testing.expectEqual(31 * ptr, @offsetOf(ICoreWebView2Controller3.Vtbl, "put_ShouldDetectMonitorScaleChanges"));

    // T394: the accelerator args' slots in IDL order, and the unpacked
    // LPARAM struct's exact size (2×UINT32 + 4×BOOL) — a padding surprise
    // here would misread every field after the scan code.
    try testing.expectEqual(3 * ptr, @offsetOf(ICoreWebView2AcceleratorKeyPressedEventArgs.Vtbl, "get_KeyEventKind"));
    try testing.expectEqual(6 * ptr, @offsetOf(ICoreWebView2AcceleratorKeyPressedEventArgs.Vtbl, "get_PhysicalKeyStatus"));
    try testing.expectEqual(8 * ptr, @offsetOf(ICoreWebView2AcceleratorKeyPressedEventArgs.Vtbl, "put_Handled"));
    try testing.expectEqual(@as(usize, 24), @sizeOf(PhysicalKeyStatus));

    // ICoreWebView2: the four slots we call. `Navigate` sits third among the
    // interface's own methods (after get_Settings/get_Source); the other three
    // sit behind opaque blocks whose LENGTHS exist to hold these numbers in
    // place. `add_NewWindowRequested` at 44 is the load-bearing one — it was
    // already asserted before the block was split into three, so it is the
    // check that says the split did not move anything.
    try testing.expectEqual(4 * ptr, @offsetOf(ICoreWebView2.Vtbl, "get_Source"));
    try testing.expectEqual(5 * ptr, @offsetOf(ICoreWebView2.Vtbl, "Navigate"));
    // T392's interception point, one slot past `NavigateToString`. The slot
    // after it is `remove_NavigationStarting`, a token-taking remove —
    // subscribing there would hand the runtime a handler pointer as an i64.
    try testing.expectEqual(7 * ptr, @offsetOf(ICoreWebView2.Vtbl, "add_NavigationStarting"));
    // T159's events, carved out of what used to be the one 9-slot `pre_nav`
    // run. `add_HistoryChanged` at 13 has `remove_SourceChanged` (a
    // token-taking remove) one slot before it — subscribing there would hand
    // the runtime a handler pointer as if it were an i64 token.
    try testing.expectEqual(11 * ptr, @offsetOf(ICoreWebView2.Vtbl, "add_SourceChanged"));
    try testing.expectEqual(13 * ptr, @offsetOf(ICoreWebView2.Vtbl, "add_HistoryChanged"));
    try testing.expectEqual(15 * ptr, @offsetOf(ICoreWebView2.Vtbl, "add_NavigationCompleted"));
    try testing.expectEqual(27 * ptr, @offsetOf(ICoreWebView2.Vtbl, "AddScriptToExecuteOnDocumentCreated"));
    try testing.expectEqual(29 * ptr, @offsetOf(ICoreWebView2.Vtbl, "ExecuteScript"));
    // T390's two. `Reload` (31) is one slot past `CapturePreview`, and
    // `CallDevToolsProtocolMethod` (36) one past `remove_WebMessageReceived` —
    // both were inside opaque runs until now, so these two numbers are exactly
    // what the run-splitting had to preserve. Calling `Reload` at 36's index
    // would hand the runtime a method name and a JSON string as if they were
    // nothing, which is the kind of mistake that corrupts rather than fails.
    try testing.expectEqual(31 * ptr, @offsetOf(ICoreWebView2.Vtbl, "Reload"));
    try testing.expectEqual(34 * ptr, @offsetOf(ICoreWebView2.Vtbl, "add_WebMessageReceived"));
    try testing.expectEqual(36 * ptr, @offsetOf(ICoreWebView2.Vtbl, "CallDevToolsProtocolMethod"));
    // T159's history quartet, out of the old 7-slot `post_devtools` run. The
    // getters take a BOOL out-param and the Go pair take nothing, so a
    // one-off here reads as a navigation that silently does not happen.
    try testing.expectEqual(38 * ptr, @offsetOf(ICoreWebView2.Vtbl, "get_CanGoBack"));
    try testing.expectEqual(39 * ptr, @offsetOf(ICoreWebView2.Vtbl, "get_CanGoForward"));
    try testing.expectEqual(40 * ptr, @offsetOf(ICoreWebView2.Vtbl, "GoBack"));
    try testing.expectEqual(41 * ptr, @offsetOf(ICoreWebView2.Vtbl, "GoForward"));
    try testing.expectEqual(44 * ptr, @offsetOf(ICoreWebView2.Vtbl, "add_NewWindowRequested"));
    // T383's pair, carved out of what used to be one 10-slot `window` run.
    // `get_DocumentTitle` (48) is a getter with an out-parameter, so calling it
    // at the wrong index writes a COM-heap pointer into whatever that slot's
    // real second argument is — silence, then a `CoTaskMemFree` on a value the
    // runtime never allocated.
    try testing.expectEqual(46 * ptr, @offsetOf(ICoreWebView2.Vtbl, "add_DocumentTitleChanged"));
    try testing.expectEqual(48 * ptr, @offsetOf(ICoreWebView2.Vtbl, "get_DocumentTitle"));
    try testing.expectEqual(55 * ptr, @offsetOf(ICoreWebView2.Vtbl, "add_WebResourceRequested"));
    try testing.expectEqual(57 * ptr, @offsetOf(ICoreWebView2.Vtbl, "AddWebResourceRequestedFilter"));

    // The resource-request trio: read the URI off the request, then hand back
    // a response built by the environment's factory (slot 4, right after the
    // controller factory).
    try testing.expectEqual(3 * ptr, @offsetOf(ICoreWebView2WebResourceRequestedEventArgs.Vtbl, "get_Request"));
    try testing.expectEqual(5 * ptr, @offsetOf(ICoreWebView2WebResourceRequestedEventArgs.Vtbl, "put_Response"));
    try testing.expectEqual(3 * ptr, @offsetOf(ICoreWebView2WebResourceRequest.Vtbl, "get_Uri"));
    try testing.expectEqual(4 * ptr, @offsetOf(ICoreWebView2Environment.Vtbl, "CreateWebResourceResponse"));

    // Navigation-completed: only "did it load" is read, and it is slot 3.
    try testing.expectEqual(3 * ptr, @offsetOf(ICoreWebView2NavigationCompletedEventArgs.Vtbl, "get_IsSuccess"));

    // Navigation-starting (T392): the URI, the two provenance bits, and the
    // cancel that makes the event a policy. `put_Cancel` at 8 has `get_Cancel`
    // one slot before it — writing through the getter's slot would pass a BOOL
    // where the runtime expects a pointer to write through.
    try testing.expectEqual(
        10 * ptr,
        @sizeOf(ICoreWebView2NavigationStartingEventArgs.Vtbl),
    );
    try testing.expectEqual(3 * ptr, @offsetOf(ICoreWebView2NavigationStartingEventArgs.Vtbl, "get_Uri"));
    try testing.expectEqual(4 * ptr, @offsetOf(ICoreWebView2NavigationStartingEventArgs.Vtbl, "get_IsUserInitiated"));
    try testing.expectEqual(5 * ptr, @offsetOf(ICoreWebView2NavigationStartingEventArgs.Vtbl, "get_IsRedirected"));
    try testing.expectEqual(8 * ptr, @offsetOf(ICoreWebView2NavigationStartingEventArgs.Vtbl, "put_Cancel"));
    // Args3: the kind getter is the last slot — base ten, Args2's two, then it.
    try testing.expectEqual(
        13 * ptr,
        @sizeOf(ICoreWebView2NavigationStartingEventArgs3.Vtbl),
    );
    try testing.expectEqual(12 * ptr, @offsetOf(ICoreWebView2NavigationStartingEventArgs3.Vtbl, "get_NavigationKind"));

    // IStream: `Write` is ISequentialStream's second method, `Seek` is
    // IStream's first. Getting these two the wrong way round would call Read
    // with write arguments.
    try testing.expectEqual(4 * ptr, @offsetOf(IStream.Vtbl, "Write"));
    try testing.expectEqual(5 * ptr, @offsetOf(IStream.Vtbl, "Seek"));

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
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2WebResourceRequestedEventArgs, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2WebResourceRequest, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2WebResourceResponse, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2NavigationCompletedEventArgs, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2NavigationStartingEventArgs, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2NavigationStartingEventArgs3, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(IStream, "vtable"));
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
    // `all` is the value the pane's one filter is registered with; a nonzero
    // value here would filter the document out of its own interception.
    try testing.expectEqual(@as(i32, 0), @intFromEnum(WebResourceContext.all));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(WebResourceContext.document));
    // `COREWEBVIEW2_NAVIGATION_KIND` (T392): routing keys on `new_document`,
    // so these three numbers are the difference between routing a link and
    // cancelling every reload.
    try testing.expectEqual(@as(i32, 0), @intFromEnum(NavigationKind.reload));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(NavigationKind.back_or_forward));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(NavigationKind.new_document));
}
