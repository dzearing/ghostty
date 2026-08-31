//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const gl = @import("opengl");
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Because OpenGL's frame completion is always
/// sync, we have no need for multi-buffering.
pub const swap_chain_count = 1;

const log = std.log.scoped(.opengl);

/// WGL declarations for Win32 OpenGL context management.
/// Only defined when building for the win32 apprt.
const wgl = if (apprt.runtime == apprt.win32) struct {
    extern "opengl32" fn wglMakeCurrent(
        hdc: ?*anyopaque,
        hglrc: ?*anyopaque,
    ) callconv(.c) i32;
    extern "opengl32" fn wglGetCurrentDC() callconv(.c) ?*anyopaque;
    extern "gdi32" fn SwapBuffers(hdc: ?*anyopaque) callconv(.c) i32;
    extern "user32" fn WindowFromDC(hdc: ?*anyopaque) callconv(.c) ?std.os.windows.HWND;
    const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
    extern "user32" fn GetClientRect(
        hwnd: std.os.windows.HWND,
        rect: *RECT,
    ) callconv(.c) i32;
} else struct {};

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The surface this renderer draws, kept only so the once-a-second frame
/// telemetry can name its pane (T1147). Deliberately NOT threadlocal state:
/// the first cut of this hung the pane id off `threadEnter`'s thread and
/// every sample logged `pane=-`, because the thread that enters the context
/// is not reliably the thread `drawFrameEnd` runs on. `drawFrameEnd` has
/// `self`, so `self` is where the answer belongs.
rt_surface: *apprt.Surface,

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

/// Lazily-created FBO + renderbuffer used to downscale the last target
/// for hero-mode thumbnails (T59a, win32 only). Sized snap_w x snap_h.
/// Owned by the GL context (freed with it; renderer-thread only).
snap_fbo: ?gl.Framebuffer = null,
snap_rbo: ?gl.Renderbuffer = null,
snap_w: u32 = 0,
snap_h: u32 = 0,

/// NOTE: This is an error{}!OpenGL instead of just OpenGL for parity with
///       Metal, since it needs to be fallible so does this, even though it
///       can't actually fail.
pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!OpenGL {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .rt_surface = opts.rt_surface,
    };
}

pub fn deinit(self: *OpenGL) void {
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".calling_convention;

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.info("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// This is called early right after surface creation.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        // GTK uses global OpenGL context so we load from null.
        apprt.gtk,
        => try prepareContext(null),

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },

        apprt.win32 => {
            // For Win32/WGL, make the context current on the main thread.
            // It stays current through Renderer.init() and finalizeSurfaceInit()
            // so OpenGL resources (shaders, textures, buffers) can be created.
            // It will be released in finalizeSurfaceInit (displayRealized)
            // right before the renderer thread is spawned.
            const hdc = surface.hdc orelse return error.InvalidSurface;
            const hglrc = surface.hglrc orelse return error.InvalidSurface;

            if (wgl.wglMakeCurrent(hdc, hglrc) == 0)
                return error.WGLMakeCurrentFailed;

            // Load GL functions. Passing null tells GLAD to use its
            // built-in loader which on Windows uses opengl32.dll +
            // wglGetProcAddress.
            try prepareContext(null);

            // NOTE: We intentionally do NOT release the context here.
            // Renderer.init() needs a current GL context to create resources.
            // The context is released in finalizeSurfaceInit/displayRealized.
        },
    }

    // These are very noisy so this is commented, but easy to uncomment
    // whenever we need to check the OpenGL extension list
    // if (builtin.mode == .Debug) {
    //     var ext_iter = try gl.ext.iterator();
    //     while (try ext_iter.next()) |ext| {
    //         log.debug("OpenGL extension available name={s}", .{ext});
    //     }
    // }
}

