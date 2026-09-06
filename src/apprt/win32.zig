//! Vendored from InsipidPoint/ghostty-windows (MIT, same license as upstream
//! Ghostty) and adapted for the Ghoztty fork.
//! Win32 application runtime for Ghostty on Windows.
//! Uses native Win32 API for windowing, input, and clipboard.

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");

const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    _ = @import("win32/ConfirmDialog.zig");
    // The startup-failure reporter (T1177). Its message composition is the
    // only part of that path a lane can check — the dialog itself needs a
    // desktop — and the whole point of the module is that it speaks when
    // nothing else can, so an untested message is how "loud" becomes "loud and
    // wrong". Listed here because THIS LIST is what pulls a file's tests into
    // the lane: the module was already imported by `App.zig` and compiled, and
    // a deliberately broken assertion inside it still went green until the line
    // below existed.
    _ = @import("win32/startup_error.zig");
    // The update-download progress panel (T1195). Its LAYOUT is the part a
    // lane can check - the paint needs a desktop - and a panel whose rows
    // overlap at 1.5x is a panel nobody can read the status line off.
    _ = @import("win32/UpdateProgress.zig");
    _ = @import("win32/RenameDialog.zig");
    _ = @import("win32/MachineChooser.zig");
    _ = @import("win32/DarkMode.zig");
    // The system accent reader (T304). Listed here so the win32 lane actually
    // COMPILES it before T305 has a caller — an OS-touching module with no
    // reference is not checked by any lane, and discovering that in the
    // wiring task is discovering it too late.
    _ = @import("win32/system_colors.zig");
    // The split tree's leaf type and the viewer leaf it makes room for
    // (T90c). ViewerPane has no constructor caller until T90d, and the same
    // rule as system_colors applies: a module no lane compiles is a module
    // nobody has checked.
    _ = @import("win32/PaneView.zig");
    _ = @import("win32/ViewerPane.zig");
    // The COM callback object every WebView2 handler is an instance of
    // (T376). Listed in its own right, not just as webview2.zig's import:
    // its refcount and interface matching are the part a fifth handler would
    // have got wrong, so the lane should name what it is checking.
    _ = @import("win32/com.zig");
    // The WebView2 host floor (T372): the loader-less runtime probe and the
    // shared environment. Same rule again — T373 is its first caller, and a
    // module that touches the registry, LoadLibraryW and a COM vtable is the
    // last one that should go uncompiled until then.
    _ = @import("win32/webview2.zig");
    // The agent-refresh relaunch guard (T421). Its spec parser is the only
    // thing standing between a malformed environment variable and a guard that
    // waits on the wrong pid, so the lane compiles and checks it in its own
    // right.
    _ = @import("win32/relaunch_guard.zig");
    // The Disconnect policy and its detach pin (T1390). Both are pure, and the
    // pin's whole reason for existing is an ORDERING invariant that a desktop
    // test could only observe by accident — so the lane is where it is checked.
    _ = @import("win32/session_disconnect.zig");
    // The update applier (T1178). Same argument as the guard above: it is the
    // process that replaces the app on disk, it runs when no app is left to
    // notice it going wrong, and its staging paths are per lineage so a debug
    // run cannot install over the user's release.
    _ = @import("win32/update_install.zig");
    // Restart Manager participation (T1204). Listed here for the T1191 reason
    // the startup reporter above is: nothing else pulls this module's tests
    // into the lane, and its whole subject — which restart flags we ask for,
    // and telling an installer's close from a logoff — is decided by constants
    // that a lane can check and a running install cannot be asked to repeat.
    _ = @import("win32/restart_manager.zig");
    // The installer prepare step (T1207). Its command-line parser decides
    // whether a normal `ghoztty.exe` start is quietly turned into a
    // non-terminal, and its image list is what stands between an MSI and the
    // user's live sessions — both are constants and pure logic a lane can
    // check, and neither can be asked of a running install.
    _ = @import("win32/install_prepare.zig");
    // The installer maintenance prompt (T1291). Same argument as the prepare
    // step above, plus one of its own: the two exit codes it hands msiexec ARE
    // the feature — 0 repairs, 1602 cancels quietly, and any other value is
    // error 1721 in the user's face — and no lane can learn that from a real
    // install, because a real install would replace the user's Ghoztty.
    _ = @import("win32/install_maintenance.zig");
    _ = @import("win32/install_restart.zig");
    // Escaping the app's job object, and measuring who is in it (T524, T426).
    // Both are what stands between a daemon/supervisor and dying with the
    // process it exists to outlive, so the lane compiles and checks them in
    // their own right rather than only through their callers.
    _ = @import("win32/job_spawn.zig");
    _ = @import("win32/job_object.zig");
    // The startup self-escape from the agent's kill-on-close PTY job (T675).
    // Its decision function is what stands between a pane-launched app and
    // dying mid-refresh — and equally between a clean launch and a pointless
    // re-exec — so the lane checks it in its own right.
    _ = @import("win32/job_escape.zig");
    // The named-target registry (T121). Its auto `window-N` allocator is the
    // thing that must never re-mint a name a restored window already adopted,
    // and that is pure logic worth checking in its own right.
    _ = @import("win32/IpcRegistry.zig");
    // The retried clipboard open (T850). Every clipboard user on Windows
    // shares one machine-wide, serialized resource, and the difference between
    // one attempt and a bounded retry is whether "copy did nothing" is a
    // routine outcome — so the budget is checked in its own right rather than
    // only through whichever caller happens to be compiled.
    _ = @import("win32/clipboard_open.zig");
    // The `ghoztty://` URL scheme's win32 half (T695): the registry entry a
    // clicked link is resolved through, and the activation process that
    // answers it. The registration strings decide whether a link reaches this
    // build at all, so the lane checks them rather than only the grammar.
    _ = @import("win32/url_scheme.zig");
    // The four modules T1191's reachability sweep found with tests that had
    // never once executed. Each is imported and used by `App.zig`,
    // `IpcHandlers.zig` or `Surface.zig` — which is exactly what makes the
    // silence hard to see: they compile in every lane, they read as covered,
    // and the lane skipped all sixteen of their tests. THIS LIST is the only
    // thing that pulls them in, so they are named here and the sweep
    // (`test/win32/test-reach-audit.ps1`) fails if any win32 module with
    // tests drops off the chain again.
    _ = @import("win32/AgentIntegrationsDialog.zig");
    _ = @import("win32/ipc_agent_integration.zig");
    _ = @import("win32/provenance.zig");
    _ = @import("win32/restore_retry.zig");
}
