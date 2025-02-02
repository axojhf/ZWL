const std = @import("std");
const builtin = @import("builtin");
const zwl = @import("zwl.zig");
const log = std.log.scoped(.zwl);
const Allocator = std.mem.Allocator;

const gl = @import("opengl.zig");

pub const windows = @import("win32").everything;

const classname = std.unicode.utf8ToUtf16LeStringLiteral("ZWL");

const WGL_DRAW_TO_WINDOW_ARB = 0x2001;
const WGL_ACCELERATION_ARB = 0x2003;
const WGL_SUPPORT_OPENGL_ARB = 0x2010;
const WGL_DOUBLE_BUFFER_ARB = 0x2011;
const WGL_PIXEL_TYPE_ARB = 0x2013;
const WGL_COLOR_BITS_ARB = 0x2014;
const WGL_DEPTH_BITS_ARB = 0x2022;
const WGL_STENCIL_BITS_ARB = 0x2023;
const WGL_FULL_ACCELERATION_ARB = 0x2027;
const WGL_TYPE_RGBA_ARB = 0x202B;

const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;
const WGL_CONTEXT_FLAGS_ARB = 0x2094;
const WGL_CONTEXT_DEBUG_BIT_ARB = 0x0001;
const WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB = 0x00000002;

pub fn Platform(comptime Parent: anytype) type {
    return struct {
        const Self = @This();

        parent: Parent,
        instance: windows.HINSTANCE,
        revent: ?Parent.Event = null,
        libgl: ?windows.HINSTANCE,

        pub fn init(allocator: Allocator, options: zwl.PlatformOptions) !*Parent {
            _ = options;
            var self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const module_handle = windows.GetModuleHandleW(null) orelse unreachable;

            const window_class_info = windows.WNDCLASSEXW{
                .cbSize = @sizeOf(windows.WNDCLASSEXW),
                // .style = windows.CS_OWNDC | windows.CS_HREDRAW | windows.CS_VREDRAW,
                .style = windows.WNDCLASS_STYLES.initFlags(.{ .OWNDC = 1, .HREDRAW = 1, .VREDRAW = 1 }),
                .lpfnWndProc = windowProc,
                .cbClsExtra = 0,
                .cbWndExtra = @sizeOf(usize),
                .hInstance = @as(windows.HINSTANCE, @ptrCast(module_handle)),
                .hIcon = null,
                .hCursor = null,
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = classname,
                .hIconSm = null,
            };
            if (windows.RegisterClassExW(&window_class_info) == 0) {
                return error.RegisterClassFailed;
            }

            self.* = .{
                .parent = .{
                    .allocator = allocator,
                    .type = .Windows,
                    .window = undefined,
                    .windows = if (!Parent.settings.single_window) &[0]*Parent.Window{} else undefined,
                },
                .instance = @as(windows.HINSTANCE, @ptrCast(module_handle)),
                .libgl = null,
            };

            if (Parent.settings.backends_enabled.opengl) {
                self.libgl = windows.LoadLibraryA("opengl32.dll") orelse return error.MissingOpenGL;
            }

            log.info("Platform Initialized: Windows", .{});
            return @as(*Parent, @ptrCast(self));
        }

        pub fn deinit(self: *Self) void {
            if (self.libgl) |libgl| {
                _ = windows.FreeLibrary(libgl);
            }
            _ = windows.UnregisterClassW(classname, self.instance);
            self.parent.allocator.destroy(self);
        }

        pub fn getOpenGlProcAddress(self: *Self, entry_point: [:0]const u8) ?*anyopaque {
            // std.debug.print("lookup {} with ", .{
            //     std.mem.span(entry_point),
            // });
            if (self.libgl) |libgl| {
                const T = *const fn (entry_point: [*:0]const u8) ?*anyopaque;

                // std.debug.print("libgl: {} entry_point: {s} \n", .{ libgl, entry_point });
                if (windows.GetProcAddress(libgl, "wglGetProcAddress")) |wglGetProcAddress| {
                    // std.debug.print("dynamic wglGetProcAddress: {}\n", .{wglGetProcAddress});
                    // var tmp = @as(T, @ptrCast(wglGetProcAddress))(entry_point);
                    // std.debug.print("tmp: {?}\n", .{tmp});
                    if (@as(T, @ptrCast(wglGetProcAddress))(entry_point)) |ptr| {
                        // std.debug.print("dynamic wglGetProcAddress: {}\n", .{ptr});
                        return @as(*anyopaque, @ptrCast(ptr));
                    }
                }

                if (windows.GetProcAddress(libgl, entry_point)) |ptr| {
                    // std.debug.print("GetProcAddress: {}\n", .{ptr});
                    return @as(*anyopaque, @ptrCast(@constCast(ptr)));
                }
            }

            if (windows.wglGetProcAddress(entry_point)) |ptr| {
                // std.debug.print("wglGetProcAddress: {}\n", .{ptr});
                return @constCast(ptr);
            }

            // std.debug.print("none.\n", .{});
            return null;
        }

        fn windowProc(hwnd: windows.HWND, uMsg: u32, wParam: windows.WPARAM, lParam: windows.LPARAM) callconv(std.os.windows.WINAPI) windows.LRESULT {
            // const msg = @as(std.os.windows.user32.WM, @enumFromInt(uMsg));
            switch (uMsg) {
                windows.WM_CLOSE => {
                    _ = windows.DestroyWindow(hwnd);
                },
                windows.WM_DESTROY => {
                    var window_opt: ?*Window = @ptrFromInt(@as(usize, @bitCast(windows.GetWindowLongPtrW(hwnd, @enumFromInt(0)))));
                    if (window_opt) |window| {
                        var platform = @as(*Self, @ptrCast(window.parent.platform));
                        window.handle = null;
                        platform.revent = Parent.Event{ .WindowDestroyed = @as(*Parent.Window, @ptrCast(window)) };
                    } else {
                        log.err("Received message {} for unknown window {}", .{ uMsg, hwnd });
                    }
                },
                windows.WM_CREATE => {
                    const create_info_opt: ?*windows.CREATESTRUCTW = @ptrFromInt(@as(usize, @intCast(lParam)));
                    if (create_info_opt) |create_info| {
                        _ = windows.SetWindowLongPtrW(hwnd, @enumFromInt(0), @bitCast(@intFromPtr(create_info.lpCreateParams)));
                    } else {
                        return @as(windows.LRESULT, @bitCast(@as(isize, -1)));
                    }
                },
                windows.WM_SIZE => {
                    var window_opt: ?*Window = @ptrFromInt(@as(usize, @bitCast(windows.GetWindowLongPtrW(hwnd, @enumFromInt(0)))));
                    if (window_opt) |window| {
                        const dim = @as([2]u16, @bitCast(@as(u32, @intCast(lParam))));
                        if (dim[0] != window.width or dim[1] != window.height) {
                            var platform = @as(*Self, @ptrCast(window.parent.platform));
                            window.width = dim[0];
                            window.height = dim[1];

                            if (window.backend == .software) {
                                if (window.backend.software.createBitmap(window.width, window.height)) |new_bmp| {
                                    window.backend.software.bitmap.destroy();
                                    window.backend.software.bitmap = new_bmp;
                                } else |err| {
                                    log.err("failed to recreate software framebuffer: {}", .{err});
                                }
                            }

                            platform.revent = Parent.Event{ .WindowResized = @as(*Parent.Window, @ptrCast(window)) };
                        }
                    } else {
                        log.err("Received message {} for unknown window {}", .{ uMsg, hwnd });
                    }
                },
                windows.WM_PAINT => {
                    var window_opt: ?*Window = @ptrFromInt(@as(usize, @bitCast(windows.GetWindowLongPtrW(hwnd, @enumFromInt(0)))));
                    if (window_opt) |window| {
                        var platform: *Self = @ptrCast(window.parent.platform);

                        var ps = std.mem.zeroes(windows.PAINTSTRUCT);
                        if (windows.BeginPaint(hwnd, &ps)) |hDC| {
                            _ = hDC;
                            defer _ = windows.EndPaint(hwnd, &ps);
                            if (window.backend == .software) {
                                // TODO software render
                                // const render_context = &window.backend.software;

                                // const hOldBmp = windows.SelectObject(
                                //     render_context.memory_dc,
                                //     render_context.bitmap.handle.toGdiObject(),
                                // );
                                // defer _ = windows.SelectObject(render_context.memory_dc, hOldBmp);

                                // _ = windows.BitBlt(
                                //     hDC,
                                //     0,
                                //     0,
                                //     render_context.bitmap.width,
                                //     render_context.bitmap.height,
                                //     render_context.memory_dc,
                                //     0,
                                //     0,
                                //     @intFromEnum(windows.TernaryRasterOperation.SRCCOPY),
                                // );
                            }
                        }

                        platform.revent = Parent.Event{ .WindowVBlank = @as(*Parent.Window, @ptrCast(window)) };
                    } else {
                        log.err("Received message {} for unknown window {}", .{ uMsg, hwnd });
                    }
                },

                // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-mousemove
                windows.WM_MOUSEMOVE => {
                    var window_opt: ?*Window = @ptrFromInt(@as(usize, @bitCast(windows.GetWindowLongPtrW(hwnd, @enumFromInt(0)))));
                    if (window_opt) |window| {
                        var platform = @as(*Self, @ptrCast(window.parent.platform));

                        const pos = @as([2]u16, @bitCast(@as(u32, @intCast(lParam))));

                        platform.revent = Parent.Event{
                            .MouseMotion = .{
                                .x = @as(i16, @intCast(pos[0])),
                                .y = @as(i16, @intCast(pos[1])),
                            },
                        };
                    } else {
                        log.err("Received message {} for unknown window {}", .{ uMsg, hwnd });
                    }
                },
                windows.WM_LBUTTONDOWN, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-lbuttondown
                windows.WM_LBUTTONUP, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-lbuttonup
                windows.WM_RBUTTONDOWN, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-rbuttondown
                windows.WM_RBUTTONUP, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-rbuttonup
                windows.WM_MBUTTONDOWN, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-mbuttondown
                windows.WM_MBUTTONUP, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-mbuttonup
                => {
                    var window_opt: ?*Window = @ptrFromInt(@as(usize, @bitCast(windows.GetWindowLongPtrW(hwnd, @enumFromInt(0)))));
                    if (window_opt) |window| {
                        var platform: *Self = @ptrCast(window.parent.platform);

                        const pos = @as([2]u16, @bitCast(@as(u32, @intCast(lParam))));

                        var data = zwl.MouseButtonEvent{
                            .x = @as(i16, @intCast(pos[0])),
                            .y = @as(i16, @intCast(pos[1])),
                            .button = switch (uMsg) {
                                windows.WM_LBUTTONDOWN, windows.WM_LBUTTONUP => .left,
                                windows.WM_MBUTTONDOWN, windows.WM_MBUTTONUP => .middle,
                                windows.WM_RBUTTONDOWN, windows.WM_RBUTTONUP => .right,
                                else => unreachable,
                            },
                        };

                        platform.revent = if ((uMsg == windows.WM_LBUTTONDOWN) or (uMsg == windows.WM_MBUTTONDOWN) or (uMsg == windows.WM_RBUTTONDOWN))
                            Parent.Event{ .MouseButtonDown = data }
                        else
                            Parent.Event{ .MouseButtonUp = data };
                    } else {
                        log.err("Received message {} for unknown window {}", .{ uMsg, hwnd });
                    }
                },
                windows.WM_KEYDOWN, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-keydown
                windows.WM_KEYUP, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-keydown
                => {
                    var window_opt: ?*Window = @ptrFromInt(@as(usize, @bitCast(windows.GetWindowLongPtrW(hwnd, @enumFromInt(0)))));
                    if (window_opt) |window| {
                        var platform: *Self = @ptrCast(window.parent.platform);

                        var kevent = zwl.KeyEvent{
                            .scancode = @as(u8, @truncate(@as(usize, @intCast(lParam)) >> 16)), // 16-23 is the OEM scancode
                        };

                        platform.revent = if (uMsg == windows.WM_KEYDOWN)
                            Parent.Event{ .KeyDown = kevent }
                        else
                            Parent.Event{ .KeyUp = kevent };
                    } else {
                        log.err("Received message {} for unknown window {}", .{ uMsg, hwnd });
                    }
                },
                else => {
                    // log.debug("default windows message: 0x{X:0>4}", .{uMsg});
                    return windows.DefWindowProcW(hwnd, uMsg, wParam, lParam);
                },
            }
            return 0;
        }

        pub fn waitForEvent(self: *Self) !Parent.Event {
            var msg: windows.MSG = undefined;
            while (true) {
                if (self.revent) |rev| {
                    self.revent = null;
                    return rev;
                }
                const ret = windows.GetMessageW(&msg, null, 0, 0);
                if (ret == -1) unreachable;
                if (ret == 0) return Parent.Event{ .ApplicationTerminated = undefined };
                _ = windows.TranslateMessage(&msg);
                _ = windows.DispatchMessageW(&msg);
            }
        }

        pub fn createWindow(self: *Self, options: zwl.WindowOptions) !*Parent.Window {
            var window = try self.parent.allocator.create(Window);
            errdefer self.parent.allocator.destroy(window);
            try window.init(self, options);
            return @as(*Parent.Window, @ptrCast(window));
        }

        pub const Window = struct {
            const Backend = union(enum) {
                none,
                software: RenderContext,
                opengl: windows.HGLRC,
            };

            parent: Parent.Window,
            handle: ?windows.HWND,
            width: u16,
            height: u16,
            backend: Backend,

            pub fn init(self: *Window, platform: *Self, options: zwl.WindowOptions) !void {
                self.* = .{
                    .parent = .{
                        .platform = @as(*Parent, @ptrCast(platform)),
                    },
                    .width = options.width orelse 800,
                    .height = options.height orelse 600,
                    .handle = undefined,
                    .backend = .none,
                };

                var namebuf: [512]u8 = undefined;
                var name_allocator = std.heap.FixedBufferAllocator.init(&namebuf);
                const title = try std.unicode.utf8ToUtf16LeWithNull(name_allocator.allocator(), options.title orelse "");
                var style: u32 = 0;
                style += if (options.visible == true) @intFromEnum(windows.WS_VISIBLE) else 0;
                style += if (options.decorations == true) @intFromEnum(windows.WS_CAPTION) | @intFromEnum(windows.WS_MAXIMIZEBOX) | @intFromEnum(windows.WS_MINIMIZEBOX) | @intFromEnum(windows.WS_SYSMENU) else 0;
                style += if (options.resizeable == true) @intFromEnum(windows.WS_SIZEBOX) else 0;

                // mode, transparent...
                // CLIENT_RECT stuff... GetClientRect, GetWindowRect

                var rect = windows.RECT{ .left = 0, .top = 0, .right = self.width, .bottom = self.height };
                _ = windows.AdjustWindowRectEx(&rect, @enumFromInt(style), 0, @enumFromInt(0));
                const x = windows.CW_USEDEFAULT;
                const y = windows.CW_USEDEFAULT;
                const w = rect.right - rect.left;
                const h = rect.bottom - rect.top;

                const handle = windows.CreateWindowExW(.LEFT, classname, title, @enumFromInt(style), x, y, w, h, null, null, platform.instance, self) orelse
                    return error.CreateWindowFailed;

                self.handle = handle;

                self.backend = switch (options.backend) {
                    // .software => {},
                    // TODO soft render
                    // .software => blk: {
                    // const hDC = windows.getDC(handle) catch return error.CreateWindowFailed;
                    // defer _ = windows.releaseDC(handle, hDC);

                    // var render_context = RenderContext{
                    //     .memory_dc = undefined,
                    //     .bitmap = undefined,
                    // };
                    // render_context.memory_dc = windows.CreateCompatibleDC(hDC) orelse return error.CreateWindowFailed;
                    // errdefer _ = windows.DeleteDC(render_context.memory_dc);

                    // render_context.bitmap = render_context.createBitmap(self.width, self.height) catch return error.CreateWindowFailed;
                    // errdefer render_context.bitmap.destroy();

                    // break :blk Backend{ .software = render_context };
                    // },
                    .opengl => |requested_gl| blk: {
                        if (Parent.settings.backends_enabled.opengl) {
                            const window_class = windows.WNDCLASSA{
                                .style = windows.WNDCLASS_STYLES.initFlags(.{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 }),
                                .lpfnWndProc = windows.DefWindowProcA,
                                .hInstance = windows.GetModuleHandleA(null),
                                .lpszClassName = "Dummy_WGL_ZWL",
                                .cbClsExtra = 0,
                                .cbWndExtra = 0,
                                .hIcon = null,
                                .hCursor = null,
                                .hbrBackground = null,
                                .lpszMenuName = null,
                            };
                            if (windows.RegisterClassA(&window_class) == 0) {
                                @panic("Failed to register dummy OpenGL window.");
                            }
                            const dummy_window: windows.HWND = windows.CreateWindowExA(
                                @enumFromInt(0),
                                window_class.lpszClassName,
                                "Dummy OpenGL Window",
                                @enumFromInt(0),
                                windows.CW_USEDEFAULT,
                                windows.CW_USEDEFAULT,
                                windows.CW_USEDEFAULT,
                                windows.CW_USEDEFAULT,
                                null,
                                null,
                                window_class.hInstance,
                                null,
                            ) orelse @panic("Failed to create dummy OpenGL window.");
                            const dummy_dc = windows.GetDC(dummy_window) orelse @panic("couldn't get dummy DC!");

                            const pfd = windows.PIXELFORMATDESCRIPTOR{
                                .nSize = @sizeOf(windows.PIXELFORMATDESCRIPTOR),
                                .nVersion = 1,
                                // .dwFlags = windows.PFD_DRAW_TO_WINDOW | windows.PFD_SUPPORT_OPENGL | windows.PFD_DOUBLEBUFFER,
                                .dwFlags = windows.PFD_FLAGS.initFlags(.{ .DRAW_TO_WINDOW = 1, .SUPPORT_OPENGL = 1, .DOUBLEBUFFER = 1 }),
                                .iPixelType = windows.PFD_TYPE_RGBA,
                                .cColorBits = 32,
                                .cRedBits = 0,
                                .cRedShift = 0,
                                .cGreenBits = 0,
                                .cGreenShift = 0,
                                .cBlueBits = 0,
                                .cBlueShift = 0,
                                // .cAlphaBits = 0,
                                .cAlphaBits = 8,
                                .cAlphaShift = 0,
                                .cAccumBits = 0,
                                .cAccumRedBits = 0,
                                .cAccumGreenBits = 0,
                                .cAccumBlueBits = 0,
                                .cAccumAlphaBits = 0,
                                .cDepthBits = 24,
                                .cStencilBits = 8,
                                .cAuxBuffers = 0,
                                .iLayerType = windows.PFD_MAIN_PLANE,
                                .bReserved = 0,
                                .dwLayerMask = 0,
                                .dwVisibleMask = 0,
                                .dwDamageMask = 0,
                            };

                            const dummy_pixel_format = windows.ChoosePixelFormat(dummy_dc, &pfd);
                            _ = windows.SetPixelFormat(dummy_dc, dummy_pixel_format, &pfd);

                            const dummy_gl_context = windows.wglCreateContext(dummy_dc) orelse @panic("Couldn't create dummy OpenGL context");
                            _ = windows.wglMakeCurrent(dummy_dc, dummy_gl_context);

                            const wglChoosePixelFormatARB: *const fn (
                                hdc: windows.HDC,
                                piAttribIList: ?[*:0]const c_int,
                                pfAttribFList: ?[*:0]const f32,
                                nMaxFormats: c_uint,
                                piFormats: [*]c_int,
                                nNumFormats: *c_uint,
                            ) callconv(std.os.windows.WINAPI) windows.BOOL =
                                @ptrCast(windows.wglGetProcAddress("wglChoosePixelFormatARB") orelse return error.InvalidOpenGL);

                            const wglCreateContextAttribsARB: *const fn (
                                hDC: windows.HDC,
                                hshareContext: ?windows.HGLRC,
                                attribList: ?[*:0]const c_int,
                            ) callconv(std.os.windows.WINAPI) ?windows.HGLRC =
                                @ptrCast(windows.wglGetProcAddress("wglCreateContextAttribsARB") orelse return error.InvalidOpenGL);
                            _ = windows.wglMakeCurrent(dummy_dc, null);
                            _ = windows.wglDeleteContext(dummy_gl_context);
                            _ = windows.ReleaseDC(dummy_window, dummy_dc);
                            _ = windows.DestroyWindow(dummy_window);

                            // Real DC
                            const hDC = windows.GetDC(handle) orelse @panic("couldn't get DC!");
                            defer _ = windows.ReleaseDC(handle, hDC);
                            const pf_attributes = [_:0]c_int{
                                WGL_DRAW_TO_WINDOW_ARB, gl.GL_TRUE,
                                WGL_SUPPORT_OPENGL_ARB, gl.GL_TRUE,
                                WGL_DOUBLE_BUFFER_ARB,  gl.GL_TRUE,
                                WGL_ACCELERATION_ARB,   WGL_FULL_ACCELERATION_ARB,
                                WGL_PIXEL_TYPE_ARB,     WGL_TYPE_RGBA_ARB,
                                WGL_COLOR_BITS_ARB,     32,
                                WGL_DEPTH_BITS_ARB,     24,
                                WGL_STENCIL_BITS_ARB,   8,
                                0, // End
                            };

                            var pixelFormat: c_int = undefined;
                            var numFormats: c_uint = undefined;

                            if (wglChoosePixelFormatARB(hDC, &pf_attributes, null, 1, @as([*]c_int, @ptrCast(&pixelFormat)), &numFormats) == 0)
                                return error.InvalidOpenGL;
                            if (numFormats == 0) // AMD driver may return numFormats > nMaxFormats, see issue #14
                                return error.InvalidOpenGL;

                            var pfd_rel: windows.PIXELFORMATDESCRIPTOR = undefined;
                            _ = windows.DescribePixelFormat(hDC, pixelFormat, @sizeOf(windows.PIXELFORMATDESCRIPTOR), &pfd_rel);
                            if (windows.SetPixelFormat(hDC, pixelFormat, &pfd_rel) == 0) {
                                @panic("Failed to set the OpenGL pixel format.");
                            }
                            // if (dummy_pixel_format != pixelFormat)
                            //     @panic("This case is not implemented yet: Recreation of the window is required here!");

                            const ctx_attributes = [_:0]c_int{
                                WGL_CONTEXT_MAJOR_VERSION_ARB, requested_gl.major,
                                WGL_CONTEXT_MINOR_VERSION_ARB, requested_gl.minor,
                                WGL_CONTEXT_FLAGS_ARB,         WGL_CONTEXT_DEBUG_BIT_ARB,
                                WGL_CONTEXT_PROFILE_MASK_ARB,  if (requested_gl.core) WGL_CONTEXT_CORE_PROFILE_BIT_ARB else WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB,
                                0,
                            };

                            const gl_context = wglCreateContextAttribsARB(
                                hDC,
                                null,
                                &ctx_attributes,
                            ) orelse return error.InvalidOpenGL;
                            errdefer _ = windows.wglDeleteContext(gl_context);

                            if (windows.wglMakeCurrent(hDC, gl_context) == 0)
                                return error.InvalidOpenGL;

                            break :blk Backend{ .opengl = gl_context };
                        } else {
                            @panic("OpenGL support not enabled");
                        }
                    },
                    else => .none,
                };
            }

            pub fn deinit(self: *Window) void {
                switch (self.backend) {
                    .none => {},
                    .software => |*render_context| {
                        render_context.bitmap.destroy();
                        _ = windows.DeleteDC(render_context.memory_dc);
                    },
                    .opengl => |gl_context| {
                        if (Parent.settings.backends_enabled.opengl) {
                            const hDC = windows.GetDC(self.handle) orelse @panic("couldn't get DC!");
                            defer _ = windows.ReleaseDC(self.handle, hDC);

                            _ = windows.wglMakeCurrent(hDC, gl_context);
                            _ = windows.wglDeleteContext(gl_context);
                        } else {
                            unreachable;
                        }
                    },
                }

                if (self.handle) |handle| {
                    _ = windows.SetWindowLongPtrW(handle, @enumFromInt(0), 0);
                    _ = windows.DestroyWindow(handle);
                }
                var platform = @as(*Self, @ptrCast(self.parent.platform));
                platform.parent.allocator.destroy(self);
            }

            pub fn configure(self: *Window, options: zwl.WindowOptions) !void {
                _ = self;
                _ = options;
                return error.Unimplemented;
            }

            pub fn getSize(self: *Window) [2]u16 {
                return [2]u16{ self.width, self.height };
            }

            pub fn present(self: *Window) !void {
                switch (self.backend) {
                    .none => {},
                    .software => return error.InvalidRenderBackend,
                    .opengl => {
                        if (self.handle) |handle| {
                            const hDC = windows.GetDC(handle) orelse @panic("couldn't get DC!");
                            defer _ = windows.ReleaseDC(handle, hDC);

                            _ = windows.SwapBuffers(hDC);

                            _ = windows.InvalidateRect(
                                handle,
                                null,
                                0, // We paint over *everything*
                            );
                        }
                    },
                }
            }

            pub fn mapPixels(self: *Window) !zwl.PixelBuffer {
                switch (self.backend) {
                    .software => |render_ctx| {
                        // var platform = @ptrCast(*Self, self.parent.platform);

                        return zwl.PixelBuffer{
                            .data = render_ctx.bitmap.pixels,
                            .width = render_ctx.bitmap.width,
                            .height = render_ctx.bitmap.height,
                        };
                    },
                    else => return error.InvalidRenderBackend,
                }
            }

            pub fn submitPixels(self: *Window, updates: []const zwl.UpdateArea) !void {
                _ = updates;
                if (self.backend != .software)
                    return error.InvalidRenderBackend;
                if (self.handle) |handle| {
                    _ = windows.InvalidateRect(
                        handle,
                        null,
                        windows.FALSE, // We paint over *everything*
                    );
                }
            }

            const RenderContext = struct {
                const Bitmap = struct {
                    handle: windows.HBITMAP,
                    pixels: [*]u32,
                    width: u16,
                    height: u16,

                    fn destroy(self: *@This()) void {
                        // _ = windows.DeleteObject(self.handle.toGdiObject()); //TODO ???
                        self.* = undefined;
                    }
                };

                memory_dc: windows.HDC,
                bitmap: Bitmap,

                fn createBitmap(self: @This(), width: u16, height: u16) !Bitmap {
                    var bmi = std.mem.zeroes(windows.BITMAPINFO);
                    bmi.bmiHeader.biSize = @sizeOf(windows.BITMAPINFOHEADER);
                    bmi.bmiHeader.biWidth = width;
                    bmi.bmiHeader.biHeight = -@as(i32, height);
                    bmi.bmiHeader.biPlanes = 1;
                    bmi.bmiHeader.biBitCount = 32;
                    bmi.bmiHeader.biCompression = windows.BI_RGB;

                    var bmp = Bitmap{
                        .width = width,
                        .height = height,
                        .handle = undefined,
                        .pixels = undefined,
                    };

                    bmp.handle = windows.CreateDIBSection(
                        self.memory_dc,
                        &bmi,
                        windows.DIB_RGB_COLORS,
                        @ptrCast(&bmp.pixels),
                        null,
                        0,
                    ) orelse return error.CreateBitmapError;

                    return bmp;
                }
            };
        };
    };
}