/// This is called just prior to spinning up the renderer
/// thread for final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;

    // On Win32, release the WGL context from the main thread so the
    // renderer thread can make it current in threadEnter. The context
    // was kept current since surfaceInit to allow Renderer.init() to
    // create GL resources.
    if (comptime apprt.runtime == apprt.win32) {
        _ = wgl.wglMakeCurrent(null, null);
    }
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // GTK doesn't support threaded OpenGL operations as far as I can
            // tell, so we use the renderer thread to setup all the state
            // but then do the actual draws and texture syncs and all that
            // on the main thread. As such, we don't do anything here.
        },

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },

        apprt.win32 => {
            // Make the WGL context current on the renderer thread.
            const hdc = surface.hdc orelse return error.InvalidSurface;
            const hglrc = surface.hglrc orelse return error.InvalidSurface;

            if (wgl.wglMakeCurrent(hdc, hglrc) == 0)
                return error.WGLMakeCurrentFailed;

            // Reload GL functions on this thread since OpenGL is
            // thread-local state.
            try prepareContext(null);
        },
    }
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const OpenGL) void {
    _ = self;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // We don't need to do any unloading for GTK because we may
            // be sharing the global bindings with other windows.
        },

        apprt.embedded => {
            // TODO: see threadEnter
        },

        apprt.win32 => {
            // Release the WGL context from the renderer thread.
            _ = wgl.wglMakeCurrent(null, null);
        },
    }
}

pub fn displayRealized(self: *const OpenGL) void {
    _ = self;

    switch (apprt.runtime) {
        apprt.gtk => prepareContext(null) catch |err| {
            log.warn(
                "Error preparing GL context in displayRealized, err={}",
                .{err},
            );
        },

        apprt.win32 => {
            // Release the WGL context from the main thread so the
            // renderer thread can make it current in threadEnter.
            // The context was kept current since surfaceInit to allow
            // Renderer.init() to create GL resources.
            _ = wgl.wglMakeCurrent(null, null);
        },

        else => @compileError("only GTK should be calling displayRealized"),
    }
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
///
/// On Win32 with double-buffered WGL, swap the front/back buffers
/// so the rendered frame appears on screen.
pub fn drawFrameEnd(self: *OpenGL) void {
    if (comptime apprt.runtime != apprt.win32) {
        // `_ = &self` rather than `_ = self`: on win32 `self` IS used below,
        // and a plain discard of a parameter that the function also uses is a
        // "pointless discard" compile error.
        _ = &self;
        return;
    }

    const hdc = wgl.wglGetCurrentDC();
    if (hdc != null) _ = wgl.SwapBuffers(hdc);
    perf.frame(self.rt_surface);
}

/// Win32 frame-pacing telemetry (T40/T48): when GHOZTTY_PERF is set in
/// the environment, log frames-per-second, the longest inter-frame gap,
/// and the max SwapBuffers-to-SwapBuffers stall once per second. Costs
/// one branch per frame when disabled. Renderer-thread only (each
/// surface has its own renderer thread; state is threadlocal so panes
/// don't interleave).
///
/// Every sample names its pane (T1147). Without that the log was a bag of
/// anonymous per-window numbers, and a grader could only reason about the
/// POPULATION: the soak's `median fps` assertion read a bimodal mix of idle
/// panes at 1 fps and loaded panes at the 60 cap, and answered a question
/// about how many panes happened to be idle. `pane=<uuid>` lets a harness
/// group by pane and grade the panes it actually loaded, and lets a reader
/// confirm from the log itself - rather than infer - that the fps=1
/// population is the idle pane.
const perf = struct {
    threadlocal var enabled: ?bool = null;
    threadlocal var window_start: ?std.time.Instant = null;
    threadlocal var last_frame: ?std.time.Instant = null;
    threadlocal var frames: u32 = 0;
    threadlocal var max_gap_ns: u64 = 0;

    fn frame(surface: *apprt.Surface) void {
        const on = enabled orelse on: {
            const on = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PERF");
            enabled = on;
            break :on on;
        };
        if (!on) return;

        const now = std.time.Instant.now() catch return;
        if (last_frame) |last| {
            const gap = now.since(last);
            if (gap > max_gap_ns) max_gap_ns = gap;
        }
        last_frame = now;
        frames += 1;

        const start = window_start orelse {
            window_start = now;
            return;
        };
        const elapsed = now.since(start);
        if (elapsed >= std.time.ns_per_s) {
            const fps = @as(u64, frames) * std.time.ns_per_s / @max(elapsed, 1);
            log.info(
                "perf pane={s} fps={d} max_gap_ms={d}",
                .{ surface.paneId(), fps, max_gap_ns / std.time.ns_per_ms },
            );
            window_start = now;
            frames = 0;
            max_gap_ns = 0;
        }
    }
};

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    _ = self;

    // On Win32, query the actual window client rect instead of
    // GL_VIEWPORT. GL_VIEWPORT is only updated when we call
    // glViewport explicitly (no framework does it for us), creating
    // a chicken-and-egg problem during resize. The Win32 Surface
    // caches the client dimensions from WM_SIZE.
    if (comptime apprt.runtime == apprt.win32) {
        // Use the thread-local WGL DC to find our HWND, then query
        // the actual window client rect for the current size.
        const hdc = wgl.wglGetCurrentDC() orelse return error.NoCurrentContext;
        const hwnd = wgl.WindowFromDC(hdc) orelse return error.NoWindow;
        var rect: wgl.RECT = undefined;
        if (wgl.GetClientRect(hwnd, &rect) != 0) {
            const w: u32 = @intCast(rect.right - rect.left);
            const h: u32 = @intCast(rect.bottom - rect.top);
            if (w > 0 and h > 0) {
                // Update glViewport to match
                gl.glad.context.Viewport.?(0, 0, @intCast(w), @intCast(h));
                return .{ .width = w, .height = h };
            }
        }
    }

    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    return Target.init(.{
        .internal_format = if (self.blending.isLinear()) .srgba else .rgba,
        .width = width,
        .height = height,
    });
}

