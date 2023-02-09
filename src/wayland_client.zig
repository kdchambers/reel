// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;
const wlr = wayland.client.zwlr;

const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");

const XCursor = struct {
    const hidden = "hidden";
    const left_ptr = "left_ptr";
    const text = "text";
    const xterm = "xterm";
    const hand2 = "hand2";
    const top_left_corner = "top_left_corner";
    const top_right_corner = "top_right_corner";
    const bottom_left_corner = "bottom_left_corner";
    const bottom_right_corner = "bottom_right_corner";
    const left_side = "left_side";
    const right_side = "right_side";
    const top_side = "top_side";
    const bottom_side = "bottom_side";
};

/// Wayland uses linux' input-event-codes for keys and buttons. When a mouse button is
/// clicked one of these will be sent with the event.
/// https://wayland-book.com/seat/pointer.html
/// https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h
pub const MouseButton = enum(c_int) {
    left = 0x110,
    right = 0x111,
    middle = 0x112,
    _,
};

pub const ButtonClicked = enum(u16) {
    none,
    right,
    middle,
    left,
};

//
// Public Variables
//

pub var display: *wl.Display = undefined;
pub var surface: *wl.Surface = undefined;

pub var previous_mouse_coordinates: geometry.Coordinates2D(f64) = undefined;
pub var mouse_coordinates: geometry.Coordinates2D(f64) = undefined;

pub var screen_dimensions: geometry.Dimensions2D(u16) = undefined;
pub var screen_scale: geometry.ScaleFactor2D(f64) = undefined;

pub var button_clicked: ButtonClicked = .none;
pub var button_state: wl.Pointer.ButtonState = undefined;
pub var is_mouse_moved: bool = false;

pub var framebuffer_resized: bool = true;
pub var is_mouse_in_screen: bool = true;
pub var is_shutdown_requested: bool = false;
pub var draw_window_decorations_requested: bool = false;
pub var frame_start_ns: i128 = undefined;
pub var is_fullscreen: bool = true;
pub var is_draw_requested: bool = false;

pub var pending_swapchain_images_count: u32 = 2;
pub var frame_index: u32 = 0;

//
// Internal Variables
//

var registry: *wl.Registry = undefined;
var compositor: *wl.Compositor = undefined;
var xdg_wm_base: *xdg.WmBase = undefined;
var seat: *wl.Seat = undefined;
var pointer: *wl.Pointer = undefined;
var frame_callback: *wl.Callback = undefined;
var xdg_toplevel: *xdg.Toplevel = undefined;
var xdg_surface: *xdg.Surface = undefined;
pub var screencopy_manager_opt: ?*wlr.ScreencopyManagerV1 = null;
pub var output_opt: ?*wl.Output = null;

var wayland_fd: i32 = undefined;

var cursor_theme: *wl.CursorTheme = undefined;
var cursor: *wl.Cursor = undefined;
var cursor_surface: *wl.Surface = undefined;
var xcursor: [:0]const u8 = undefined;
pub var shared_memory: *wl.Shm = undefined;

pub const OnFrameTickCallbackFn = fn (frame_index: u32, data: *void) void;

pub const OnFrameTickCallbackEntry = struct {
    callback: *const OnFrameTickCallbackFn,
    data: *void,
};

var frame_tick_callback_buffer: [2]OnFrameTickCallbackEntry = undefined;
var frame_tick_callback_count: u32 = 0;

//
// Public Interface
//

pub fn shutdown() void {
    is_shutdown_requested = true;
}

pub fn addFrameTickCallback(entry: OnFrameTickCallbackEntry) !u32 {
    if (frame_tick_callback_count == frame_tick_callback_buffer.len)
        return error.BufferFull;
    const index_handle = frame_tick_callback_count;
    frame_tick_callback_buffer[frame_tick_callback_count] = entry;
    frame_tick_callback_count += 1;
    return index_handle;
}

pub fn removeFrameTickCallback(index: u32) void {
    std.debug.assert(index < frame_tick_callback_count);
    frame_tick_callback_buffer[index] = frame_tick_callback_buffer[frame_tick_callback_count - 1];
    frame_tick_callback_count -= 1;
}

