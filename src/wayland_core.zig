// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const linux = std.os.linux;

const utils = @import("utils.zig");
const FixedBuffer = utils.FixedBuffer;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;

const build_options = @import("build_options");

const wlr = if (build_options.have_wlr_screencopy) wayland.client.zwlr else {};

const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");

pub var display: *wl.Display = undefined;
pub var screencopy_manager_opt: if (build_options.have_wlr_screencopy) ?*wlr.ScreencopyManagerV1 else void = if (build_options.have_wlr_screencopy) null else {};
pub var shared_memory: *wl.Shm = undefined;

pub var registry: *wl.Registry = undefined;
pub var compositor: *wl.Compositor = undefined;
pub var xdg_wm_base: *xdg.WmBase = undefined;

pub var wayland_fd: i32 = undefined;

pub var seat: *wl.Seat = undefined;
pub var pointer: *wl.Pointer = undefined;

pub var display_list: std.ArrayList([]const u8) = undefined;

pub const CaptureCallbackFn = fn () void;
pub var capture_callback: ?*const CaptureCallbackFn = null;

pub const OutputDisplay = struct {
    handle: *wl.Output,
    dimensions: geometry.Dimensions2D(i32) = .{ .width = 0, .height = 0 },
    refresh_rate: i32 = 0,
    index: u16,
    scale_factor: i32 = 0.0,
    name: []const u8 = undefined,
};

pub var outputs: FixedBuffer(OutputDisplay, 8) = .{};

pub var window_decorations_opt: ?*zxdg.DecorationManagerV1 = null;

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
    shared_memory.setListener(*const void, shmListener, &{});

    wayland_fd = display.getFd();

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    state = .initialized;

    std.log.info("wayland_client: init done", .{});
}

pub fn deinit() void {
    display_list.deinit();

    if (display.roundtrip() != .SUCCESS) assert(false);

    if (comptime build_options.have_wlr_screencopy) {
        if (screencopy_manager_opt) |*screencopy_manager| {
            screencopy_manager.*.destroy();
        }
    }

    if (window_decorations_opt) |*window_decorations| {
        window_decorations.*.destroy();
    }

    shared_memory.destroy();
    xdg_wm_base.destroy();

    pointer.destroy();
    seat.destroy();

    registry.destroy();
    _ = display.flush();

    //
    // Hack: On Gnome (Mutter) I'm getting a compositor crash when calling disconnect.
    //       I haven't been able to track down the cause but it seems there's a race condition
    //       at play. Strangely this doesn't happen on Ctrl-C.
    //
    std.time.sleep(std.time.ns_per_ms * 200);

    display.disconnect();

    state = .uninitialized;
}

pub fn sync() bool {
    if (display.roundtrip() != .SUCCESS)
        unreachable;

    // while (!display.prepareRead()) {
    //     //
    //     // Client event queue should be empty before calling `prepareRead`
    //     // As a result this shouldn't happen but is just a safegaurd
    //     //
    //     _ = display.dispatchPending();
    // }

    // //
    // // Flush Display write buffer -> Compositor
    // //
    // _ = display.flush();

    // const timeout_milliseconds = 1;
    // var pollfd = linux.pollfd{
    //     .fd = wayland_fd,
    //     .events = linux.POLL.IN,
    //     .revents = 0,
    // };
    // const poll_code = linux.poll(@ptrCast([*]linux.pollfd, &pollfd), 1, timeout_milliseconds);

    // if (poll_code == 0) {
    //     display.cancelRead();
    //     return true;
    // }

    // const input_available = (pollfd.revents & linux.POLL.IN) != 0;
    // if (poll_code > 0 and input_available) {
    //     const errno = display.readEvents();
    //     if (errno != .SUCCESS)
    //         std.log.warn("wayland_client: failed reading events. Errno: {}", .{errno});
    // } else {
    //     std.log.info("Cancel read", .{});
    //     display.cancelRead();
    // }

    // _ = display.dispatchPending();

    //
    // This is used by the wlroots screencapture backend to get CPU time at
    // ~60 frames per second. It will need to be made more sophisticated later on
    //
    if (capture_callback) |callback|
        callback();

    return false;
}

