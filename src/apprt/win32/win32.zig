//! Vendored from InsipidPoint/ghostty-windows (MIT, same license as upstream
//! Ghostty) and adapted for the Ghoztty fork (branding, fork apprt actions).
//! Win32 API type definitions and extern function declarations.
//! These supplement what is available in std.os.windows.

const std = @import("std");

// Re-export commonly used types from std
pub const HWND = std.os.windows.HWND;
pub const HINSTANCE = std.os.windows.HINSTANCE;
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
pub const HMENU = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};

pub const POINT = extern struct {
    x: i32,
    y: i32,
};

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: POINT,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: *const fn (HWND, u32, usize, isize) callconv(.winapi) isize,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON,
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16,
    nVersion: u16,
    dwFlags: u32,
    iPixelType: u8,
    cColorBits: u8,
    cRedBits: u8,
    cRedShift: u8,
    cGreenBits: u8,
    cGreenShift: u8,
    cBlueBits: u8,
    cBlueShift: u8,
    cAlphaBits: u8,
    cAlphaShift: u8,
    cAccumBits: u8,
    cAccumRedBits: u8,
    cAccumGreenBits: u8,
    cAccumBlueBits: u8,
    cAccumAlphaBits: u8,
    cDepthBits: u8,
    cStencilBits: u8,
    cAuxBuffers: u8,
    iLayerType: u8,
    bReserved: u8,
    dwLayerMask: u32,
    dwVisibleMask: u32,
    dwDamageMask: u32,
};

// Window class styles
pub const CS_HREDRAW: u32 = 0x0002;
pub const CS_VREDRAW: u32 = 0x0001;
pub const CS_OWNDC: u32 = 0x0020;
pub const CS_DBLCLKS: u32 = 0x0008;

// Window styles
pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
pub const WS_POPUP: u32 = 0x80000000;
pub const WS_CAPTION: u32 = 0x00C00000;
pub const WS_THICKFRAME: u32 = 0x00040000;
pub const WS_SYSMENU: u32 = 0x00080000;

// Extended window styles
pub const WS_EX_LAYERED: u32 = 0x00080000;
pub const WS_EX_TOOLWINDOW: u32 = 0x00000080;
pub const WS_EX_DLGMODALFRAME: u32 = 0x00000001;

// Layered window flags
pub const LWA_ALPHA: u32 = 0x00000002;

// Window long indices
pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;

// SetWindowPos flags
pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_FRAMECHANGED: u32 = 0x0020;

// MonitorFromWindow flags
pub const MONITOR_DEFAULTTONEAREST: u32 = 0x00000002;
/// Return NULL when the point/rect is on no monitor — which makes
/// `MonitorFromRect` a "does this rectangle touch any screen?" query (T336).
pub const MONITOR_DEFAULTTONULL: u32 = 0x00000000;

pub const HMONITOR = *opaque {};

pub const MONITORINFO = extern struct {
    cbSize: u32,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: u32,
};

// Window messages
pub const WM_USER: u32 = 0x0400;
pub const WM_APP: u32 = 0x8000;
pub const WM_QUIT: u32 = 0x0012;
/// A message with no effect. Posted purely to make a thread's queue tick —
/// the second half of the MSDN "menu does not dismiss" workaround.
pub const WM_NULL: u32 = 0x0000;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_QUERYENDSESSION: u32 = 0x0011;
pub const WM_ENDSESSION: u32 = 0x0016;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
// WM_SIZE wParam values.
pub const SIZE_RESTORED: usize = 0;
pub const SIZE_MINIMIZED: usize = 1;
pub const SIZE_MAXIMIZED: usize = 2;
pub const WM_MOVE: u32 = 0x0003;
pub const WM_SETFOCUS: u32 = 0x0007;
pub const WM_KILLFOCUS: u32 = 0x0008;
pub const WM_GETOBJECT: u32 = 0x003D;
/// MSAA object IDs queried via WM_GETOBJECT lparam. OBJID_CLIENT is the
/// main one — returning 0 (not -4 as some docs suggest) before reaching
/// DefWindowProc skips the oleacc default proxy that otherwise causes
/// re-entrant focus / IME deadlocks under our multi-HWND split layout.
/// Typed as isize so it compares cleanly with the LPARAM the WindowProc
/// receives.
pub const OBJID_CLIENT: isize = -4;
pub const WM_ERASEBKGND: u32 = 0x0014;
pub const WM_PAINT: u32 = 0x000F;
/// "Draw yourself into THIS dc, right now." `PrintWindow` sends it, and a
/// window that answers it can be captured exactly and synchronously — the
/// DWM `PW_RENDERFULLCONTENT` path is asynchronous and hands back torn
/// frames instead (T835).
pub const WM_PRINTCLIENT: u32 = 0x0318;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_ENTERSIZEMOVE: u32 = 0x0231;
pub const WM_EXITSIZEMOVE: u32 = 0x0232;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_CHAR: u32 = 0x0102;
/// Suppress a control's own repainting while a batch of changes is applied,
/// then turn it back on. The control does NOT repaint itself on the way back,
/// so an `InvalidateRect` has to follow.
pub const WM_SETREDRAW: u32 = 0x000B;
pub const WM_PASTE: u32 = 0x0302;
pub const WM_DEADCHAR: u32 = 0x0103;
pub const WM_SYSKEYDOWN: u32 = 0x0104;
pub const WM_SYSKEYUP: u32 = 0x0105;
pub const WM_SYSCHAR: u32 = 0x0106;
pub const WM_SYSDEADCHAR: u32 = 0x0107;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_LBUTTONDBLCLK: u32 = 0x0203;
pub const WM_RBUTTONDOWN: u32 = 0x0204;
pub const WM_RBUTTONUP: u32 = 0x0205;
pub const WM_MBUTTONDOWN: u32 = 0x0207;
pub const WM_MBUTTONUP: u32 = 0x0208;
pub const WM_XBUTTONDOWN: u32 = 0x020B;
pub const WM_XBUTTONUP: u32 = 0x020C;
// GET_XBUTTON_WPARAM(wParam) high word values.
pub const XBUTTON1: usize = 0x0001; // "Back"
pub const XBUTTON2: usize = 0x0002; // "Forward"
pub const WM_MOUSEWHEEL: u32 = 0x020A;
pub const WM_MOUSEHWHEEL: u32 = 0x020E;
pub const WM_CONTEXTMENU: u32 = 0x007B;
// Mouse-message wparam modifier bits (queue-synchronized key state — the
// authoritative mods for that click, unlike GetKeyState which reads the
// thread's current state and never sees posted/synthetic messages).
pub const MK_SHIFT: usize = 0x0004;
pub const MK_CONTROL: usize = 0x0008;
pub const WM_SETCURSOR: u32 = 0x0020;
pub const WM_DPICHANGED: u32 = 0x02E0;

// WM_SETCURSOR hit-test values
pub const HTCLIENT: u16 = 1;
pub const WM_NCHITTEST: u32 = 0x0084;
/// WM_NCHITTEST return: pass the hit to the next window in the same
/// thread (siblings below in z-order, then the parent).
pub const HTTRANSPARENT: isize = -1;

// --- Custom caption bar (T254) ----------------------------------------------
//
// `WM_NCCALCSIZE` hands the caption band to the client area, so everything
// that used to be DWM's job (paint, hover, click, the resize edge along the
// top) becomes ours. Returning a non-`HTCLIENT` code from `WM_NCHITTEST` is
// what makes Windows route NC mouse messages to those client pixels, and
// returning `HTMAXBUTTON` in particular is what keeps the Snap Layouts flyout
// working — the OS watches for that hit-test code, not for a real button.
pub const HTCAPTION: isize = 2;
pub const HTSYSMENU: isize = 3;
pub const HTMINBUTTON: isize = 8;
pub const HTMAXBUTTON: isize = 9;
pub const HTTOP: isize = 12;
pub const HTTOPLEFT: isize = 13;
pub const HTTOPRIGHT: isize = 14;
pub const HTCLOSE: isize = 20;
/// "An object in the non-client area" — Windows' own code for a caption
/// control that is not one of the system's. `DefWindowProc` attaches no
/// behavior to it, which is exactly what an app-owned control wants: the NC
/// mouse messages arrive and nothing else happens behind our back. The remote
/// connection pill (T367) uses it.
pub const HTOBJECT: isize = 19;

pub const WM_NCCALCSIZE: u32 = 0x0083;
pub const WM_NCMOUSEMOVE: u32 = 0x00A0;
pub const WM_NCLBUTTONDOWN: u32 = 0x00A1;
pub const WM_NCLBUTTONUP: u32 = 0x00A2;
pub const WM_NCLBUTTONDBLCLK: u32 = 0x00A3;
pub const WM_NCMOUSELEAVE: u32 = 0x02A2;

pub const WM_SYSCOMMAND: u32 = 0x0112;
pub const SC_SIZE: usize = 0xF000;
pub const SC_MOVE: usize = 0xF010;
pub const SC_MINIMIZE: usize = 0xF020;
pub const SC_MAXIMIZE: usize = 0xF030;
pub const SC_CLOSE: usize = 0xF060;
pub const SC_RESTORE: usize = 0xF120;
/// wparam low 4 bits are flags on some SC_* values; mask before comparing.
pub const SC_MASK: usize = 0xFFF0;

/// `TRACKMOUSEEVENT.dwFlags` bit that asks for `WM_NCMOUSELEAVE` rather than
/// `WM_MOUSELEAVE`. Without it a hover on a caption button never un-hovers,
/// because the band's pixels are client but its mouse messages are NC.
pub const TME_NONCLIENT: u32 = 0x00000010;

pub const SM_CYSIZEFRAME: i32 = 33;
pub const SM_CXPADDEDBORDER: i32 = 92;

/// The parameter block `WM_NCCALCSIZE` passes in `lparam` when `wparam` is
/// TRUE. `rgrc[0]` goes in as the proposed WINDOW rect and comes out as the
/// new CLIENT rect.
pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: ?*anyopaque,
};

/// DPI-aware `GetSystemMetrics`. The frame thickness we hand back to the
/// resize edge has to be the one for THIS window's DPI, not the primary
/// monitor's — a window dragged to a 200% display would otherwise get a
/// 100%-sized grab band. Windows 10 1607+, which this app already requires
/// (the per-monitor-v2 DPI awareness it runs under arrived in the same
/// release), so it is imported statically like the rest of user32.
pub extern "user32" fn GetSystemMetricsForDpi(
    nIndex: i32,
    dpi: u32,
) callconv(.winapi) i32;

// IME messages
pub const WM_IME_STARTCOMPOSITION: u32 = 0x010D;
pub const WM_IME_ENDCOMPOSITION: u32 = 0x010E;
pub const WM_IME_COMPOSITION: u32 = 0x010F;
pub const WM_IME_SETCONTEXT: u32 = 0x0281;
// WM_IME_SETCONTEXT lparam bit: show the default composition window.
pub const ISC_SHOWUICOMPOSITIONWINDOW: isize = 0x80000000;

// IME composition string flags
pub const GCS_COMPSTR: u32 = 0x0008;
pub const GCS_RESULTSTR: u32 = 0x0800;

// IME composition form styles
pub const CFS_POINT: u32 = 0x0002;

// Virtual key codes
pub const VK_PROCESSKEY: u16 = 0xE5;
pub const VK_PACKET: u16 = 0xE7;
pub const VK_BACK: u16 = 0x08;
pub const VK_LBUTTON: u16 = 0x01;
pub const VK_TAB: u16 = 0x09;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_SHIFT: u16 = 0x10;
pub const VK_CONTROL: u16 = 0x11;
pub const VK_MENU: u16 = 0x12; // Alt key
pub const VK_PAUSE: u16 = 0x13;
pub const VK_CAPITAL: u16 = 0x14; // Caps Lock
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_SPACE: u16 = 0x20;
pub const VK_PRIOR: u16 = 0x21; // Page Up
pub const VK_NEXT: u16 = 0x22; // Page Down
pub const VK_END: u16 = 0x23;
pub const VK_HOME: u16 = 0x24;
pub const VK_LEFT: u16 = 0x25;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;
pub const VK_INSERT: u16 = 0x2D;
pub const VK_DELETE: u16 = 0x2E;
// 0-9 keys are 0x30-0x39 (same as ASCII)
// A-Z keys are 0x41-0x5A (same as ASCII uppercase)
pub const VK_LWIN: u16 = 0x5B;
pub const VK_RWIN: u16 = 0x5C;
pub const VK_APPS: u16 = 0x5D; // Context menu key
pub const VK_NUMPAD0: u16 = 0x60;
pub const VK_NUMPAD1: u16 = 0x61;
pub const VK_NUMPAD2: u16 = 0x62;
pub const VK_NUMPAD3: u16 = 0x63;
pub const VK_NUMPAD4: u16 = 0x64;
pub const VK_NUMPAD5: u16 = 0x65;
pub const VK_NUMPAD6: u16 = 0x66;
pub const VK_NUMPAD7: u16 = 0x67;
pub const VK_NUMPAD8: u16 = 0x68;
pub const VK_NUMPAD9: u16 = 0x69;
pub const VK_MULTIPLY: u16 = 0x6A;
pub const VK_ADD: u16 = 0x6B;
pub const VK_SEPARATOR: u16 = 0x6C;
pub const VK_SUBTRACT: u16 = 0x6D;
pub const VK_DECIMAL: u16 = 0x6E;
pub const VK_DIVIDE: u16 = 0x6F;
pub const VK_F1: u16 = 0x70;
pub const VK_F2: u16 = 0x71;
pub const VK_F3: u16 = 0x72;
pub const VK_F4: u16 = 0x73;
pub const VK_F5: u16 = 0x74;
pub const VK_F6: u16 = 0x75;
pub const VK_F7: u16 = 0x76;
pub const VK_F8: u16 = 0x77;
pub const VK_F9: u16 = 0x78;
pub const VK_F10: u16 = 0x79;
pub const VK_F11: u16 = 0x7A;
pub const VK_F12: u16 = 0x7B;
pub const VK_F13: u16 = 0x7C;
pub const VK_F14: u16 = 0x7D;
pub const VK_F15: u16 = 0x7E;
pub const VK_F16: u16 = 0x7F;
pub const VK_F17: u16 = 0x80;
pub const VK_F18: u16 = 0x81;
pub const VK_F19: u16 = 0x82;
pub const VK_F20: u16 = 0x83;
pub const VK_F21: u16 = 0x84;
pub const VK_F22: u16 = 0x85;
pub const VK_F23: u16 = 0x86;
pub const VK_F24: u16 = 0x87;
pub const VK_NUMLOCK: u16 = 0x90;
pub const VK_SCROLL: u16 = 0x91;
pub const VK_LSHIFT: u16 = 0xA0;
pub const VK_RSHIFT: u16 = 0xA1;
pub const VK_LCONTROL: u16 = 0xA2;
pub const VK_RCONTROL: u16 = 0xA3;
pub const VK_LMENU: u16 = 0xA4;
pub const VK_RMENU: u16 = 0xA5;
pub const VK_OEM_1: u16 = 0xBA; // ';:' on US
pub const VK_OEM_PLUS: u16 = 0xBB; // '=+' on US
pub const VK_OEM_COMMA: u16 = 0xBC; // ',<' on US
pub const VK_OEM_MINUS: u16 = 0xBD; // '-_' on US
pub const VK_OEM_PERIOD: u16 = 0xBE; // '.>' on US
pub const VK_OEM_2: u16 = 0xBF; // '/?' on US
pub const VK_OEM_3: u16 = 0xC0; // '`~' on US
pub const VK_OEM_4: u16 = 0xDB; // '[{' on US
pub const VK_OEM_5: u16 = 0xDC; // '\|' on US
pub const VK_OEM_6: u16 = 0xDD; // ']}' on US
pub const VK_OEM_7: u16 = 0xDE; // ''"' on US

