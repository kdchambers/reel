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
pub var screencopy_manager_opt: ?*wlr.ScreencopyManagerV1 = null;
pub var output_opt: ?*wl.Output = null;
pub var shared_memory: *wl.Shm = undefined;

//
// Internal Variables
//

var registry: *wl.Registry = undefined;
var compositor: *wl.Compositor = undefined;
var xdg_wm_base: *xdg.WmBase = undefined;

var wayland_fd: i32 = undefined;

var cursor_theme: *wl.CursorTheme = undefined;
var cursor: *wl.Cursor = undefined;
var cursor_surface: *wl.Surface = undefined;
var xcursor: [:0]const u8 = undefined;
var seat: *wl.Seat = undefined;
var pointer: *wl.Pointer = undefined;

// var display_buffer: [512]u8 = undefined;

pub var display_list: std.ArrayList([]const u8) = undefined;

//
// TODO: Get rid of this and bind the interface
//
pub var draw_window_decorations_requested: bool = false;

var state: enum {
    uninitialized,
    initialized,
} = .uninitialized;

var allocator_ref: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    allocator_ref = allocator;
    std.debug.assert(state == .uninitialized);

    display_list = try std.ArrayList([]const u8).initCapacity(allocator, 3);

    display = try wl.Display.connect(null);
    registry = try display.getRegistry();

    registry.setListener(*const void, registryListener, &{});

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    xdg_wm_base.setListener(*const void, xdgWmBaseListener, &{});

    wayland_fd = display.getFd();

    state = .initialized;

    std.log.info("wayland_client: init done", .{});
}

pub fn deinit() void {
    // TODO: Call whatever wayland deinit fns

    display = undefined;
    screencopy_manager_opt = null;
    output_opt = null;
    registry = undefined;
    compositor = undefined;
    xdg_wm_base = undefined;
    wayland_fd = -1;
    cursor_theme = undefined;
    cursor = undefined;
    cursor_surface = undefined;
    xcursor = undefined;
    shared_memory = undefined;
    seat = undefined;
    pointer = undefined;
    output_opt = null;

    display_list.deinit();

    state = .uninitialized;
}

pub fn sync() bool {
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

fn shmListener(shm: *wl.Shm, event: wl.Shm.Event, _: *const void) void {
    _ = shm;
    switch (event) {
        .format => |format| {
            std.log.info("wayland_client: Shm format: {}", .{format});
        },
    }
}

fn outputListener(output: *wl.Output, event: wl.Output.Event, _: *const void) void {
    _ = output;
    switch (event) {
        .geometry => |data| {
            // std.log.info("Output geometry: {s} :: {s}", .{
            //     data.make, data.model,
            // });
            const duped_make_string = allocator_ref.dupe(u8, std.mem.span(data.make)) catch return;
            display_list.append(duped_make_string) catch return;
        },
        .mode => |mode| {
            _ = mode;
            // std.log.info("Output mode: {d}x{d} refresh {d}", .{
            //     mode.width, mode.height, mode.refresh,
            // });
        },
        .scale => |scale| {
            _ = scale;
            // std.log.info("Output scale: {d}", .{scale.factor});
        },
        .name => |name| {
            _ = name;
            // std.log.info("Output name: {s}", .{ name.name });
        },
        .description => |data| {
            // std.log.info("Output description: {s}", .{ data.description });
            _ = data;
        },
        .done => {},
    }
}

fn registryListener(registry_ref: *wl.Registry, event: wl.Registry.Event, _: *const void) void {
    switch (event) {
        .global => |global| {
            // std.log.info("Wayland interface: {s}", .{global.interface});
            if (std.cstr.cmp(global.interface, wl.Compositor.getInterface().name) == 0) {
                compositor = registry_ref.bind(global.name, wl.Compositor, 4) catch return;
            } else if (std.cstr.cmp(global.interface, xdg.WmBase.getInterface().name) == 0) {
                xdg_wm_base = registry_ref.bind(global.name, xdg.WmBase, 3) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Seat.getInterface().name) == 0) {
                seat = registry_ref.bind(global.name, wl.Seat, 5) catch return;
                pointer = seat.getPointer() catch return;
            } else if (std.cstr.cmp(global.interface, wl.Shm.getInterface().name) == 0) {
                shared_memory = registry_ref.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.cstr.cmp(global.interface, wlr.ScreencopyManagerV1.getInterface().name) == 0) {
                screencopy_manager_opt = registry_ref.bind(global.name, wlr.ScreencopyManagerV1, 3) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                output_opt = registry_ref.bind(global.name, wl.Output, 2) catch return;
                output_opt.?.setListener(*const void, outputListener, &{});
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