//
// Private Interface
//

fn xdgWmBaseListener(xdg_wm_base_ref: *xdg.WmBase, event: xdg.WmBase.Event, _: *const void) void {
    switch (event) {
        .ping => |ping| xdg_wm_base_ref.pong(ping.serial),
    }
}

fn shmListener(_: *wl.Shm, event: wl.Shm.Event, _: *const void) void {
    _ = event;
    // switch (event) {
    //     .format => |format| std.log.info("wayland_client: Shm format: {}", .{format}),
    // }
}

fn outputListener(output: *wl.Output, event: wl.Output.Event, index: *const u16) void {
    _ = output;
    switch (event) {
        .geometry => |data| {
            const duped_make_string = allocator_ref.dupe(u8, std.mem.span(data.make)) catch unreachable;
            display_list.append(duped_make_string) catch unreachable;
            outputs.buffer[index.*].name = duped_make_string;
        },
        .mode => |mode| {
            outputs.buffer[index.*].refresh_rate = mode.refresh;
            outputs.buffer[index.*].dimensions.width = mode.width;
            outputs.buffer[index.*].dimensions.height = mode.height;
            std.log.info("Refresh rate: {d}", .{mode.refresh});
        },
        .scale => |scale| {
            outputs.buffer[index.*].scale_factor = scale.factor;
        },
        .name => |name| std.log.info("Wayland output name: {s}", .{name.name}),
        .description => |data| std.log.info("Wayland output description: {s}", .{data.description}),
        .done => {},
    }
}

fn registryListener(registry_ref: *wl.Registry, event: wl.Registry.Event, _: *const void) void {
    switch (event) {
        .global => |global| {
            const orderZ = std.mem.orderZ;
            // std.log.info("Wayland interface: {s}", .{global.interface});
            if (orderZ(u8, global.interface, wl.Compositor.getInterface().name) == .eq) {
                compositor = registry_ref.bind(global.name, wl.Compositor, 4) catch return;
            } else if (orderZ(u8, global.interface, xdg.WmBase.getInterface().name) == .eq) {
                xdg_wm_base = registry_ref.bind(global.name, xdg.WmBase, 3) catch return;
            } else if (orderZ(u8, global.interface, wl.Seat.getInterface().name) == .eq) {
                seat = registry_ref.bind(global.name, wl.Seat, 5) catch return;
                pointer = seat.getPointer() catch return;
            } else if (orderZ(u8, global.interface, wl.Shm.getInterface().name) == .eq) {
                shared_memory = registry_ref.bind(global.name, wl.Shm, 1) catch return;
            } else if (comptime build_options.have_wlr_screencopy and orderZ(u8, global.interface, wlr.ScreencopyManagerV1.getInterface().name) == .eq) {
                screencopy_manager_opt = registry_ref.bind(global.name, wlr.ScreencopyManagerV1, 3) catch return;
            } else if (orderZ(u8, global.interface, wl.Output.getInterface().name) == .eq) {
                if (outputs.len < outputs.buffer.len) {
                    const output_ptr = registry_ref.bind(global.name, wl.Output, 2) catch return;
                    const output_index = @as(u16, @intCast(outputs.len));
                    outputs.append(.{
                        .handle = output_ptr,
                        .index = output_index,
                    }) catch unreachable;
                    output_ptr.setListener(*const u16, outputListener, &(outputs.buffer[outputs.len - 1].index));
                }
            } else if (orderZ(u8, global.interface, zxdg.DecorationManagerV1.getInterface().name) == .eq) {
                window_decorations_opt = registry_ref.bind(global.name, zxdg.DecorationManagerV1, 2) catch blk: {
                    std.log.warn("Failed to bind to zxdg.DecorationManagerV1", .{});
                    break :blk null;
                };
            }
        },
        .global_remove => {},
    }
}