// WHEEL_DELTA for mouse wheel normalization
pub const WHEEL_DELTA: i16 = 120;

// Show window commands
pub const SW_HIDE: i32 = 0;
pub const SW_SHOW: i32 = 5;
/// Show without activating — a chrome bar revealing itself must never steal
/// keyboard focus from the content it sits above.
pub const SW_SHOWNA: i32 = 8;
pub const SW_MAXIMIZE: i32 = 3;
pub const SW_RESTORE: i32 = 9;

// Font weight constants
pub const FW_NORMAL: i32 = 400;

// Character set constants
pub const DEFAULT_CHARSET: u32 = 1;

// Window long pointer indices
pub const GWLP_USERDATA: i32 = -21;

// HWND_MESSAGE for message-only windows
pub const HWND_MESSAGE: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

// Pixel format descriptor flags
pub const PFD_DRAW_TO_WINDOW: u32 = 0x00000004;
pub const PFD_SUPPORT_OPENGL: u32 = 0x00000020;
pub const PFD_DOUBLEBUFFER: u32 = 0x00000001;
pub const PFD_TYPE_RGBA: u8 = 0;

// CreateWindowEx defaults
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

// Standard icon IDs (MAKEINTRESOURCE values)
pub const IDI_APPLICATION: usize = 32512;

/// Resource ID of the application icon (matches ID_ICON_GHOSTTY in
/// dist/windows/ghostty.rc).
pub const IDI_GHOSTTY: usize = 1;

// SetClassLongPtrW indices (used to swap the class-level background
// brush after a config or OSC color change).
pub const GCLP_HBRBACKGROUND: i32 = -10;

pub extern "user32" fn SetClassLongPtrW(
    hWnd: HWND,
    nIndex: i32,
    dwNewLong: isize,
) callconv(.winapi) isize;

pub extern "user32" fn LoadIconW(
    hInstance: ?HINSTANCE,
    lpIconName: usize,
) callconv(.winapi) ?HICON;

// Standard system icon IDs (MAKEINTRESOURCE values) for LoadIconW(null, ...).
pub const IDI_WARNING: usize = 32515; // IDI_EXCLAMATION
pub const IDI_INFORMATION: usize = 32516; // IDI_ASTERISK

pub const DI_NORMAL: u32 = 0x0003;

pub extern "user32" fn DrawIconEx(
    hdc: HDC,
    xLeft: i32,
    yTop: i32,
    hIcon: HICON,
    cxWidth: i32,
    cyWidth: i32,
    istepIfAniCur: u32,
    hbrFlickerFreeDraw: ?HBRUSH,
    diFlags: u32,
) callconv(.winapi) i32;

// Standard cursor IDs (MAKEINTRESOURCE values)
pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;

// -----------------------------------------------------------------------
// Win32 API extern declarations
// -----------------------------------------------------------------------

pub extern "user32" fn RegisterClassExW(
    *const WNDCLASSEXW,
) callconv(.winapi) u16;

pub extern "user32" fn UnregisterClassW(
    lpClassName: [*:0]const u16,
    hInstance: ?HINSTANCE,
) callconv(.winapi) i32;

pub extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: u32,
    x: i32,
    y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;

pub extern "user32" fn ShowWindow(
    hWnd: HWND,
    nCmdShow: i32,
) callconv(.winapi) i32;

pub extern "user32" fn IsWindowVisible(
    hWnd: HWND,
) callconv(.winapi) i32;

pub extern "user32" fn IsWindow(
    hWnd: ?HWND,
) callconv(.winapi) i32;

pub extern "user32" fn UpdateWindow(
    hWnd: HWND,
) callconv(.winapi) i32;

/// Render the window's full content, including a DirectComposition/layered
/// surface a plain `PrintWindow` would miss. The only capture that works on a
/// BACKGROUND desktop — DWM composes the input desktop only, so a `BitBlt` off
/// the desktop DC returns false there (see `test/win32/lib/TestDesktop.ps1`'s
/// CAPTURE LIMIT header, and `hover_capture.zig` for the T282 use).
pub const PW_RENDERFULLCONTENT: u32 = 0x00000002;

pub extern "user32" fn PrintWindow(
    hWnd: HWND,
    hdcBlt: HDC,
    nFlags: u32,
) callconv(.winapi) i32;

pub extern "user32" fn GetMessageW(
    lpMsg: *MSG,
    hWnd: ?HWND,
    wMsgFilterMin: u32,
    wMsgFilterMax: u32,
) callconv(.winapi) i32;

pub const PM_REMOVE: u32 = 0x0001;

pub extern "user32" fn PeekMessageW(
    lpMsg: *MSG,
    hWnd: ?HWND,
    wMsgFilterMin: u32,
    wMsgFilterMax: u32,
    wRemoveMsg: u32,
) callconv(.winapi) i32;

pub extern "user32" fn TranslateMessage(
    lpMsg: *const MSG,
) callconv(.winapi) i32;

pub extern "user32" fn DispatchMessageW(
    lpMsg: *const MSG,
) callconv(.winapi) isize;

pub extern "user32" fn PostMessageW(
    hWnd: HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
) callconv(.winapi) i32;

pub extern "user32" fn DestroyWindow(
    hWnd: HWND,
) callconv(.winapi) i32;

pub extern "user32" fn DefWindowProcW(
    hWnd: HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
) callconv(.winapi) isize;

pub extern "user32" fn PostQuitMessage(
    nExitCode: i32,
) callconv(.winapi) void;

pub extern "user32" fn GetClientRect(
    hWnd: HWND,
    lpRect: *RECT,
) callconv(.winapi) i32;

pub extern "user32" fn GetDC(
    hWnd: ?HWND,
) callconv(.winapi) ?HDC;

pub extern "user32" fn ReleaseDC(
    hWnd: ?HWND,
    hDC: HDC,
) callconv(.winapi) i32;

pub extern "user32" fn SetWindowLongPtrW(
    hWnd: HWND,
    nIndex: i32,
    dwNewLong: isize,
) callconv(.winapi) isize;

pub extern "user32" fn GetWindowLongPtrW(
    hWnd: HWND,
    nIndex: i32,
) callconv(.winapi) isize;

// Safe only for 16-bit GCW_* indices (e.g. GCW_ATOM). For pointer-sized
// GCLP_* indices use GetClassLongPtrW.
pub extern "user32" fn GetClassLongW(
    hWnd: HWND,
    nIndex: i32,
) callconv(.winapi) u32;

pub const GCW_ATOM: i32 = -32;

/// Window-proc slot, for subclassing a system control (T172: the chooser's
/// LISTBOX, to get hover feedback the parent never sees).
pub const GWLP_WNDPROC: i32 = -4;

pub extern "user32" fn CallWindowProcW(
    lpPrevWndFunc: *const anyopaque,
    hWnd: HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
) callconv(.winapi) isize;

pub const GetCursorPos_ = struct {
    extern "user32" fn GetCursorPos(
        lpPoint: *POINT,
    ) callconv(.winapi) i32;
}.GetCursorPos;

pub extern "user32" fn ScreenToClient(
    hWnd: HWND,
    lpPoint: *POINT,
) callconv(.winapi) i32;

pub extern "user32" fn ClientToScreen(
    hWnd: HWND,
    lpPoint: *POINT,
) callconv(.winapi) i32;

pub extern "user32" fn IsIconic(hwnd: HWND) callconv(.winapi) i32;

pub extern "user32" fn GetParent(
    hWnd: HWND,
) callconv(.winapi) ?HWND;

pub extern "user32" fn GetClassNameW(
    hWnd: HWND,
    lpClassName: [*]u16,
    nMaxCount: i32,
) callconv(.winapi) i32;

pub extern "user32" fn AdjustWindowRectEx(
    lpRect: *RECT,
    dwStyle: u32,
    bMenu: i32,
    dwExStyle: u32,
) callconv(.winapi) i32;

pub extern "user32" fn GetDpiForWindow(
    hWnd: HWND,
) callconv(.winapi) u32;

pub extern "user32" fn MessageBeep(
    uType: u32,
) callconv(.winapi) i32;

pub extern "user32" fn SetWindowTextW(
    hWnd: HWND,
    lpString: [*:0]const u16,
) callconv(.winapi) i32;

pub extern "user32" fn ValidateRect(
    hWnd: ?HWND,
    lpRect: ?*const RECT,
) callconv(.winapi) i32;

pub extern "user32" fn InvalidateRect(
    hWnd: ?HWND,
    lpRect: ?*const RECT,
    bErase: i32,
) callconv(.winapi) i32;

/// Non-zero when the window has a non-empty update region; fills `lpRect`
/// with its bounding box in client coordinates. Reading it is how a test
/// asserts what a resize actually invalidated, rather than what it looked
/// like it invalidated.
pub extern "user32" fn GetUpdateRect(
    hWnd: HWND,
    lpRect: ?*RECT,
    bErase: i32,
) callconv(.winapi) i32;

pub extern "user32" fn LoadCursorW(
    hInstance: ?HINSTANCE,
    lpCursorName: usize,
) callconv(.winapi) ?HCURSOR;

pub extern "user32" fn GetKeyState(
    nVirtKey: i32,
) callconv(.winapi) i16;

/// The PHYSICAL key state right now, rather than the state as of the message
/// this thread is currently dispatching. The distinction matters wherever the
/// dispatched message is not the user's input at all — a WebView2 event
/// callback, where `GetKeyState` answers for a browser-process message and
/// never reports the Ctrl the user is holding (T163).
pub extern "user32" fn GetAsyncKeyState(
    vKey: i32,
) callconv(.winapi) i16;

pub extern "kernel32" fn GetModuleHandleW(
    lpModuleName: ?[*:0]const u16,
) callconv(.winapi) ?HINSTANCE;

pub extern "kernel32" fn LoadLibraryW(
    lpLibFileName: [*:0]const u16,
) callconv(.winapi) ?HINSTANCE;

/// lpProcName is either a name or an ordinal packed as a pointer
/// (MAKEINTRESOURCEA semantics).
pub extern "kernel32" fn GetProcAddress(
    hModule: HINSTANCE,
    lpProcName: ?[*:0]const u8,
) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?*const fn (u32) callconv(.winapi) i32,
    Add: i32,
) callconv(.winapi) i32;

/// The pid behind a process HANDLE. Returns 0 on failure.
pub extern "kernel32" fn GetProcessId(
    Process: std.os.windows.HANDLE,
) callconv(.winapi) u32;

/// Our own pid. Cannot fail.
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

/// Monotonic milliseconds since boot; never wraps, never rewinds with the
/// wall clock. What the viewer nav bar's hide deadline is measured in.
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub extern "user32" fn ToUnicode(
    wVirtKey: u32,
    wScanCode: u32,
    lpKeyState: *const [256]u8,
    pwszBuff: [*]u16,
    cchBuff: i32,
    wFlags: u32,
) callconv(.winapi) i32;

pub extern "user32" fn GetKeyboardState(
    lpKeyState: *[256]u8,
) callconv(.winapi) i32;

pub extern "user32" fn SetCapture(
    hWnd: HWND,
) callconv(.winapi) ?HWND;

pub extern "user32" fn ReleaseCapture() callconv(.winapi) i32;