pub fn init(app_name: [*:0]const u8) !void {
    display = try wl.Display.connect(null);
    registry = try display.getRegistry();

    registry.setListener(*const void, registryListener, &{});

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    xdg_wm_base.setListener(*const void, xdgWmBaseListener, &{});

    surface = try compositor.createSurface();

    xdg_surface = try xdg_wm_base.getXdgSurface(surface);
    xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, surface);

    xdg_toplevel = try xdg_surface.getToplevel();
    xdg_toplevel.setListener(*bool, xdgToplevelListener, &is_shutdown_requested);

    frame_callback = try surface.frame();
    frame_callback.setListener(*const void, frameListener, &{});

    shared_memory.setListener(*const void, shmListener, &{});

    xdg_toplevel.setTitle(app_name);
    surface.commit();

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    //
    // Load cursor theme
    //

    cursor_surface = try compositor.createSurface();

    const cursor_size = 24;
    cursor_theme = try wl.CursorTheme.load(null, cursor_size, shared_memory);
    cursor = cursor_theme.getCursor(XCursor.left_ptr).?;
    xcursor = XCursor.left_ptr;

    wayland_fd = display.getFd();

    std.log.info("wayland_client: init done", .{});
}

pub fn deinit() void {
    // TODO: Implement
}

pub fn pollEvents() bool {
    while (!display.prepareRead()) {
        //
        // Client event queue should be empty before calling `prepareRead`
        // As a result this shouldn't happen but is just a safegaurd
        //
        _ = display.dispatchPending();
    }

    //
    // Flush Display write buffer -> Compositor
    //
    _ = display.flush();

    const timeout_milliseconds = 4;
    var pollfd = linux.pollfd{
        .fd = wayland_fd,
        .events = linux.POLL.IN,
        .revents = 0,
    };
    const poll_code = linux.poll(@ptrCast([*]linux.pollfd, &pollfd), 1, timeout_milliseconds);

    if (poll_code == 0) {
        // if (builtin.mode == .Debug)
        //     std.log.warn("wayland_client: Input poll timed out", .{});

        display.cancelRead();
        return true;
    }

    const input_available = (pollfd.revents & linux.POLL.IN) != 0;
    if (poll_code > 0 and input_available) {
        const errno = display.readEvents();
        if (errno != .SUCCESS)
            std.log.warn("wayland_client: failed reading events. Errno: {}", .{errno});
    } else {
        std.log.info("Cancel read", .{});
        display.cancelRead();
    }

    _ = display.dispatchPending();

    return false;
}

pub fn mouseCoordinatesNDCR() geometry.Coordinates2D(f64) {
    return .{
        .x = -1.0 + (mouse_coordinates.x * screen_scale.horizontal),
        .y = -1.0 + (mouse_coordinates.y * screen_scale.vertical),
    };
}

//
// Private Interface
//

fn xdgWmBaseListener(xdg_wm_base_ref: *xdg.WmBase, event: xdg.WmBase.Event, _: *const void) void {
    switch (event) {
        .ping => |ping| {
            std.log.info("wayland_client: xdg_wmbase ping", .{});
            xdg_wm_base_ref.pong(ping.serial);
        },
    }
}