/// Present the provided target.
pub fn present(self: *OpenGL, target: Target) !void {
    // In order to present a target we blit it to the default framebuffer.

    // We disable GL_FRAMEBUFFER_SRGB while doing this blit, otherwise the
    // values may be linearized as they're copied, but even though the draw
    // framebuffer has a linear internal format, the values in it should be
    // sRGB, not linear!
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };

    // Update the viewport to match the target dimensions. On Win32
    // there's no framework (like GTK's GLArea) that automatically
    // updates glViewport when the window resizes.
    gl.glad.context.Viewport.?(0, 0, @intCast(target.width), @intCast(target.height));

    // Bind the target for reading.
    const fbobind = try target.framebuffer.bind(.read);
    defer fbobind.unbind();

    // Blit
    gl.glad.context.BlitFramebuffer.?(
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        gl.c.GL_COLOR_BUFFER_BIT,
        gl.c.GL_NEAREST,
    );

    // Keep track of this target in case we need to repeat it.
    self.last_target = target;
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *OpenGL) !void {
    if (self.last_target) |target| try self.present(target);
}

/// Capture the last presented render target, downscaled to (w, h), as
/// bottom-up BGRA pixels into `out` (len must be w*h*4). Renderer thread,
/// win32 hero-mode thumbnails (T59a). Reads from the OFFSCREEN target
/// texture — not the window back buffer — so it stays valid for panes
/// whose HWND is hidden (no DWM redirection / pixel-ownership involved).
pub fn captureThumb(self: *OpenGL, w: u32, h: u32, out: []u8) !void {
    const target = self.last_target orelse return error.NoFrameYet;
    if (out.len != @as(usize, w) * @as(usize, h) * 4) return error.BadBufferSize;

    if (self.snap_fbo == null) self.snap_fbo = try gl.Framebuffer.create();
    if (self.snap_rbo == null) self.snap_rbo = try gl.Renderbuffer.create();
    if (self.snap_w != w or self.snap_h != h) {
        {
            const rb = try self.snap_rbo.?.bind();
            defer rb.unbind();
            try rb.storage(.rgba, @intCast(w), @intCast(h));
        }
        {
            const fb = try self.snap_fbo.?.bind(.framebuffer);
            defer fb.unbind();
            try fb.renderbuffer(.color0, self.snap_rbo.?);
        }
        self.snap_w = w;
        self.snap_h = h;
    }

    // Copy raw values: without this the blit would linearize/encode sRGB
    // (same reasoning as present()).
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };

    {
        const draw = try self.snap_fbo.?.bind(.draw);
        defer draw.unbind();
        const read = try target.framebuffer.bind(.read);
        defer read.unbind();
        gl.glad.context.BlitFramebuffer.?(
            0,
            0,
            @intCast(target.width),
            @intCast(target.height),
            0,
            0,
            @intCast(w),
            @intCast(h),
            gl.c.GL_COLOR_BUFFER_BIT,
            gl.c.GL_LINEAR,
        );
    }

    {
        const read = try self.snap_fbo.?.bind(.read);
        defer read.unbind();
        gl.glad.context.ReadBuffer.?(gl.c.GL_COLOR_ATTACHMENT0);
        gl.glad.context.PixelStorei.?(gl.c.GL_PACK_ALIGNMENT, 4);
        gl.glad.context.ReadPixels.?(
            0,
            0,
            @intCast(w),
            @intCast(h),
            gl.c.GL_BGRA,
            gl.c.GL_UNSIGNED_BYTE,
            out.ptr,
        );
    }
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2D",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2D",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .Rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}