pub extern "user32" fn GetWindowLongW(
    hWnd: HWND,
    nIndex: i32,
) callconv(.winapi) u32;

pub extern "user32" fn SetWindowLongW(
    hWnd: HWND,
    nIndex: i32,
    dwNewLong: u32,
) callconv(.winapi) u32;

pub extern "user32" fn SetWindowPos(
    hWnd: HWND,
    hWndInsertAfter: ?HWND,
    X: i32,
    Y: i32,
    cx: i32,
    cy: i32,
    uFlags: u32,
) callconv(.winapi) i32;

pub extern "user32" fn GetWindowRect(
    hWnd: HWND,
    lpRect: *RECT,
) callconv(.winapi) i32;

pub extern "user32" fn MonitorFromWindow(
    hwnd: HWND,
    dwFlags: u32,
) callconv(.winapi) HMONITOR;

pub extern "user32" fn GetMonitorInfoW(
    hMonitor: HMONITOR,
    lpmi: *MONITORINFO,
) callconv(.winapi) i32;

pub extern "user32" fn IsZoomed(
    hWnd: HWND,
) callconv(.winapi) i32;

pub extern "user32" fn SetCursor(
    // NULL is documented as valid — it hides the cursor. Make the
    // parameter optional so callers can pass null without a cast.
    hCursor: ?HCURSOR,
) callconv(.winapi) ?HCURSOR;

/// ShowCursor increments (true) or decrements (false) an internal
/// display counter. The cursor is shown when the count is >= 0.
/// Returns the new display count.
pub extern "user32" fn ShowCursor(
    bShow: i32,
) callconv(.winapi) i32;

// WM_GETMINMAXINFO — drives the OS-side resize clamp.
pub const WM_GETMINMAXINFO: u32 = 0x0024;

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

// Drag and drop (shell32) — used so dropping files onto a terminal
// pastes their paths.
pub const HDROP = *opaque {};
pub const WM_DROPFILES: u32 = 0x0233;

pub extern "shell32" fn DragAcceptFiles(
    hWnd: HWND,
    fAccept: i32,
) callconv(.winapi) void;

pub extern "shell32" fn DragQueryFileW(
    hDrop: HDROP,
    iFile: u32,
    lpszFile: ?[*]u16,
    cch: u32,
) callconv(.winapi) u32;

pub extern "shell32" fn DragFinish(
    hDrop: HDROP,
) callconv(.winapi) void;

// FlashWindowEx — used to draw attention to an unfocused window.
pub const FLASHW_STOP: u32 = 0;
pub const FLASHW_CAPTION: u32 = 0x00000001;
pub const FLASHW_TRAY: u32 = 0x00000002;
pub const FLASHW_ALL: u32 = 0x00000003;
pub const FLASHW_TIMER: u32 = 0x00000004;
pub const FLASHW_TIMERNOFG: u32 = 0x0000000C;

pub const FLASHWINFO = extern struct {
    cbSize: u32,
    hwnd: HWND,
    dwFlags: u32,
    uCount: u32,
    dwTimeout: u32,
};

pub extern "user32" fn FlashWindowEx(
    pfwi: *FLASHWINFO,
) callconv(.winapi) i32;

// GetSystemMetrics — used for cascade-position bounds checks etc.
// 0=SM_CXSCREEN, 1=SM_CYSCREEN.
pub extern "user32" fn GetSystemMetrics(
    nIndex: i32,
) callconv(.winapi) i32;

/// The VIRTUAL SCREEN: the bounding box of every monitor, whose origin is the
/// primary monitor's top-left and can therefore be NEGATIVE (a monitor placed
/// left of or above it). The manifest declares PerMonitorV2, so these come back
/// in physical pixels with no per-monitor scaling applied — which is exactly
/// what a screen-pixel capture wants (T647).
pub const SM_XVIRTUALSCREEN: i32 = 76;
pub const SM_YVIRTUALSCREEN: i32 = 77;
pub const SM_CXVIRTUALSCREEN: i32 = 78;
pub const SM_CYVIRTUALSCREEN: i32 = 79;

pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: i32,
) callconv(.winapi) isize;

pub extern "user32" fn SetLayeredWindowAttributes(
    hwnd: HWND,
    crKey: u32,
    bAlpha: u8,
    dwFlags: u32,
) callconv(.winapi) i32;

// RedrawWindow — needed after clearing WS_EX_LAYERED: the style change is
// not repainted automatically (see "Layered Windows" in the Win32 docs).
pub const RDW_INVALIDATE: u32 = 0x0001;
pub const RDW_ERASE: u32 = 0x0004;
pub const RDW_ALLCHILDREN: u32 = 0x0080;
/// Send `WM_PAINT` right now rather than leaving it in the queue. A SENT
/// message, so it runs on the caller's stack — which is the whole ordering
/// guarantee `hover_capture.zig` depends on (T282).
pub const RDW_UPDATENOW: u32 = 0x0100;
pub const RDW_FRAME: u32 = 0x0400;
pub extern "user32" fn RedrawWindow(
    hWnd: ?HWND,
    lprcUpdate: ?*const RECT,
    hrgnUpdate: ?*anyopaque,
    flags: u32,
) callconv(.winapi) i32;

pub extern "user32" fn SetTimer(
    hWnd: ?HWND,
    nIDEvent: usize,
    uElapse: u32,
    lpTimerFunc: ?*const anyopaque,
) callconv(.winapi) usize;

pub extern "user32" fn KillTimer(
    hWnd: ?HWND,
    uIDEvent: usize,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Synchronization API
// -----------------------------------------------------------------------

pub const HANDLE = std.os.windows.HANDLE;
pub const INFINITE: u32 = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: u32 = 0x00000000;
pub const WAIT_TIMEOUT: u32 = 0x00000102;

pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: i32,
    bInitialState: i32,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn SetEvent(
    hEvent: HANDLE,
) callconv(.winapi) i32;

pub extern "kernel32" fn ResetEvent(
    hEvent: HANDLE,
) callconv(.winapi) i32;

pub extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: u32,
) callconv(.winapi) u32;

pub extern "kernel32" fn CloseHandle(
    hObject: HANDLE,
) callconv(.winapi) i32;

/// Cross-process coalescing (T695): the URL-scheme activation processes race
/// for this, and whoever creates it first owns the failure dialog. We never
/// wait on it — `ERROR_ALREADY_EXISTS` from `GetLastError` IS the answer.
pub extern "kernel32" fn CreateMutexW(
    lpMutexAttributes: ?*anyopaque,
    bInitialOwner: i32,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;

pub const WAIT_FAILED: u32 = 0xFFFFFFFF;

pub extern "kernel32" fn WaitForMultipleObjects(
    nCount: u32,
    lpHandles: [*]const HANDLE,
    bWaitAll: i32,
    dwMilliseconds: u32,
) callconv(.winapi) u32;

// -----------------------------------------------------------------------
// Directory change notifications (T391, the viewer's live reload)
// -----------------------------------------------------------------------

pub const OVERLAPPED = std.os.windows.OVERLAPPED;
pub const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;

pub const FILE_LIST_DIRECTORY: u32 = 0x0001;
pub const FILE_SHARE_READ: u32 = 0x0000_0001;
pub const FILE_SHARE_WRITE: u32 = 0x0000_0002;
pub const FILE_SHARE_DELETE: u32 = 0x0000_0004;
pub const OPEN_EXISTING: u32 = 3;
/// Required to open a DIRECTORY with `CreateFileW` at all.
pub const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
pub const FILE_FLAG_OVERLAPPED: u32 = 0x4000_0000;

pub const FILE_NOTIFY_CHANGE_FILE_NAME: u32 = 0x0000_0001;
pub const FILE_NOTIFY_CHANGE_ATTRIBUTES: u32 = 0x0000_0004;
pub const FILE_NOTIFY_CHANGE_SIZE: u32 = 0x0000_0008;
pub const FILE_NOTIFY_CHANGE_LAST_WRITE: u32 = 0x0000_0010;
pub const FILE_NOTIFY_CHANGE_CREATION: u32 = 0x0000_0040;

pub extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: HANDLE,
    lpBuffer: *anyopaque,
    nBufferLength: u32,
    bWatchSubtree: i32,
    dwNotifyFilter: u32,
    lpBytesReturned: ?*u32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*const anyopaque,
) callconv(.winapi) i32;

pub extern "kernel32" fn CancelIoEx(
    hFile: HANDLE,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) i32;

pub extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *u32,
    bWait: i32,
) callconv(.winapi) i32;

// Stock object indices for GetStockObject
pub const BLACK_BRUSH: i32 = 4;
/// A pen that draws nothing, so `Polygon` fills its interior WITHOUT also
/// outlining it. Chrome glyphs are filled shapes (T232) and an outline would
/// re-introduce exactly the wide-pen bias the fill exists to remove.
pub const NULL_PEN: i32 = 8;

pub extern "gdi32" fn GetStockObject(
    i: i32,
) callconv(.winapi) ?*anyopaque;

/// Fill a closed polygon with the current brush, outlined with the current
/// pen. Right and bottom boundaries are EXCLUSIVE, like `Rectangle`.
pub extern "gdi32" fn Polygon(
    hdc: HDC,
    apt: [*]const POINT,
    cpt: i32,
) callconv(.winapi) i32;

/// Stroke an OPEN polyline with the current pen. Unlike `MoveToEx`/`LineTo`,
/// every supplied point is drawn (§8 of the design system: `LineTo` drops its
/// endpoint), which is what the Activity Monitor's trend charts need.
pub extern "gdi32" fn Polyline(
    hdc: HDC,
    apt: [*]const POINT,
    cpt: i32,
) callconv(.winapi) i32;