fn xdgSurfaceListener(xdg_surface_ref: *xdg.Surface, event: xdg.Surface.Event, surface_ref: *wl.Surface) void {
    switch (event) {
        .configure => |configure| {
            std.log.info("wayland_client: xdg_surface configure", .{});
            xdg_surface_ref.ackConfigure(configure.serial);
            surface_ref.commit();
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, close_requested: *bool) void {
    switch (event) {
        .configure => |configure| {
            std.log.info("wayland_client: xdg_toplevel configure", .{});
            if (configure.width > 0 and configure.width != screen_dimensions.width) {
                framebuffer_resized = true;
                screen_dimensions.width = @intCast(u16, configure.width);
                screen_scale.horizontal = 2.0 / @intToFloat(f64, screen_dimensions.width);
            }
            if (configure.height > 0 and configure.height != screen_dimensions.height) {
                framebuffer_resized = true;
                screen_dimensions.height = @intCast(u16, configure.height);
                screen_scale.vertical = 2.0 / @intToFloat(f64, screen_dimensions.height);
            }

            const state_list = configure.states.slice(xdg.Toplevel.State);
            is_fullscreen = false;
            for (state_list) |state| {
                if (state == .fullscreen) {
                    is_draw_requested = true;
                    //
                    // TODO: This is kind of a hack but we need to force a redraw
                    //       when the screen is made fullscreen
                    //
                    is_fullscreen = true;
                }
            }
            frame_callback.destroy();
            frame_callback = surface.frame() catch |err| {
                std.log.err("Failed to create new wayland frame -> {}", .{err});
                return;
            };
            frame_callback.setListener(*const void, frameListener, &{});
        },
        .close => close_requested.* = true,
    }
}

fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, _: *const void) void {
    switch (event) {
        .done => {
            callback.destroy();
            frame_callback = surface.frame() catch |err| {
                std.log.err("Failed to create new wayland frame -> {}", .{err});
                std.debug.assert(false);
                return;
            };
            frame_callback.setListener(*const void, frameListener, &{});

            var i: usize = 0;
            while (i < frame_tick_callback_count) : (i += 1) {
                const entry_ptr = frame_tick_callback_buffer[i];
                entry_ptr.callback(frame_index, entry_ptr.data);
            }
            frame_index += 1;
            pending_swapchain_images_count += 1;
        },
    }
}

fn shmListener(shm: *wl.Shm, event: wl.Shm.Event, _: *const void) void {
    _ = shm;
    switch (event) {
        .format => |format| {
            std.log.info("wayland_client: Shm format: {}", .{format});
        },
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, _: *const void) void {
    switch (event) {
        .enter => |enter| {
            is_mouse_in_screen = true;
            mouse_coordinates.x = enter.surface_x.toDouble();
            mouse_coordinates.y = enter.surface_y.toDouble();

            //
            // When mouse enters application surface, update the cursor image
            //
            const image = cursor.images[0];
            const image_buffer = image.getBuffer() catch return;
            cursor_surface.attach(image_buffer, 0, 0);
            pointer.setCursor(enter.serial, cursor_surface, @intCast(i32, image.hotspot_x), @intCast(i32, image.hotspot_y));
            cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            cursor_surface.commit();
        },
        .leave => |leave| {
            _ = leave;
            is_mouse_in_screen = false;
        },
        .motion => |motion| {
            if (!is_mouse_in_screen)
                return;

            const motion_mouse_x = motion.surface_x.toDouble();
            const motion_mouse_y = motion.surface_y.toDouble();

            mouse_coordinates.x = motion_mouse_x;
            mouse_coordinates.y = motion_mouse_y;

            is_mouse_moved = true;
        },
        .button => |button| {
            if (!is_mouse_in_screen) {
                return;
            }

            if (mouse_coordinates.x < 0 or mouse_coordinates.y < 0)
                return;

            const mouse_button = @intToEnum(MouseButton, button.button);
            button_clicked = .none;

            if (mouse_button == .left)
                button_clicked = .left;

            if (mouse_button == .right)
                button_clicked = .right;

            if (mouse_button == .middle)
                button_clicked = .middle;

            button_state = button.state;

            std.log.info("Button mouse coordinates: {d}, {d}", .{
                mouse_coordinates.x,
                mouse_coordinates.y,
            });

            {
                const mouse_x = @floatToInt(u16, mouse_coordinates.x);
                const mouse_y = @floatToInt(u16, mouse_coordinates.y);

                std.log.info("Mouse coords: {d}, {d}. Screen {d}, {d}", .{
                    mouse_x,
                    mouse_y,
                    screen_dimensions.width,
                    screen_dimensions.height,
                });

                if (mouse_x > screen_dimensions.width or mouse_y > screen_dimensions.height)
                    return;

                if (mouse_x < 3 and mouse_y < 3) {
                    xdg_toplevel.resize(seat, button.serial, .bottom_left);
                }

                const edge_threshold = 3;
                const max_width = screen_dimensions.width - edge_threshold;
                const max_height = screen_dimensions.height - edge_threshold;

                if (mouse_x < edge_threshold and mouse_y > max_height) {
                    xdg_toplevel.resize(seat, button.serial, .top_left);
                    return;
                }

                if (mouse_x > max_width and mouse_y < edge_threshold) {
                    xdg_toplevel.resize(seat, button.serial, .bottom_right);
                    return;
                }

                if (mouse_x > max_width and mouse_y > max_height) {
                    xdg_toplevel.resize(seat, button.serial, .bottom_right);
                    return;
                }

                if (mouse_x < edge_threshold) {
                    xdg_toplevel.resize(seat, button.serial, .left);
                    return;
                }

                if (mouse_x > max_width) {
                    xdg_toplevel.resize(seat, button.serial, .right);
                    return;
                }

                if (mouse_y <= edge_threshold) {
                    xdg_toplevel.resize(seat, button.serial, .top);
                    return;
                }

                if (mouse_y == max_height) {
                    xdg_toplevel.resize(seat, button.serial, .bottom);
                    return;
                }
            }

            if (@floatToInt(u16, mouse_coordinates.y) > screen_dimensions.height)
                return;

            if (@floatToInt(u16, mouse_coordinates.x) > screen_dimensions.width)
                return;

            // if (draw_window_decorations_requested and mouse_button == .left) {
            //     // Start interactive window move if mouse coordinates are in window decorations bounds
            //     if (@floatToInt(u32, mouse_coordinates.y) <= window_decorations.height_pixels) {
            //         xdg_toplevel.move(seat, button.serial);
            //     }
            //     const end_x = exit_button_extent.x + exit_button_extent.width;
            //     const end_y = exit_button_extent.y + exit_button_extent.height;
            //     const mouse_x = @floatToInt(u16, mouse_coordinates.x);
            //     const mouse_y = screen_dimensions.height - @floatToInt(u16, mouse_coordinates.y);
            //     const is_within_bounds = (mouse_x >= exit_button_extent.x and mouse_y >= exit_button_extent.y and mouse_x <= end_x and mouse_y <= end_y);
            //     if (is_within_bounds) {
            //         std.log.info("Close button clicked. Shutdown requested.", .{});
            //         self.is_shutdown_requested = true;
            //     }
            // }
        },
        .axis => |axis| {
            std.log.info("Mouse: axis {} {}", .{ axis.axis, axis.value.toDouble() });
        },
        .frame => |frame| {
            _ = frame;
        },
        .axis_source => |axis_source| {
            std.log.info("Mouse: axis_source {}", .{axis_source.axis_source});
        },
        .axis_stop => |axis_stop| {
            _ = axis_stop;
            std.log.info("Mouse: axis_stop", .{});
        },
        .axis_discrete => |axis_discrete| {
            _ = axis_discrete;
            std.log.info("Mouse: axis_discrete", .{});
        },
    }
}

fn registryListener(registry_ref: *wl.Registry, event: wl.Registry.Event, _: *const void) void {
    switch (event) {
        .global => |global| {
            std.log.info("Wayland: {s}", .{global.interface});
            if (std.cstr.cmp(global.interface, wl.Compositor.getInterface().name) == 0) {
                compositor = registry_ref.bind(global.name, wl.Compositor, 4) catch return;
            } else if (std.cstr.cmp(global.interface, xdg.WmBase.getInterface().name) == 0) {
                xdg_wm_base = registry_ref.bind(global.name, xdg.WmBase, 3) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Seat.getInterface().name) == 0) {
                seat = registry_ref.bind(global.name, wl.Seat, 5) catch return;
                pointer = seat.getPointer() catch return;
                pointer.setListener(*const void, pointerListener, &{});
            } else if (std.cstr.cmp(global.interface, wl.Shm.getInterface().name) == 0) {
                shared_memory = registry_ref.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.cstr.cmp(global.interface, wlr.ScreencopyManagerV1.getInterface().name) == 0) {
                screencopy_manager_opt = registry_ref.bind(global.name, wlr.ScreencopyManagerV1, 3) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                output_opt = registry_ref.bind(global.name, wl.Output, 2) catch return;
            } else if (std.cstr.cmp(global.interface, zxdg.DecorationManagerV1.getInterface().name) == 0) {
                //
                // TODO: Negociate with compositor how the window decorations will be drawn
                //
                draw_window_decorations_requested = false;
            }
        },
        .global_remove => {},
    }
}
