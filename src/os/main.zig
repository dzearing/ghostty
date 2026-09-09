//! The "os" package contains utilities for interfacing with the operating
//! system. These aren't restricted to syscalls or low-level operations, but
//! also OS-specific features and conventions.

const builtin = @import("builtin");

const dbus = @import("dbus.zig");
const desktop = @import("desktop.zig");
const env = @import("env.zig");
const file = @import("file.zig");
const flatpak = @import("flatpak.zig");
const homedir = @import("homedir.zig");
const locale = @import("locale.zig");
const mouse = @import("mouse.zig");
const openpkg = @import("open.zig");
const pipepkg = @import("pipe.zig");
const resourcesdir = @import("resourcesdir.zig");
const systemd = @import("systemd.zig");
const kernel_info = @import("kernel_info.zig");

// Namespaces
pub const args = @import("args.zig");
pub const cgroup = @import("cgroup.zig");
pub const cli_launch = @import("cli_launch.zig");
pub const hostname = @import("hostname.zig");
pub const i18n = @import("i18n.zig");
pub const ipc_client = @import("ipc_client.zig");
pub const ipc_handoff = @import("ipc_handoff.zig");
pub const ipc_timeout = @import("ipc_timeout.zig");
pub const listening_pid = @import("listening_pid.zig");
pub const log_stamp = @import("log_stamp.zig");
pub const log_rotate = @import("log_rotate.zig");
pub const mach = @import("mach.zig");
pub const path = @import("path.zig");
pub const power = @import("power.zig");
pub const path_env = @import("path_env.zig");
pub const process_cwd = @import("process_cwd.zig");
pub const self_exe = @import("self_exe.zig");
pub const source_checkout = @import("source_checkout.zig");
pub const passwd = @import("passwd.zig");
pub const user_env = @import("user_env.zig");
pub const xdg = @import("xdg.zig");
pub const windows = @import("windows.zig");
pub const macos = @import("macos.zig");
pub const shell = @import("shell.zig");
pub const uri = @import("uri.zig");

// Functions and types
pub const CFReleaseThread = @import("cf_release_thread.zig");
pub const TempDir = @import("TempDir.zig");
pub const GetEnvResult = env.GetEnvResult;
pub const getEnvMap = env.getEnvMap;
pub const appendEnv = env.appendEnv;
pub const appendEnvAlways = env.appendEnvAlways;
pub const prependEnv = env.prependEnv;
pub const getenv = env.getenv;
pub const setenv = env.setenv;
pub const unsetenv = env.unsetenv;
pub const launchedFromDesktop = desktop.launchedFromDesktop;
pub const launchedByDbusActivation = dbus.launchedByDbusActivation;
pub const launchedBySystemd = systemd.launchedBySystemd;
pub const desktopEnvironment = desktop.desktopEnvironment;
pub const rlimit = file.rlimit;
pub const fixMaxFiles = file.fixMaxFiles;
pub const restoreMaxFiles = file.restoreMaxFiles;
pub const allocTmpDir = file.allocTmpDir;
pub const freeTmpDir = file.freeTmpDir;
pub const randomTmpPath = file.randomTmpPath;
pub const isFlatpak = flatpak.isFlatpak;
pub const FlatpakHostCommand = flatpak.FlatpakHostCommand;
pub const home = homedir.home;
pub const expandHome = homedir.expandHome;
pub const ensureLocale = locale.ensureLocale;
pub const clickInterval = mouse.clickInterval;
pub const open = openpkg.open;
pub const OpenType = openpkg.Type;
pub const pipe = pipepkg.pipe;
pub const resourcesDir = resourcesdir.resourcesDir;
pub const ResourcesDir = resourcesdir.ResourcesDir;
pub const ShellEscapeWriter = shell.ShellEscapeWriter;
pub const getKernelInfo = kernel_info.getKernelInfo;

test {
    _ = cli_launch;
    _ = file;
    _ = i18n;
    _ = ipc_client;
    _ = ipc_handoff;
    _ = ipc_timeout;
    _ = listening_pid;
    _ = log_stamp;
    _ = log_rotate;
    _ = path;
    _ = path_env;
    _ = process_cwd;
    _ = self_exe;
    _ = source_checkout;
    _ = uri;
    _ = shell;
    _ = user_env;

    if (comptime builtin.os.tag == .linux) {
        _ = kernel_info;
    } else if (comptime builtin.os.tag.isDarwin()) {
        _ = mach;
        _ = macos;
    }
}