/// COLORREF is 0x00BBGGRR (blue in high byte, red in low byte).
pub fn RGB(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

pub extern "gdi32" fn CreateSolidBrush(
    color: u32,
) callconv(.winapi) ?HBRUSH;

pub extern "gdi32" fn DeleteObject(
    ho: *anyopaque,
) callconv(.winapi) i32;

pub extern "user32" fn FillRect(
    hDC: HDC,
    lprc: *const RECT,
    hbr: HBRUSH,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Clipboard API
// -----------------------------------------------------------------------

// Clipboard format: Unicode text (UTF-16LE, null-terminated)
pub const CF_UNICODETEXT: u32 = 13;

// Clipboard image formats, in the order a reader should prefer them: V5 first
// because it is the only one carrying an alpha channel, then the plain DIB,
// then a bare HBITMAP (which GDI synthesises for anything else).
pub const CF_BITMAP: u32 = 2;
pub const CF_DIB: u32 = 8;
pub const CF_DIBV5: u32 = 17;

pub extern "user32" fn RegisterClipboardFormatW(
    lpszFormat: [*:0]const u16,
) callconv(.winapi) u32;

pub extern "user32" fn IsClipboardFormatAvailable(
    format: u32,
) callconv(.winapi) i32;

// GlobalAlloc flags
pub const GMEM_MOVEABLE: u32 = 0x0002;

pub extern "user32" fn OpenClipboard(
    hWndNewOwner: ?HWND,
) callconv(.winapi) i32;

pub extern "user32" fn CloseClipboard() callconv(.winapi) i32;

pub extern "user32" fn EmptyClipboard() callconv(.winapi) i32;

pub extern "user32" fn GetClipboardData(
    uFormat: u32,
) callconv(.winapi) ?*anyopaque;

pub extern "user32" fn SetClipboardData(
    uFormat: u32,
    hMem: *anyopaque,
) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GlobalAlloc(
    uFlags: u32,
    dwBytes: usize,
) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GlobalLock(
    hMem: *anyopaque,
) callconv(.winapi) ?[*]u8;

pub extern "kernel32" fn GlobalUnlock(
    hMem: *anyopaque,
) callconv(.winapi) i32;

pub extern "kernel32" fn GlobalFree(
    hMem: *anyopaque,
) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GlobalSize(
    hMem: *anyopaque,
) callconv(.winapi) usize;

pub extern "kernel32" fn Sleep(
    dwMilliseconds: u32,
) callconv(.winapi) void;

// -----------------------------------------------------------------------
// Edit control / child window API
// -----------------------------------------------------------------------

pub const WM_COMMAND: u32 = 0x0111;
pub const WM_CTLCOLOREDIT: u32 = 0x0133;
pub const WM_CTLCOLORSTATIC: u32 = 0x0138;
pub const WM_CTLCOLORBTN: u32 = 0x0135;
pub const WM_CTLCOLORLISTBOX: u32 = 0x0134;

// LISTBOX control styles, messages, and notifications (T22c machine chooser).
pub const LBS_NOTIFY: u32 = 0x0001;
pub const LBS_HASSTRINGS: u32 = 0x0040;
pub const LB_ADDSTRING: u32 = 0x0180;
pub const LB_RESETCONTENT: u32 = 0x0184;
pub const LB_SETCURSEL: u32 = 0x0186;
pub const LB_GETCURSEL: u32 = 0x0188;
pub const LB_GETCOUNT: u32 = 0x018B;
pub const LBN_SELCHANGE: u16 = 1;
pub const LBN_DBLCLK: u16 = 2;

// Owner-drawn LISTBOX rows (T172 machine chooser). The listbox reports item
// geometry to its parent (WM_MEASUREITEM) and asks it to paint each row
// (WM_DRAWITEM) instead of rendering a system-blue string bar.
pub const LBS_OWNERDRAWFIXED: u32 = 0x0010;
pub const LBS_NOINTEGRALHEIGHT: u32 = 0x0100;
pub const LB_GETITEMRECT: u32 = 0x0198;
pub const LB_GETITEMHEIGHT: u32 = 0x01A1;
pub const LB_ITEMFROMPOINT: u32 = 0x01A9;
pub const LB_SETITEMHEIGHT: u32 = 0x01A0;
pub const WM_MEASUREITEM: u32 = 0x002C;
pub const WM_DRAWITEM: u32 = 0x002B;
pub const ODT_LISTBOX: u32 = 2;
pub const ODT_BUTTON: u32 = 4;
pub const ODA_DRAWENTIRE: u32 = 0x0001;
pub const ODS_SELECTED: u32 = 0x0001;
pub const ODS_DISABLED: u32 = 0x0004;
pub const ODS_FOCUS: u32 = 0x0010;

pub const MEASUREITEMSTRUCT = extern struct {
    CtlType: u32,
    CtlID: u32,
    itemID: u32,
    itemWidth: u32,
    itemHeight: u32,
    itemData: usize,
};

pub const DRAWITEMSTRUCT = extern struct {
    CtlType: u32,
    CtlID: u32,
    itemID: u32,
    itemAction: u32,
    itemState: u32,
    hwndItem: ?HWND,
    hDC: HDC,
    rcItem: RECT,
    itemData: usize,
};

// EDIT cue banner ("placeholder" text shown while empty and unfocused).
pub const EM_SETCUEBANNER: u32 = 0x1501;
/// Select a range of an EDIT's text; `(0, -1)` selects all, so typing replaces
/// a seeded value.
pub const EM_GETSEL: u32 = 0x00B0;
pub const EM_SETSEL: u32 = 0x00B1;

// COMBOBOX control styles and messages (T174's Host Settings shell field —
// Mac's editable NSComboBox with the shell presets).
/// An editable combo box: a text field plus a drop-down list, so a preset can
/// be picked OR any other path typed. (`CBS_DROPDOWNLIST` would be read-only.)
pub const CBS_DROPDOWN: u32 = 0x0002;
pub const CBS_AUTOHSCROLL: u32 = 0x0040;
pub const CB_ADDSTRING: u32 = 0x0143;
pub const CB_SETITEMHEIGHT: u32 = 0x0153;
pub const CB_GETITEMHEIGHT: u32 = 0x0154;
/// Whether the drop-down list is currently open. Enter/Escape must close the
/// LIST when it is, not commit/cancel the dialog behind it.
pub const CB_GETDROPPEDSTATE: u32 = 0x0157;
/// The combo's own cue banner ("placeholder"), so the inner EDIT never has to
/// be found to set one.
pub const CB_SETCUEBANNER: u32 = 0x1703;

// Button control styles / notifications
pub const BS_DEFPUSHBUTTON: u32 = 0x00000001;
/// A checkbox whose check state the OWNER sets (BM_SETCHECK) — for toggles
/// whose flip can fail or complete asynchronously, so the box never shows a
/// state the underlying work has not reached (T547).
pub const BS_CHECKBOX: u32 = 0x00000002;
/// A checkbox that toggles its own check state on click (no BM_SETCHECK from
/// the WM_COMMAND handler needed).
pub const BS_AUTOCHECKBOX: u32 = 0x00000003;
pub const BN_CLICKED: u16 = 0;
pub const BM_GETCHECK: u32 = 0x00F0;
pub const BM_SETCHECK: u32 = 0x00F1;
pub const BST_UNCHECKED: usize = 0;
pub const BST_CHECKED: usize = 1;
/// A button the owner paints itself (`WM_DRAWITEM`). The chooser's "Sign Out"
/// is a LINK, which no system button style draws — but it still has to be a
/// BUTTON so it keeps a tab stop, a focus rect and BN_CLICKED (T311).
pub const BS_OWNERDRAW: u32 = 0x0000000B;
// STATIC control styles.
pub const SS_CENTER: u32 = 0x0001;
pub const SS_RIGHT: u32 = 0x0002;
pub const SS_CENTERIMAGE: u32 = 0x0200;
/// Middle-truncate with an ellipsis when the text does not fit — Mac
/// middle-truncates the account email (win32-machine-chooser.md §2.4), which
/// keeps the domain visible where `SS_ENDELLIPSIS` would eat it.
pub const SS_PATHELLIPSIS: u32 = 0x00008000;

// -------------------------------------------------------------------------
// RichEdit (T635 — the viewer feedback composer's text control, D43's answer)
//
// The control lives in Msftedit.dll, which is NOT loaded by default: the DLL
// registers its window classes from its entry point, so a `CreateWindowExW`
// before the `LoadLibraryW` fails with "class not registered". Everything
// below is the subset the composer uses; RichEdit's message numbers are all
// `WM_USER (0x0400) + n`, spelled out here so a reader can check them against
// richedit.h without arithmetic.
// -------------------------------------------------------------------------

/// Msftedit's own class, i.e. RichEdit 4.1 and later. `RICHEDIT_CLASS`
/// ("RichEdit20W") is riched20.dll's older one and is deliberately not used.
pub const MSFTEDIT_CLASS = std.unicode.utf8ToUtf16LeStringLiteral("RichEdit50W");
pub const MSFTEDIT_DLL = std.unicode.utf8ToUtf16LeStringLiteral("Msftedit.dll");

/// Background colour of the whole control. wparam 0 = use the given COLORREF,
/// 1 = fall back to the system window colour. RichEdit paints its own
/// background, so this is the ONLY way the pill's fill reaches it.
pub const EM_SETBKGNDCOLOR: u32 = 0x0443; // WM_USER + 67
pub const EM_SETCHARFORMAT: u32 = 0x0444; // WM_USER + 68
pub const EM_SETEVENTMASK: u32 = 0x0445; // WM_USER + 69
/// Read the formatting the composer would otherwise blindly re-set (T644):
/// skipping a set that would change nothing is what keeps RichEdit's
/// group-typing aggregation — and therefore word-at-a-time undo — intact.
pub const EM_GETCHARFORMAT: u32 = 0x043A; // WM_USER + 58
pub const EM_GETPARAFORMAT: u32 = 0x043D; // WM_USER + 61
/// The door to RichEdit's COM side (`IRichEditOle`, and through it the TOM's
/// `ITextDocument`) — how programmatic formatting is kept OFF the undo stack
/// (T644, `richedit_tom.zig`).
pub const EM_GETOLEINTERFACE: u32 = 0x043C; // WM_USER + 60
/// Cap on the undo stack. 0 disables undo entirely; the composer leaves the
/// default in place and only names the message so the intent is greppable.
pub const EM_SETUNDOLIMIT: u32 = 0x0452; // WM_USER + 82
pub const EM_EXSETSEL: u32 = 0x0437; // WM_USER + 55
pub const EM_EXGETSEL: u32 = 0x0434; // WM_USER + 52
/// Paragraph formatting — how the composer indents a quoted block (T641).
/// Applies to every paragraph the selection touches, so a quote is selected
/// and then set.
pub const EM_SETPARAFORMAT: u32 = 0x0447; // WM_USER + 71
/// Replace the selection with text, keeping it on the undo stack when wparam
/// is TRUE. The insertion point ends up after what was inserted.
pub const EM_REPLACESEL: u32 = 0x00C2;
/// Read the control's text WITHOUT the CR->CRLF translation `WM_GETTEXT`
/// does. That is load-bearing for T641: with bare CRs, a byte offset into the
/// pane's LF buffer is the same number as a character index in the control,
/// so a quote's span can be computed in pure code and handed straight to
/// `EM_EXSETSEL`. With CRLF the two drift by one per line break.
pub const EM_GETTEXTEX: u32 = 0x045E; // WM_USER + 94
/// Where a character sits in client coordinates. RichEdit's is NOT the EDIT
/// message of the same name: wparam is a `POINTL*` that receives the position
/// and lparam is the index, where the EDIT version packs the point into the
/// return value.
pub const EM_POSFROMCHAR: u32 = 0x04D6; // WM_USER + 214
pub const EM_GETLINECOUNT: u32 = 0x00BA;
pub const EM_SCROLLCARET: u32 = 0x00B7;

/// Which notifications the control is allowed to send its parent. RichEdit
/// sends NONE by default — an EN_CHANGE that never arrives is the classic
/// "my RichEdit does not notify" bug.
pub const ENM_CHANGE: usize = 0x00000001;

/// `EM_SETCHARFORMAT` targets.
pub const SCF_DEFAULT: usize = 0x0000;
pub const SCF_SELECTION: usize = 0x0001;
pub const SCF_ALL: usize = 0x0004;

/// `CHARFORMAT2W.dwMask` bits the composer sets.
pub const CFM_COLOR: u32 = 0x40000000;
/// The tint behind a quoted block (T641). RichEdit paints a background colour
/// as tight line boxes, which is why the accent bar down the left is drawn by
/// hand rather than asked for here.
pub const CFM_BACKCOLOR: u32 = 0x04000000;

/// `CHARFORMAT2W.dwEffects` bits. Each shares its value with its `CFM_` twin;
/// an effect bit SET on a read means the colour is "auto" and the matching
/// `crTextColor`/`crBackColor` is not what is on screen — which is why the
/// composer's is-it-already-plain check (T644) must see them clear before it
/// trusts the colour fields.
pub const CFE_AUTOCOLOR: u32 = 0x40000000;
pub const CFE_AUTOBACKCOLOR: u32 = 0x04000000;

/// `PARAFORMAT2.dwMask` bits the composer sets: the left indent that makes a
/// quoted block read as a block.
pub const PFM_STARTINDENT: u32 = 0x00000001;

/// Paragraph formatting, v2 (`PARAFORMAT2`) — distinguished from v1 by
/// `cbSize`, exactly like `CHARFORMAT2W`. Indents are in TWIPs (1/1440"), so
/// 15 twips is one DIP and the control does the DPI conversion itself.
pub const PARAFORMAT2 = extern struct {
    cbSize: u32,
    dwMask: u32,
    wNumbering: u16,
    wEffects: u16,
    dxStartIndent: i32,
    dxRightIndent: i32,
    dxOffset: i32,
    wAlignment: u16,
    cTabCount: i16,
    rgxTabs: [32]i32,
    dySpaceBefore: i32,
    dySpaceAfter: i32,
    dyLineSpacing: i32,
    sStyle: i16,
    bLineSpacingRule: u8,
    bOutlineLevel: u8,
    wShadingWeight: u16,
    wShadingStyle: u16,
    wNumberingStart: u16,
    wNumberingStyle: u16,
    wNumberingTab: u16,
    wBorderSpace: u16,
    wBorderWidth: u16,
    wBorders: u16,
};

/// `EM_GETTEXTEX`'s in-parameter. `cb` is a BYTE count for a wide buffer, and
/// `flags` of 0 (`GT_DEFAULT`) is what leaves line breaks as bare CR.
pub const GETTEXTEX = extern struct {
    cb: u32,
    flags: u32,
    codepage: u32,
    lpDefaultChar: ?*const anyopaque,
    lpUsedDefChar: ?*anyopaque,
};

/// `GETTEXTEX.codepage` for UTF-16.
pub const CP_UNICODE: u32 = 1200;

/// The character-formatting struct, in its `CHARFORMAT2W` (v2, wide) form —
/// which is what `EM_SETCHARFORMAT` expects from Msftedit. `cbSize` is how the
/// control tells v1 from v2, so it must be the size of THIS struct.
pub const CHARFORMAT2W = extern struct {
    cbSize: u32,
    dwMask: u32,
    dwEffects: u32,
    yHeight: i32,
    yOffset: i32,
    crTextColor: u32,
    bCharSet: u8,
    bPitchAndFamily: u8,
    szFaceName: [32]u16,
    wWeight: u16,
    sSpacing: i16,
    crBackColor: u32,
    lcid: u32,
    dwReserved: u32,
    sStyle: i16,
    wKerning: u16,
    bUnderlineType: u8,
    bAnimation: u8,
    bRevAuthor: u8,
    bReserved1: u8,
};

/// A character range for `EM_EXSETSEL`. `cpMax` of -1 means "to the end", so
/// `(0, -1)` selects everything.
pub const CHARRANGE = extern struct {
    cpMin: i32,
    cpMax: i32,
};

/// `EM_POSFROMCHAR`'s out-parameter.
pub const POINTL = extern struct {
    x: i32,
    y: i32,
};

// Edit control notification codes (high word of wParam in WM_COMMAND)
pub const EN_CHANGE: u16 = 0x0300;
pub const EN_SETFOCUS: u16 = 0x0100;
pub const EN_KILLFOCUS: u16 = 0x0200;

// Edit control styles
pub const ES_AUTOHSCROLL: u32 = 0x0080;
// Multi-line edit styles for the pane-banner editor (T35).
pub const ES_MULTILINE: u32 = 0x0004;
pub const ES_AUTOVSCROLL: u32 = 0x0040;
pub const ES_WANTRETURN: u32 = 0x1000;

// Window styles for child windows
pub const WS_CHILD: u32 = 0x40000000;
pub const WS_VISIBLE_STYLE: u32 = 0x10000000;
pub const WS_BORDER: u32 = 0x00800000;
/// Excludes the areas occupied by child windows when painting the parent.
/// A viewer pane needs it: WebView2 parents its own Chromium windows inside
/// the pane's host window, and painting the pane background over them is a
/// visible flash on every resize.
pub const WS_CLIPCHILDREN: u32 = 0x02000000;

pub extern "user32" fn SetFocus(
    hWnd: ?HWND,
) callconv(.winapi) ?HWND;

pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;

pub extern "user32" fn GetActiveWindow() callconv(.winapi) ?HWND;

/// Enables or disables mouse and keyboard input to the window. Used for
/// modal-ish dialogs: disable the owner while the dialog is open.
pub extern "user32" fn EnableWindow(
    hWnd: HWND,
    bEnable: i32,
) callconv(.winapi) i32;

pub extern "user32" fn GetWindowTextW(
    hWnd: HWND,
    lpString: [*]u16,
    nMaxCount: i32,
) callconv(.winapi) i32;

pub extern "user32" fn GetWindowTextLengthW(
    hWnd: HWND,
) callconv(.winapi) i32;

pub extern "user32" fn MoveWindow(
    hWnd: HWND,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    bRepaint: i32,
) callconv(.winapi) i32;

// Imported under an underscore-suffixed Zig name to avoid colliding
// with `std.os.windows.user32.IsWindowVisible`. The `@extern` builtin
// pins the actual import name to "IsWindowVisible".
pub const IsWindowVisible_: *const fn (HWND) callconv(.winapi) i32 = @extern(
    *const fn (HWND) callconv(.winapi) i32,
    .{ .name = "IsWindowVisible", .library_name = "user32" },
);

pub extern "gdi32" fn SetBkColor(
    hdc: HDC,
    color: u32,
) callconv(.winapi) u32;

pub extern "gdi32" fn SetTextColor(
    hdc: HDC,
    color: u32,
) callconv(.winapi) u32;

pub extern "gdi32" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: u32,
    bUnderline: u32,
    bStrikeOut: u32,
    iCharSet: u32,
    iOutPrecision: u32,
    iClipPrecision: u32,
    iQuality: u32,
    iPitchAndFamily: u32,
    pszFaceName: ?[*:0]const u16,
) callconv(.winapi) ?*anyopaque;

/// Grayscale antialiasing (`LOGFONT.lfQuality`). Chrome glyphs from the
/// system icon font are drawn with this rather than ClearType: subpixel
/// fringing on a colored fill (the close button's red) reads as a dirty
/// glyph, and Windows' own caption glyphs are grayscale too.
pub const ANTIALIASED_QUALITY: u32 = 4;

/// `LOGFONT.lfFaceName` capacity, including the terminator.
pub const LF_FACESIZE: usize = 32;

pub extern "gdi32" fn GetTextFaceW(
    hdc: HDC,
    c: i32,
    lpName: ?[*]u16,
) callconv(.winapi) i32;

pub const WM_SETFONT: u32 = 0x0030;

pub extern "user32" fn SendMessageW(
    hWnd: HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
) callconv(.winapi) isize;

// -----------------------------------------------------------------------
// MessageBox API
// -----------------------------------------------------------------------

pub const MB_OK: u32 = 0x00000000;
pub const MB_OKCANCEL: u32 = 0x00000001;
pub const MB_YESNO: u32 = 0x00000004;
pub const MB_ICONWARNING: u32 = 0x00000030;
pub const MB_ICONINFORMATION: u32 = 0x00000040;
pub const MB_DEFBUTTON2: u32 = 0x00000100;
pub const IDOK: i32 = 1;
pub const IDCANCEL: i32 = 2;
pub const IDYES: i32 = 6;
pub const IDNO: i32 = 7;

pub extern "user32" fn MessageBoxW(
    hWnd: ?HWND,
    lpText: [*:0]const u16,
    lpCaption: [*:0]const u16,
    uType: u32,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Scrollbar API
// -----------------------------------------------------------------------

pub const SB_VERT: i32 = 1;
pub const SIF_ALL: u32 = 0x0017;
pub const SIF_POS: u32 = 0x0004;
pub const SIF_RANGE: u32 = 0x0001;
pub const SIF_PAGE: u32 = 0x0002;
pub const SIF_TRACKPOS: u32 = 0x0010;
pub const SIF_DISABLENOSCROLL: u32 = 0x0008;

pub const WM_VSCROLL: u32 = 0x0115;

// Scrollbar request codes (from wParam low word)
pub const SB_LINEUP: u16 = 0;
pub const SB_LINEDOWN: u16 = 1;
pub const SB_PAGEUP: u16 = 2;
pub const SB_PAGEDOWN: u16 = 3;
pub const SB_THUMBTRACK: u16 = 5;
pub const SB_THUMBPOSITION: u16 = 4;
pub const SB_TOP: u16 = 6;
pub const SB_BOTTOM: u16 = 7;

pub const SCROLLINFO = extern struct {
    cbSize: u32,
    fMask: u32,
    nMin: i32,
    nMax: i32,
    nPage: u32,
    nPos: i32,
    nTrackPos: i32,
};

pub extern "user32" fn SetScrollInfo(
    hwnd: HWND,
    nBar: i32,
    lpsi: *const SCROLLINFO,
    redraw: i32,
) callconv(.winapi) i32;

pub extern "user32" fn GetScrollInfo(
    hwnd: HWND,
    nBar: i32,
    lpsi: *SCROLLINFO,
) callconv(.winapi) i32;

// Window style for vertical scrollbar
pub const WS_VSCROLL: u32 = 0x00200000;

pub extern "user32" fn ShowScrollBar(
    hWnd: HWND,
    wBar: i32,
    bShow: i32,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Shell notification (tray icon + balloon) API
// -----------------------------------------------------------------------

pub const NIM_ADD: u32 = 0x00000000;
pub const NIM_MODIFY: u32 = 0x00000001;
pub const NIM_DELETE: u32 = 0x00000002;
pub const NIM_SETVERSION: u32 = 0x00000004;

/// `uVersion` values for NIM_SETVERSION. Without a NIM_SETVERSION call an
/// icon keeps the shell's DEFAULT pre-5.0 ("Windows 95") behavior, under
/// which the NIN_* balloon notifications below are never sent at all — see
/// `tray_notify.zig` for why that matters and why we pick 3 over 4.
pub const NOTIFYICON_VERSION: u32 = 3;
pub const NOTIFYICON_VERSION_4: u32 = 4;

pub const NIF_MESSAGE: u32 = 0x00000001;
pub const NIF_ICON: u32 = 0x00000002;
pub const NIF_TIP: u32 = 0x00000004;
pub const NIF_INFO: u32 = 0x00000010;

// Tray-icon callback message values (delivered as lparam in the
// uCallbackMessage handler).
pub const NIN_BALLOONSHOW: u32 = 0x0402;
pub const NIN_BALLOONHIDE: u32 = 0x0403;
pub const NIN_BALLOONTIMEOUT: u32 = 0x0404;
pub const NIN_BALLOONUSERCLICK: u32 = 0x0405;

pub const NIIF_INFO: u32 = 0x00000001;

pub const NOTIFYICONDATAW = extern struct {
    cbSize: u32,
    hWnd: ?HWND,
    uID: u32,
    uFlags: u32,
    uCallbackMessage: u32,
    hIcon: ?HICON,
    szTip: [128]u16,
    dwState: u32,
    dwStateMask: u32,
    szInfo: [256]u16,
    uVersion_or_uTimeout: u32,
    szInfoTitle: [64]u16,
    dwInfoFlags: u32,
};

pub extern "shell32" fn Shell_NotifyIconW(
    dwMessage: u32,
    lpData: *NOTIFYICONDATAW,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// IMM32 (Input Method Manager) API
// -----------------------------------------------------------------------

pub const HIMC = *opaque {};

pub const COMPOSITIONFORM = extern struct {
    dwStyle: u32,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub extern "imm32" fn ImmGetContext(
    hWnd: HWND,
) callconv(.winapi) ?HIMC;

pub extern "imm32" fn ImmNotifyIME(
    hIMC: HIMC,
    dwAction: u32,
    dwIndex: u32,
    dwValue: u32,
) callconv(.winapi) i32;
pub const NI_COMPOSITIONSTR: u32 = 0x0015;
pub const CPS_CANCEL: u32 = 0x0004;

pub extern "imm32" fn ImmReleaseContext(
    hWnd: HWND,
    hIMC: HIMC,
) callconv(.winapi) i32;

pub extern "imm32" fn ImmGetCompositionStringW(
    hIMC: HIMC,
    dwIndex: u32,
    lpBuf: ?[*]u16,
    dwBufLen: u32,
) callconv(.winapi) i32;

pub extern "imm32" fn ImmSetCompositionWindow(
    hIMC: HIMC,
    lpCompForm: *const COMPOSITIONFORM,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// DWM (Desktop Window Manager) API
// -----------------------------------------------------------------------

/// DWMWA_USE_IMMERSIVE_DARK_MODE — tells DWM to use dark-mode window chrome.
/// Supported on Windows 10 build 18985+ (formally documented from Windows 11).
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;
/// Title-bar fill color (Windows 11 22H2+). COLORREF 0x00BBGGRR.
pub const DWMWA_CAPTION_COLOR: u32 = 35;
// Sentinel for DWMWA_CAPTION_COLOR/TEXT_COLOR meaning "use the system default".
pub const DWMWA_COLOR_DEFAULT: u32 = 0xFFFFFFFF;
/// Title-bar text color (Windows 11 22H2+). COLORREF 0x00BBGGRR.
pub const DWMWA_TEXT_COLOR: u32 = 36;
/// Border color (Windows 11+). COLORREF 0x00BBGGRR.
pub const DWMWA_BORDER_COLOR: u32 = 34;

pub const MARGINS = extern struct {
    left: i32,
    right: i32,
    top: i32,
    bottom: i32,
};

pub extern "uxtheme" fn SetWindowTheme(
    hwnd: HWND,
    pszSubAppName: ?[*:0]const u16,
    pszSubIdList: ?[*:0]const u16,
) callconv(.winapi) i32;

pub extern "dwmapi" fn DwmExtendFrameIntoClientArea(
    hWnd: HWND,
    pMarInset: *const MARGINS,
) callconv(.winapi) i32;

pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: HWND,
    dwAttribute: u32,
    pvAttribute: *const anyopaque,
    cbAttribute: u32,
) callconv(.winapi) i32;

pub extern "dwmapi" fn DwmGetWindowAttribute(
    hwnd: HWND,
    dwAttribute: u32,
    pvAttribute: *anyopaque,
    cbAttribute: u32,
) callconv(.winapi) i32;

/// `DWMWA_CLOAKED` — the window is composed but not drawn. Non-zero for a
/// window on another virtual desktop, or one the shell has cloaked. There is no
/// window message for entering or leaving this state, so it can only be polled
/// (T290).
pub const DWMWA_CLOAKED: u32 = 14;

// -----------------------------------------------------------------------
// GDI double-buffered painting API
// -----------------------------------------------------------------------

pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, cx: i32, cy: i32) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) i32;
pub extern "gdi32" fn BitBlt(hdcDest: HDC, x: i32, y: i32, cx: i32, cy: i32, hdcSrc: HDC, x1: i32, y1: i32, rop: u32) callconv(.winapi) i32;
// DrawTextW is exported by user32.dll, not gdi32.dll. The previous
// declaration on gdi32 worked only because user32 was linked anyway.
pub extern "user32" fn DrawTextW(hdc: HDC, lpchText: [*]const u16, cchText: i32, lprc: *RECT, format: u32) callconv(.winapi) i32;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
// Pane-banner run painting (T35): sequential styled text segments.
pub extern "gdi32" fn TextOutW(hdc: HDC, x: i32, y: i32, lpString: [*]const u16, c: i32) callconv(.winapi) i32;
pub extern "gdi32" fn GetTextExtentPoint32W(hdc: HDC, lpString: [*]const u16, c: i32, psizl: *SIZE) callconv(.winapi) i32;
/// Longest prefix that fits a pixel budget: `lpnFit` receives the number of
/// UTF-16 units of `lpszString` that fit within `nMaxExtent`. One call
/// instead of a measure-per-prefix loop when breaking a long unbroken token
/// mid-string in a banner table cell (T123).
pub extern "gdi32" fn GetTextExtentExPointW(
    hdc: HDC,
    lpszString: [*]const u16,
    cchString: i32,
    nMaxExtent: i32,
    lpnFit: ?*i32,
    lpnDx: ?[*]i32,
    lpSize: *SIZE,
) callconv(.winapi) i32;
pub extern "gdi32" fn CreatePen(iStyle: i32, cWidth: i32, color: u32) callconv(.winapi) ?*anyopaque;
pub const PS_SOLID: i32 = 0;
pub extern "gdi32" fn MoveToEx(hdc: HDC, x: i32, y: i32, lppt: ?*anyopaque) callconv(.winapi) i32;
pub extern "gdi32" fn LineTo(hdc: HDC, x: i32, y: i32) callconv(.winapi) i32;

// Hero-mode carousel painting (T59a): stretch/alpha blits, rounded-rect
// clipping and borders.
pub extern "gdi32" fn StretchBlt(hdcDest: HDC, xDest: i32, yDest: i32, wDest: i32, hDest: i32, hdcSrc: HDC, xSrc: i32, ySrc: i32, wSrc: i32, hSrc: i32, rop: u32) callconv(.winapi) i32;
pub extern "gdi32" fn SetStretchBltMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
pub extern "gdi32" fn SetBrushOrgEx(hdc: HDC, x: i32, y: i32, lppt: ?*anyopaque) callconv(.winapi) i32;
pub const HALFTONE: i32 = 4;
// BLENDFUNCTION is defined below (UpdateLayeredWindow section).
pub extern "msimg32" fn AlphaBlend(hdcDest: HDC, xoriginDest: i32, yoriginDest: i32, wDest: i32, hDest: i32, hdcSrc: HDC, xoriginSrc: i32, yoriginSrc: i32, wSrc: i32, hSrc: i32, ftn: BLENDFUNCTION) callconv(.winapi) i32;
pub extern "gdi32" fn CreateRoundRectRgn(x1: i32, y1: i32, x2: i32, y2: i32, w: i32, h: i32) callconv(.winapi) ?*anyopaque;
/// Clip a WINDOW to a region (the viewer TOC card's rounded corners in its
/// floating overlay mode, T160). The system takes ownership of the region on
/// success — the caller must NOT delete it afterwards.
pub extern "user32" fn SetWindowRgn(hwnd: HWND, hrgn: ?*anyopaque, redraw: i32) callconv(.winapi) i32;
/// Fill a region directly. Preferred over SelectClipRgn+FillRect when
/// painting inside code that already holds a clip (the tab loop holds the
/// chiclet clip): this leaves the current clip untouched, where clearing it
/// with `SelectClipRgn(dc, null)` would silently un-clip everything drawn
/// after.
pub extern "gdi32" fn FillRgn(hdc: HDC, hrgn: *anyopaque, hbr: *anyopaque) callconv(.winapi) i32;
pub extern "gdi32" fn SelectClipRgn(hdc: HDC, hrgn: ?*anyopaque) callconv(.winapi) i32;
/// Intersect the DC's clip with a rect. Preferred over `SelectClipRgn(dc, null)`
/// to restore, which un-clips everything rather than what the caller added —
/// `SaveDC`/`RestoreDC` around this pair is what puts the previous clip back.
pub extern "gdi32" fn IntersectClipRect(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32) callconv(.winapi) i32;
pub extern "gdi32" fn SaveDC(hdc: HDC) callconv(.winapi) i32;
pub extern "gdi32" fn RestoreDC(hdc: HDC, state: i32) callconv(.winapi) i32;
pub extern "gdi32" fn RoundRect(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32, width: i32, height: i32) callconv(.winapi) i32;
pub const NULL_BRUSH: i32 = 5;

/// The system's own focus indicator: an XOR'd dotted outline, so it reads on
/// whatever it lands on. Used by the chooser's owner-drawn account link, which
/// has no border of its own to thicken (T311) — the design system requires focus
/// to be visible and never carried by color alone.
pub extern "user32" fn DrawFocusRect(hdc: HDC, lprc: *const RECT) callconv(.winapi) i32;

// Machine-chooser owner-drawn rows (T172): status dot + machine glyph.
pub extern "gdi32" fn Ellipse(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32) callconv(.winapi) i32;
pub extern "gdi32" fn Rectangle(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32) callconv(.winapi) i32;

// Hero-mode animations (T59b): honor the OS "animate controls and elements
// inside windows" accessibility setting.
pub extern "user32" fn SystemParametersInfoW(uiAction: u32, uiParam: u32, pvParam: ?*anyopaque, fWinIni: u32) callconv(.winapi) i32;
pub const SPI_GETCLIENTAREAANIMATION: u32 = 0x1042;

// Window-placement memory (T85): primary-monitor work area + the restored
// (normal) rect of a maximized window.
pub const SPI_GETWORKAREA: u32 = 0x0030;

pub const WINDOWPLACEMENT = extern struct {
    length: u32,
    flags: u32,
    showCmd: u32,
    ptMinPosition: POINT,
    ptMaxPosition: POINT,
    rcNormalPosition: RECT,
};

pub extern "user32" fn GetWindowPlacement(
    hWnd: HWND,
    lpwndpl: *WINDOWPLACEMENT,
) callconv(.winapi) i32;

/// The only call that sets a window's normal rect and its show state TOGETHER
/// (T748). `SetWindowPos` moves a maximized window without clearing
/// `WS_MAXIMIZE`, which leaves a window Windows still calls maximized sitting at
/// a normal window's size — see `applyRestoreFrame`.
pub extern "user32" fn SetWindowPlacement(
    hWnd: HWND,
    lpwndpl: *const WINDOWPLACEMENT,
) callconv(.winapi) i32;

/// `WINDOWPLACEMENT.showCmd` spellings. `SW_SHOWMAXIMIZED` is the same value as
/// `SW_MAXIMIZE`; both are here because the placement struct documents itself in
/// the `SW_SHOW*` vocabulary.
pub const SW_SHOWNORMAL: u32 = 1;
pub const SW_SHOWMAXIMIZED: u32 = 3;

pub extern "user32" fn BeginPaint(hwnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(hwnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) i32;

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: i32,
    rcPaint: RECT,
    fRestore: i32,
    fIncUpdate: i32,
    rgbReserved: [32]u8,
};

pub const SRCCOPY: u32 = 0x00CC0020;
/// OR'd into a `BitBlt` rop to include LAYERED windows in the result. Without
/// it a screen grab silently omits every layered popup — which here is the
/// scrollbars, the dim overlays and the banner cards, i.e. most of Ghoztty's
/// own chrome (T647).
pub const CAPTUREBLT: u32 = 0x40000000;
pub const TRANSPARENT: i32 = 1;
pub const DT_LEFT: u32 = 0;
pub const DT_CENTER: u32 = 1;
pub const DT_RIGHT: u32 = 2;
pub const DT_VCENTER: u32 = 4;
pub const DT_WORDBREAK: u32 = 0x10;
pub const DT_SINGLELINE: u32 = 32;
pub const DT_CALCRECT: u32 = 0x400;
pub const DT_END_ELLIPSIS: u32 = 0x8000;
/// Ellipsize a PATH in the middle, keeping the leaf filename visible — the
/// Path column's `.truncationMode(.head)` on the Mac.
pub const DT_PATH_ELLIPSIS: u32 = 0x4000;
pub const DT_NOPREFIX: u32 = 0x800;
/// Draw past the rect instead of clipping to it. The chooser's CPU meter uses
/// it so a four-digit reading (ten fully busy cores in one session) runs into
/// the slack beside its fixed slot rather than being cut mid-glyph — the slot is
/// sized for the readings that happen, not for the theoretical maximum (T462).
pub const DT_NOCLIP: u32 = 0x100;

// STATIC control styles.
pub const SS_NOPREFIX: u32 = 0x80;

pub extern "gdi32" fn ChoosePixelFormat(
    hdc: HDC,
    ppfd: *const PIXELFORMATDESCRIPTOR,
) callconv(.winapi) i32;

pub extern "gdi32" fn SetPixelFormat(
    hdc: HDC,
    format: i32,
    ppfd: *const PIXELFORMATDESCRIPTOR,
) callconv(.winapi) i32;

pub extern "gdi32" fn SwapBuffers(
    hdc: HDC,
) callconv(.winapi) i32;

pub extern "opengl32" fn wglCreateContext(
    hdc: HDC,
) callconv(.winapi) ?HGLRC;

pub extern "opengl32" fn wglMakeCurrent(
    hdc: ?HDC,
    hglrc: ?HGLRC,
) callconv(.winapi) i32;

pub extern "opengl32" fn wglDeleteContext(
    hglrc: HGLRC,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// TrackMouseEvent API (for WM_MOUSELEAVE tracking)
// -----------------------------------------------------------------------

pub const WM_MOUSELEAVE: u32 = 0x02A3;

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32,
    dwFlags: u32,
    hwndTrack: HWND,
    dwHoverTime: u32,
};

pub const TME_LEAVE: u32 = 0x00000002;

pub extern "user32" fn TrackMouseEvent(
    lpEventTrack: *TRACKMOUSEEVENT,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Tooltip control (comctl32) — the tab-strip cwd tooltip (T447). Track
// mode (TTF_TRACK): the app decides when and where the tip shows, which
// matches the strip's existing hover tracking; the control itself stays
// native-drawn so it inherits the system's own tooltip styling.
// -----------------------------------------------------------------------

pub const TOOLTIPS_CLASS = std.unicode.utf8ToUtf16LeStringLiteral("tooltips_class32");

pub const TTS_ALWAYSTIP: u32 = 0x01;
pub const TTS_NOPREFIX: u32 = 0x02;

/// The tool's owner window is SUBCLASSED so comctl32 relays its own mouse
/// messages — the viewer nav bar's feedback tooltip (T633), which wants the
/// system's delay and placement rather than a hand-driven one.
pub const TTF_SUBCLASS: u32 = 0x0001;
pub const TTF_TRACK: u32 = 0x0020;
pub const TTF_ABSOLUTE: u32 = 0x0080;

pub const TTM_TRACKACTIVATE: u32 = WM_USER + 17;
pub const TTM_TRACKPOSITION: u32 = WM_USER + 18;
/// Without a max width a tooltip renders on ONE line and `\n` in its text is
/// ignored — setting it is what turns newlines into line breaks (the T556
/// two-line title+cwd tip).
pub const TTM_SETMAXTIPWIDTH: u32 = WM_USER + 24;
pub const TTM_ADDTOOLW: u32 = WM_USER + 50;
pub const TTM_DELTOOLW: u32 = WM_USER + 51;
pub const TTM_NEWTOOLRECTW: u32 = WM_USER + 52;
pub const TTM_UPDATETIPTEXTW: u32 = WM_USER + 57;

pub const TOOLINFOW = extern struct {
    cbSize: u32,
    uFlags: u32,
    hwnd: ?HWND,
    uId: usize,
    rect: RECT,
    hinst: ?HINSTANCE,
    lpszText: ?[*:0]u16,
    lParam: isize,
    lpReserved: ?*anyopaque,
};

pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: u32,
    dwICC: u32,
};

/// Tab AND tooltip control classes (they share one ICC bit).
pub const ICC_TAB_CLASSES: u32 = 0x00000008;

pub extern "comctl32" fn InitCommonControlsEx(
    picce: *const INITCOMMONCONTROLSEX,
) callconv(.winapi) BOOL;

/// The user's double-click interval — also the system's conventional
/// tooltip initial-show delay.
pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;

// -----------------------------------------------------------------------
// Popup menu API
// -----------------------------------------------------------------------

pub const MF_STRING: u32 = 0x00000000;
pub const MF_SEPARATOR: u32 = 0x00000800;
pub const MF_GRAYED: u32 = 0x00000001;
pub const MF_CHECKED: u32 = 0x00000008;
pub const MF_POPUP: u32 = 0x00000010;

pub const MIIM_BITMAP: u32 = 0x00000080;

pub const MENUITEMINFOW = extern struct {
    cbSize: u32 = @sizeOf(MENUITEMINFOW),
    fMask: u32 = 0,
    fType: u32 = 0,
    fState: u32 = 0,
    wID: u32 = 0,
    hSubMenu: ?HMENU = null,
    hbmpChecked: ?HANDLE = null,
    hbmpUnchecked: ?HANDLE = null,
    dwItemData: usize = 0,
    dwTypeData: ?[*:0]u16 = null,
    cch: u32 = 0,
    hbmpItem: ?HANDLE = null,
};

pub extern "user32" fn SetMenuItemInfoW(
    hmenu: HMENU,
    item: u32,
    fByPosition: i32,
    lpmii: *const MENUITEMINFOW,
) callconv(.winapi) i32;

pub const TPM_LEFTALIGN: u32 = 0x0000;
pub const TPM_TOPALIGN: u32 = 0x0000;
pub const TPM_RETURNCMD: u32 = 0x0100;

pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;

pub extern "user32" fn AppendMenuW(
    hMenu: HMENU,
    uFlags: u32,
    uIDNewItem: usize,
    lpNewItem: ?[*:0]const u16,
) callconv(.winapi) i32;

pub extern "user32" fn TrackPopupMenuEx(
    hMenu: HMENU,
    uFlags: u32,
    x: i32,
    y: i32,
    hwnd: HWND,
    lptpm: ?*const anyopaque,
) callconv(.winapi) i32;

pub extern "user32" fn DestroyMenu(
    hMenu: HMENU,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Global hotkey API
// -----------------------------------------------------------------------

pub const WM_HOTKEY: u32 = 0x0312;

pub const MOD_ALT: u32 = 0x0001;
pub const MOD_CONTROL: u32 = 0x0002;
pub const MOD_SHIFT: u32 = 0x0004;
pub const MOD_WIN: u32 = 0x0008;
pub const MOD_NOREPEAT: u32 = 0x4000;

pub extern "user32" fn RegisterHotKey(
    hWnd: ?HWND,
    id: i32,
    fsModifiers: u32,
    vk: u32,
) callconv(.winapi) i32;

pub extern "user32" fn UnregisterHotKey(
    hWnd: ?HWND,
    id: i32,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Monitor API (additional)
// -----------------------------------------------------------------------

pub const MONITOR_DEFAULTTOPRIMARY: u32 = 0x00000001;

pub extern "user32" fn MonitorFromPoint(
    pt: POINT,
    dwFlags: u32,
) callconv(.winapi) ?HMONITOR;

pub extern "user32" fn MonitorFromRect(
    lprc: *const RECT,
    dwFlags: u32,
) callconv(.winapi) ?HMONITOR;

// -----------------------------------------------------------------------
// Performance counter API
// -----------------------------------------------------------------------

pub extern "kernel32" fn QueryPerformanceCounter(
    lpPerformanceCount: *i64,
) callconv(.winapi) i32;

pub extern "kernel32" fn QueryPerformanceFrequency(
    lpFrequency: *i64,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Thread input and foreground focus API
// -----------------------------------------------------------------------

pub const WM_ACTIVATE: u32 = 0x0006;
pub const WA_INACTIVE: u16 = 0;

pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;

pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;

// Desktop objects. Only used to answer "am I on the INPUT desktop?" — a
// process on a background desktop (CreateDesktopW, as the T211 acceptance
// harness does) has no foreground window at all, so foreground-based guards
// have to know not to apply there.
pub const HDESK = HANDLE;
pub const UOI_NAME: i32 = 2;
pub const DESKTOP_READOBJECTS: u32 = 0x0001;

const window_active = @import("window_active.zig");

pub extern "user32" fn GetThreadDesktop(dwThreadId: u32) callconv(.winapi) ?HDESK;

pub extern "user32" fn OpenInputDesktop(
    dwFlags: u32,
    fInherit: i32,
    dwDesiredAccess: u32,
) callconv(.winapi) ?HDESK;

pub extern "user32" fn CloseDesktop(hDesktop: HDESK) callconv(.winapi) i32;

pub extern "user32" fn GetUserObjectInformationW(
    hObj: HDESK,
    nIndex: i32,
    pvInfo: ?*anyopaque,
    nLength: u32,
    lpnLengthNeeded: ?*u32,
) callconv(.winapi) i32;

/// Whether this process's GUI thread runs on the INPUT desktop (the one the
/// user sees). Cached: a thread's desktop is bound at startup and never
/// changes for the app. Failure to determine it is reported as `true`, so
/// the interactive path keeps its exact behavior when the query is denied.
var on_input_desktop_cache: ?bool = null;

pub fn onInputDesktop() bool {
    if (on_input_desktop_cache) |v| return v;
    const v = queryOnInputDesktop();
    on_input_desktop_cache = v;
    return v;
}

fn queryOnInputDesktop() bool {
    const mine = GetThreadDesktop(GetCurrentThreadId()) orelse return true;
    const input_desk = OpenInputDesktop(0, 0, DESKTOP_READOBJECTS) orelse return true;
    defer _ = CloseDesktop(input_desk);

    // Handles differ even for the same desktop object, so compare names.
    var mine_name: [256]u16 = undefined;
    var input_name: [256]u16 = undefined;
    var mine_len: u32 = 0;
    var input_len: u32 = 0;
    if (GetUserObjectInformationW(
        mine,
        UOI_NAME,
        &mine_name,
        @sizeOf(@TypeOf(mine_name)),
        &mine_len,
    ) == 0) return true;
    if (GetUserObjectInformationW(
        input_desk,
        UOI_NAME,
        &input_name,
        @sizeOf(@TypeOf(input_name)),
        &input_len,
    ) == 0) return true;
    if (mine_len != input_len) return false;
    const n = mine_len / @sizeOf(u16);
    return std.mem.eql(u16, mine_name[0..n], input_name[0..n]);
}

/// Read activation for `window_active`'s two decisions (T215): the one place
/// the GUI thread calls the OS about "which of our windows is active". Call
/// it on the GUI thread — `GetActiveWindow` answers for the CALLING thread's
/// message queue, which is the property that makes it survive off the input
/// desktop, and equally the reason it is meaningless from any other thread.
pub fn activation() window_active.Activation {
    return .{
        .on_input_desktop = onInputDesktop(),
        .foreground = @intFromPtr(GetForegroundWindow()),
        .active = @intFromPtr(GetActiveWindow()),
    };
}

/// True when `hwnd` is the window activation currently sits on. The whole
/// rule — and why it is not simply `GetForegroundWindow() == hwnd` — is in
/// `window_active.zig`.
pub fn windowIsActive(hwnd: ?HWND) bool {
    return window_active.isActive(activation(), @intFromPtr(hwnd));
}

pub const GA_ROOT: u32 = 2;

pub extern "user32" fn GetAncestor(
    hwnd: HWND,
    gaFlags: u32,
) callconv(.winapi) ?HWND;

pub extern "user32" fn GetWindowThreadProcessId(
    hWnd: HWND,
    lpdwProcessId: ?*u32,
) callconv(.winapi) u32;

pub extern "user32" fn AttachThreadInput(
    idAttach: u32,
    idAttachTo: u32,
    fAttach: i32,
) callconv(.winapi) i32;

pub extern "user32" fn SetForegroundWindow(
    hWnd: HWND,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Window positioning constants (additional)
// -----------------------------------------------------------------------

pub const HWND_TOPMOST: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
pub const SWP_NOACTIVATE: u32 = 0x0010;
pub const SWP_SHOWWINDOW: u32 = 0x0040;
/// Suppress the bit-block copy of the client area's old contents into the
/// new position. Correct whenever the whole surface is about to be
/// repainted anyway: the copy is what smears a stale image across a resize.
pub const SWP_NOCOPYBITS: u32 = 0x0100;
pub const WS_EX_TOPMOST: u32 = 0x00000008;
pub const SW_SHOWNOACTIVATE: i32 = 4;

// GetWindow relationships (z-order and ownership walks).
pub const GW_HWNDPREV: u32 = 3;
pub const GW_OWNER: u32 = 4;

pub extern "user32" fn GetWindow(
    hWnd: HWND,
    uCmd: u32,
) callconv(.winapi) ?HWND;

const overlay_zorder = @import("overlay_zorder.zig");

comptime {
    // The policy module duplicates this bit so it can be pure.
    std.debug.assert(WS_EX_TOPMOST == overlay_zorder.ex_topmost);
}

/// Walk down from `root` through the windows directly above it, and report
/// whether `hwnd` is in that run — i.e. whether any VISIBLE window that is
/// not one of `root`'s own overlays sits between the two.
///
/// Hidden windows are part of the z-order but cannot occlude anything, so
/// they are skipped; other popups owned by `root` (a sibling overlay of
/// another pane) are fine to have between us and the owner.
fn seatedAboveOwner(hwnd: HWND, root: HWND) bool {
    var next: ?HWND = GetWindow(root, GW_HWNDPREV);
    // Bounded: a pathological chain must fall through to a reseat, not spin.
    for (0..64) |_| {
        const cur = next orelse return false;
        switch (overlay_zorder.walkStep(.{
            .is_self = cur == hwnd,
            .is_visible = IsWindowVisible_(cur) != 0,
            .is_sibling = GetWindow(cur, GW_OWNER) == root,
        })) {
            .seated => return true,
            .reseat => return false,
            .keep_walking => next = GetWindow(cur, GW_HWNDPREV),
        }
    }
    return false;
}

/// Move `hwnd` into (or out of) the always-on-top band and CONFIRM it landed
/// there, returning whether it did (T277).
///
/// `SetWindowPos` is not a reliable report of its own outcome here: with no
/// foreground window — a background desktop, a locked session, the moment
/// between two windows taking focus — the first `HWND_TOPMOST` returns TRUE
/// with `GetLastError() == 0` and leaves `WS_EX_TOPMOST` clear. Measured on
/// this box: `ok=1 lasterr=0 after=0x100`, then an identical call issued on
/// the very next line lands (`after=0x108`). That is why
/// `toggle_window_float_on_top` read as "a feature that does nothing" from a
/// keybind while the same code worked from the menu — the menu happened to
/// run with a foreground window and the keybind path did not.
///
/// So the ex-style is read back and the call retried, up to
/// `overlay_zorder.band_change_attempts`. Callers that care get `false` and
/// can say so rather than reporting a float that never happened.
pub fn setTopmost(hwnd: HWND, want: bool) bool {
    const insert_after = if (want) HWND_TOPMOST else HWND_NOTOPMOST;
    const flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
    var attempt: u8 = 0;
    while (attempt < overlay_zorder.band_change_attempts) : (attempt += 1) {
        if (overlay_zorder.bandSettled(GetWindowLongW(hwnd, GWL_EXSTYLE), want)) return true;
        _ = SetWindowPos(hwnd, insert_after, 0, 0, 0, 0, flags);
    }
    const settled = overlay_zorder.bandSettled(GetWindowLongW(hwnd, GWL_EXSTYLE), want);
    if (!settled) std.log.scoped(.win32).warn(
        "topmost band change did not take want={} attempts={d}",
        .{ want, overlay_zorder.band_change_attempts },
    );
    return settled;
}

/// Re-assert the z-order of an owned overlay popup — the banner strip, dim
/// overlay, themed scrollbar and resize overlay — so that it sits directly
/// above the window it decorates and nowhere else (T142). Call after every
/// reposition; both failure modes are permanent until something does.
///
///   1. A stray `WS_EX_TOPMOST` another process left on the popup. We never
///      set it, and nothing else was clearing it.
///   2. A popup that was shown while its owner was NOT in front. Showing a
///      popup lifts it to the top of the non-topmost band, and ownership
///      only guarantees it stays above its OWNER — not below unrelated
///      windows. That is the "banner of a background window floats over the
///      foreground app" report, with no stray bit involved at all.
///
/// A no-op once the popup is seated, so the common path is a short z-order
/// walk and two `GetWindowLongW` reads.
///
/// When the owner is legitimately topmost (`toggle_window_float_on_top`, the
/// quick terminal) the topmost bit on the popup is NOT a stray and must be
/// left alone — demoting it would drop the banner out of the band its own
/// window is in, and Windows drags an owner out of the topmost band along with
/// any owned window that is demoted. The SEATING half still runs, though
/// (T277): being in the same band as your owner does not put you above it, and
/// a banner that was re-laid-out while its window was pinned measured three
/// windows BELOW its own window — a banner hidden behind the terminal it
/// describes. Only the demotion is skipped, not the re-seat.
///
/// `owner` may be a child window (the pane overlays are owned by the surface
/// HWND); the z-order — and the topmost bit — live on its top-level ancestor.
pub fn healOverlayZOrder(hwnd: HWND, owner: HWND) void {
    const root = GetAncestor(owner, GA_ROOT) orelse owner;
    const root_ex = GetWindowLongW(root, GWL_EXSTYLE);

    const flags = SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE;
    if (overlay_zorder.isStray(GetWindowLongW(hwnd, GWL_EXSTYLE), root_ex)) {
        _ = SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, flags);
    }
    if (seatedAboveOwner(hwnd, root)) return;

    // Insert AFTER whatever is directly above the owner (null = top of the
    // band, when the owner is already at the top). Inserting after the OWNER
    // itself would put the overlay behind it — an owned window is kept above
    // its owner when the SYSTEM orders them, but an explicit SetWindowPos is
    // honored as given, and the banner would vanish behind the terminal.
    _ = SetWindowPos(hwnd, GetWindow(root, GW_HWNDPREV), 0, 0, 0, 0, flags);
}

// -----------------------------------------------------------------------
// WinINet — HTTP client for update checks
// -----------------------------------------------------------------------

pub const HINTERNET = *opaque {};

pub const INTERNET_OPEN_TYPE_PRECONFIG: u32 = 0;
pub const INTERNET_FLAG_SECURE: u32 = 0x00800000;
pub const INTERNET_FLAG_NO_CACHE_WRITE: u32 = 0x04000000;
pub const INTERNET_FLAG_RELOAD: u32 = 0x80000000;

pub extern "wininet" fn InternetOpenW(
    lpszAgent: [*:0]const u16,
    dwAccessType: u32,
    lpszProxy: ?[*:0]const u16,
    lpszProxyBypass: ?[*:0]const u16,
    dwFlags: u32,
) callconv(.winapi) ?HINTERNET;

pub extern "wininet" fn InternetOpenUrlW(
    hInternet: HINTERNET,
    lpszUrl: [*:0]const u16,
    lpszHeaders: ?[*:0]const u16,
    dwHeadersLength: u32,
    dwFlags: u32,
    dwContext: usize,
) callconv(.winapi) ?HINTERNET;

pub extern "wininet" fn InternetReadFile(
    hFile: HINTERNET,
    lpBuffer: [*]u8,
    dwNumberOfBytesToRead: u32,
    lpdwNumberOfBytesRead: *u32,
) callconv(.winapi) i32;

pub extern "wininet" fn InternetCloseHandle(hInternet: HINTERNET) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Layered window painting
// -----------------------------------------------------------------------

pub const ULW_ALPHA: u32 = 0x00000002;
pub const AC_SRC_OVER: u8 = 0x00;
pub const AC_SRC_ALPHA: u8 = 0x01;
pub const WS_EX_TRANSPARENT: u32 = 0x00000020;
pub const WS_EX_NOACTIVATE: u32 = 0x08000000;

pub const BLENDFUNCTION = extern struct {
    BlendOp: u8 = AC_SRC_OVER,
    BlendFlags: u8 = 0,
    SourceConstantAlpha: u8 = 255,
    AlphaFormat: u8 = AC_SRC_ALPHA,
};

pub const SIZE = extern struct { cx: i32, cy: i32 };

pub extern "user32" fn UpdateLayeredWindow(
    hwnd: HWND,
    hdcDst: ?HDC,
    pptDst: ?*const POINT,
    psize: ?*const SIZE,
    hdcSrc: ?HDC,
    pptSrc: ?*const POINT,
    crKey: u32,
    pblend: ?*const BLENDFUNCTION,
    dwFlags: u32,
) callconv(.winapi) c_int;

// -----------------------------------------------------------------------
// DIB section
// -----------------------------------------------------------------------

pub const BI_RGB: u32 = 0;
pub const DIB_RGB_COLORS: u32 = 0;

pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = BI_RGB,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};

pub extern "gdi32" fn CreateDIBSection(
    hdc: ?HDC,
    pbmi: *const BITMAPINFO,
    usage: u32,
    ppvBits: *?*anyopaque,
    hSection: ?HANDLE,
    offset: u32,
) callconv(.winapi) ?HANDLE;

/// The `BITMAPV5HEADER` prefix, which is what `CF_DIBV5` on the clipboard
/// starts with. Only the fields up to the masks are named: everything past
/// them is colour-management metadata that GDI reads for us.
pub const BITMAPV5HEADER = extern struct {
    bV5Size: u32 = @sizeOf(BITMAPV5HEADER),
    bV5Width: i32,
    bV5Height: i32,
    bV5Planes: u16 = 1,
    bV5BitCount: u16 = 32,
    bV5Compression: u32 = BI_RGB,
    bV5SizeImage: u32 = 0,
    bV5XPelsPerMeter: i32 = 0,
    bV5YPelsPerMeter: i32 = 0,
    bV5ClrUsed: u32 = 0,
    bV5ClrImportant: u32 = 0,
    bV5RedMask: u32 = 0,
    bV5GreenMask: u32 = 0,
    bV5BlueMask: u32 = 0,
    bV5AlphaMask: u32 = 0,
    bV5CSType: u32 = 0,
    bV5Endpoints: [36]u8 = [_]u8{0} ** 36,
    bV5GammaRed: u32 = 0,
    bV5GammaGreen: u32 = 0,
    bV5GammaBlue: u32 = 0,
    bV5Intent: u32 = 0,
    bV5ProfileData: u32 = 0,
    bV5ProfileSize: u32 = 0,
    bV5Reserved: u32 = 0,
};

pub const BI_BITFIELDS: u32 = 3;

pub const BITMAP = extern struct {
    bmType: i32 = 0,
    bmWidth: i32 = 0,
    bmHeight: i32 = 0,
    bmWidthBytes: i32 = 0,
    bmPlanes: u16 = 0,
    bmBitsPixel: u16 = 0,
    bmBits: ?*anyopaque = null,
};

pub extern "gdi32" fn GetObjectW(
    h: HANDLE,
    c: i32,
    pv: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "gdi32" fn GetDIBits(
    hdc: HDC,
    hbm: HANDLE,
    start: u32,
    lines: u32,
    bits: ?*anyopaque,
    bmi: *BITMAPINFO,
    usage: u32,
) callconv(.winapi) i32;

pub extern "gdi32" fn StretchDIBits(
    hdc: HDC,
    xDest: i32,
    yDest: i32,
    destWidth: i32,
    destHeight: i32,
    xSrc: i32,
    ySrc: i32,
    srcWidth: i32,
    srcHeight: i32,
    bits: ?*const anyopaque,
    bmi: *const anyopaque,
    usage: u32,
    rop: u32,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Mouse activate
// -----------------------------------------------------------------------

pub const WM_MOUSEACTIVATE: u32 = 0x0021;
pub const MA_NOACTIVATE: isize = 3;

// -----------------------------------------------------------------------
// Registry
// -----------------------------------------------------------------------

pub const HKEY = *opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
pub const KEY_READ: u32 = 0x00020019;
/// Read the 32-bit registry view (`WOW6432Node` on a 64-bit box). EdgeUpdate
/// writes there, and letting the flag do the redirection keeps one path
/// string correct on both bitnesses (T372).
pub const KEY_WOW64_32KEY: u32 = 0x0200;
pub const KEY_QUERY_VALUE: u32 = 0x0001;
pub const KEY_SET_VALUE: u32 = 0x0002;
pub const REG_SZ: u32 = 1;
pub const REG_EXPAND_SZ: u32 = 2;
pub const REG_DWORD: u32 = 4;
pub const ERROR_SUCCESS: u32 = 0;
pub const ERROR_FILE_NOT_FOUND: u32 = 2;

pub extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const u16,
    ulOptions: u32,
    samDesired: u32,
    phkResult: *HKEY,
) callconv(.winapi) u32;

pub extern "advapi32" fn RegQueryValueExW(
    hKey: HKEY,
    lpValueName: [*:0]const u16,
    lpReserved: ?*u32,
    lpType: ?*u32,
    lpData: ?[*]u8,
    lpcbData: *u32,
) callconv(.winapi) u32;

pub extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    lpValueName: [*:0]const u16,
    Reserved: u32,
    dwType: u32,
    lpData: [*]const u8,
    cbData: u32,
) callconv(.winapi) u32;

/// Open, creating it (and every missing parent) when absent. The URL-scheme
/// handler (T695) writes a three-level key path into a hive that has none of it
/// yet, which `RegOpenKeyExW` cannot do.
pub extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const u16,
    Reserved: u32,
    lpClass: ?[*:0]const u16,
    dwOptions: u32,
    samDesired: u32,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*u32,
) callconv(.winapi) u32;

pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) u32;

/// Set (or, with a null value, remove) a process environment variable.
/// `std.process` has no portable setter, and the T372 probe tests need the
/// real process environment to change so the runtime-absent branch is
/// reachable on a box that HAS the runtime.
pub extern "kernel32" fn SetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpValue: ?[*:0]const u16,
) callconv(.winapi) i32;

pub extern "kernel32" fn ExpandEnvironmentStringsW(
    lpSrc: [*:0]const u16,
    lpDst: ?[*]u16,
    nSize: u32,
) callconv(.winapi) u32;

// -----------------------------------------------------------------------
// Settings change broadcast
// -----------------------------------------------------------------------

pub const WM_SETTINGCHANGE: u32 = 0x001A;
/// Broadcast by DWM when the user changes their accent color. `wparam` carries
/// the composed colorization color, which is NOT the accent (it is blended
/// with the afterglow and the opacity slider) — treat the message as a signal
/// and re-read the accent from the registry (`system_colors.zig`, T305).
pub const WM_DWMCOLORIZATIONCOLORCHANGED: u32 = 0x0320;
pub const WM_SHOWWINDOW: u32 = 0x0018;
pub const HWND_BROADCAST: HWND = @ptrFromInt(0xFFFF);
pub const SMTO_ABORTIFHUNG: u32 = 0x0002;

/// Case-insensitive wide-string compare. Used on the `WM_SETTINGCHANGE`
/// `lparam`, which is a pointer supplied by whoever broadcast the message —
/// `lstrcmpiW` is the canonical reader for it precisely because it guards the
/// dereference with structured exception handling, so a sender that passes a
/// bad pointer costs a mismatch rather than an access violation.
pub extern "kernel32" fn lstrcmpiW(
    lpString1: [*:0]const u16,
    lpString2: [*:0]const u16,
) callconv(.winapi) i32;

pub extern "user32" fn SendMessageTimeoutW(
    hWnd: HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
    fuFlags: u32,
    uTimeout: u32,
    lpdwResult: ?*usize,
) callconv(.winapi) isize;

// -----------------------------------------------------------------------
// SetWindowCompositionAttribute — accent blur-behind for background-blur.
// Undocumented but stable since Windows 10 (used by Windows Terminal et al).
// -----------------------------------------------------------------------

pub const ACCENT_DISABLED: i32 = 0;
pub const ACCENT_ENABLE_BLURBEHIND: i32 = 3;
pub const WCA_ACCENT_POLICY: u32 = 19;

pub const ACCENT_POLICY = extern struct {
    AccentState: i32,
    AccentFlags: u32,
    GradientColor: u32,
    AnimationId: u32,
};

pub const WINDOWCOMPOSITIONATTRIBDATA = extern struct {
    Attrib: u32,
    pvData: *anyopaque,
    cbData: usize,
};

pub extern "user32" fn SetWindowCompositionAttribute(
    hwnd: HWND,
    data: *WINDOWCOMPOSITIONATTRIBDATA,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// COM: ITaskbarList3 — taskbar button progress (OSC 9;4 progress reports)
// -----------------------------------------------------------------------

pub const GUID = std.os.windows.GUID;
pub const HRESULT = std.os.windows.HRESULT;
pub const BOOL = std.os.windows.BOOL;

pub const CLSCTX_INPROC_SERVER: u32 = 0x1;
pub const COINIT_APARTMENTTHREADED: u32 = 0x2;

pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
/// Free a buffer a COM method allocated with `CoTaskMemAlloc` — e.g. the
/// string `ICoreWebView2Environment::get_BrowserVersionString` hands back
/// (T372).
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

pub extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;

/// Create a growable in-memory `IStream`. `hGlobal` null + `fDeleteOnRelease`
/// TRUE means "allocate as I write, and free it with the stream" — the shape a
/// viewer response body wants, since the bytes are read once by the browser
/// process and then thrown away (T90e).
///
/// Typed as an opaque out-pointer because `IStream` itself is declared in
/// `webview2_iface.zig`, which this module must not depend on.
pub extern "ole32" fn CreateStreamOnHGlobal(
    hGlobal: ?*anyopaque,
    fDeleteOnRelease: BOOL,
    ppstm: *?*anyopaque,
) callconv(.winapi) HRESULT;

// {56FDF344-FD6D-11D0-958A-006097C9A090}
pub const CLSID_TaskbarList: GUID = .{
    .Data1 = 0x56FDF344,
    .Data2 = 0xFD6D,
    .Data3 = 0x11D0,
    .Data4 = .{ 0x95, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90 },
};
// {EA1AFB91-9E28-4B86-90E9-9E9F8A5EEFAF}
pub const IID_ITaskbarList3: GUID = .{
    .Data1 = 0xEA1AFB91,
    .Data2 = 0x9E28,
    .Data3 = 0x4B86,
    .Data4 = .{ 0x90, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF },
};

// TBPFLAG taskbar progress states.
pub const TBPF_NOPROGRESS: c_int = 0x0;
pub const TBPF_INDETERMINATE: c_int = 0x1;
pub const TBPF_NORMAL: c_int = 0x2;
pub const TBPF_ERROR: c_int = 0x4;
pub const TBPF_PAUSED: c_int = 0x8;

/// Minimal ITaskbarList3, declared through SetProgressState (the only methods
/// we call). The vtable layout mirrors the COM inheritance chain
/// IUnknown -> ITaskbarList -> ITaskbarList2 -> ITaskbarList3; trailing
/// ITaskbarList3 methods are omitted because we never call them.
pub const ITaskbarList3 = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*ITaskbarList3, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ITaskbarList3) callconv(.winapi) u32,
        Release: *const fn (*ITaskbarList3) callconv(.winapi) u32,
        // ITaskbarList
        HrInit: *const fn (*ITaskbarList3) callconv(.winapi) HRESULT,
        AddTab: *const fn (*ITaskbarList3, ?HWND) callconv(.winapi) HRESULT,
        DeleteTab: *const fn (*ITaskbarList3, ?HWND) callconv(.winapi) HRESULT,
        ActivateTab: *const fn (*ITaskbarList3, ?HWND) callconv(.winapi) HRESULT,
        SetActiveAlt: *const fn (*ITaskbarList3, ?HWND) callconv(.winapi) HRESULT,
        // ITaskbarList2
        MarkFullscreenWindow: *const fn (*ITaskbarList3, ?HWND, BOOL) callconv(.winapi) HRESULT,
        // ITaskbarList3
        SetProgressValue: *const fn (*ITaskbarList3, ?HWND, u64, u64) callconv(.winapi) HRESULT,
        SetProgressState: *const fn (*ITaskbarList3, ?HWND, c_int) callconv(.winapi) HRESULT,
    };

    pub fn HrInit(self: *ITaskbarList3) HRESULT {
        return self.vtable.HrInit(self);
    }
    pub fn Release(self: *ITaskbarList3) void {
        _ = self.vtable.Release(self);
    }
    pub fn SetProgressState(self: *ITaskbarList3, hwnd: ?HWND, flags: c_int) void {
        _ = self.vtable.SetProgressState(self, hwnd, flags);
    }
    pub fn SetProgressValue(self: *ITaskbarList3, hwnd: ?HWND, completed: u64, total: u64) void {
        _ = self.vtable.SetProgressValue(self, hwnd, completed, total);
    }
};

// --- Common color dialog (comdlg32) — T67 "Background Color…" picker ---

/// CHOOSECOLORW for ChooseColorW. rgbResult/lpCustColors are COLORREF
/// (0x00BBGGRR).
pub const CHOOSECOLORW = extern struct {
    lStructSize: u32 = @sizeOf(CHOOSECOLORW),
    hwndOwner: ?HWND = null,
    hInstance: ?HWND = null,
    rgbResult: u32 = 0,
    lpCustColors: ?*[16]u32 = null,
    Flags: u32 = 0,
    lCustData: usize = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
};

pub const CC_RGBINIT: u32 = 0x00000001;
pub const CC_FULLOPEN: u32 = 0x00000002;
pub const CC_ANYCOLOR: u32 = 0x00000100;

pub extern "comdlg32" fn ChooseColorW(lpcc: *CHOOSECOLORW) callconv(.winapi) BOOL;

// --- Common open-file dialog (comdlg32) — T396 "Viewer: Open File in Pane…" ---

/// OPENFILENAMEW for GetOpenFileNameW (the post-Win2000 shape, with the
/// three reserved trailing fields — comdlg32 sizes its behavior off
/// lStructSize, so the struct must be the full modern one).
pub const OPENFILENAMEW = extern struct {
    lStructSize: u32 = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HWND = null,
    hInstance: ?*anyopaque = null,
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*:0]u16 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: ?[*:0]u16 = null,
    nMaxFile: u32 = 0,
    lpstrFileTitle: ?[*:0]u16 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: usize = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};

pub const OFN_FILEMUSTEXIST: u32 = 0x00001000;
pub const OFN_PATHMUSTEXIST: u32 = 0x00000800;
pub const OFN_HIDEREADONLY: u32 = 0x00000004;
/// Without this the dialog CHANGES THE PROCESS CWD to the browsed
/// directory, which would silently re-aim every later relative-path
/// resolution in the app.
pub const OFN_NOCHANGEDIR: u32 = 0x00000008;
pub const OFN_EXPLORER: u32 = 0x00080000;

pub extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
