// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wlr = wayland.client.zwlr;
const screencast = @import("../../screencast.zig");
const wayland_core = @import("../../wayland_core.zig");
const geometry = @import("../../geometry.zig");

const WaylandBufferAllocator = @import("BufferAllocator.zig");

var screenshot_buffer: ?WaylandBufferAllocator.Buffer = null; 
var buffer_allocator: WaylandBufferAllocator = undefined;

const PixelType = screencast.PixelType;

pub const InitErrorSet = error{
    OutOfMemory,
};

const DisplayInfo = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: wl.Shm.Format,
};

const Entry = struct {
    buffer: WaylandBufferAllocator.Buffer,
    captured_frame: *wlr.ScreencopyFrameV1,
    frame_index: u32,
};

const invalid_frame = std.math.maxInt(u32);

pub var stream_state: screencast.State = .uninitialized;

var display_info: DisplayInfo = undefined;

const buffer_entry_count = 4;
var entry_buffer: [buffer_entry_count]Entry = undefined;

var screencapture_frame: *wlr.ScreencopyFrameV1 = undefined;

var onOpenSuccessCallback: *const screencast.OpenOnSuccessFn = undefined;
var onOpenErrorCallback: *const screencast.OpenOnErrorFn = undefined;

var frameReadyCallback: *const screencast.OnFrameReadyFn = undefined;

var frametick_callback_index: u32 = 0;

var frame_callback: *wlr.ScreencopyManagerV1 = undefined;
pub var screencopy_manager_opt: ?*wlr.ScreencopyManagerV1 = null;
pub var output_opt: ?*wl.Output = null;

pub fn createInterface(
    onFrameReadyCallback: *const screencast.OnFrameReadyFn,
) screencast.Interface {
    frameReadyCallback = onFrameReadyCallback;
    return .{
        .requestOpen = open,
        .state = state,
        .pause = pause,
        .unpause = unpause,
        .close = close,
        .screenshot = screenshot,
    };
}

pub fn detectSupport() bool {
    return (wayland_core.screencopy_manager_opt != null and wayland_core.output_opt != null);
}

pub fn open(
    on_success_cb: *const screencast.OpenOnSuccessFn,
    on_error_cb: *const screencast.OpenOnErrorFn,
) InitErrorSet!void {
    std.log.info("Opening wlroots screencast backend", .{});

    std.debug.assert(stream_state == .uninitialized);

    onOpenSuccessCallback = on_success_cb;
    onOpenErrorCallback = on_error_cb;

    const display_output = wayland_core.output_opt.?;
    const screencopy_manager = wayland_core.screencopy_manager_opt.?;

    screencapture_frame = screencopy_manager.captureOutput(1, display_output) catch {
        return onOpenErrorCallback();
    };

    screencapture_frame.setListener(
        *const void,
        screenshotFrameCaptureCallback,
        &{},
    );

    //
    // We need to know about the display (monitor) to complete initialization. This is done in the following
    // callback and we set state to `init_pending` meanwhile. Once the callback successfully completes, state
    // will be set to `.open` and `captureFrame` can be called on the current frame
    //
    // if (wayland_client.screencopy_manager_opt) |screencopy_manager| {
    //     if (wayland_client.output_opt) |display_output| {
    //         const frame = try screencopy_manager.captureOutput(1, display_output);

    //         frame.setListener(
    //             *const void,
    //             finishedInitializationCallback,
    //             &{},
    //         );
    //         stream_state = .init_pending;
    //     }
    // }
}

pub fn state() screencast.State {
    return stream_state;
}

// fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, _: *const void) void {
//     switch (event) {
//         .done => {
//             callback.destroy();
//             frame_callback = surface.frame() catch |err| {
//                 std.log.err("Failed to create new wayland frame -> {}", .{err});
//                 std.debug.assert(false);
//                 return;
//             };
//         },
//     }
// }

// fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, _: *const void) void {
//     switch (event) {
//         .done => {
//             callback.destroy();
//             frame_callback = surface.frame() catch |err| {
//                 std.log.err("Failed to create new wayland frame -> {}", .{err});
//                 std.debug.assert(false);
//                 return;
//             };
//             frame_callback.setListener(*const void, frameListener, &{});

//             var i: usize = 0;
//             while (i < frame_tick_callback_count) : (i += 1) {
//                 const entry_ptr = frame_tick_callback_buffer[i];
//                 entry_ptr.callback(frame_index, entry_ptr.data);
//             }
//             frame_index += 1;
//             pending_swapchain_images_count += 1;
//         },
//     }
// }

fn onFrameTick(frame_index: u32, data: *void) void {
    _ = data;
    std.debug.assert(stream_state == .open);
    if (wayland_core.screencopy_manager_opt) |screencopy_manager| {
        if (wayland_core.output_opt) |display_output| {
            var i: usize = 0;
            while (i < buffer_entry_count) : (i += 1) {
                var entry_ptr = &entry_buffer[i];
                if (entry_ptr.frame_index == std.math.maxInt(u32)) {
                    entry_ptr.frame_index = frame_index;
                    const next_frame = screencopy_manager.captureOutput(1, display_output) catch {
                        std.log.err("screencast: Failed to capture next frame", .{});
                        stream_state = .fatal_error;
                        return;
                    };
                    next_frame.setListener(
                        *Entry,
                        frameCaptureCallback,
                        entry_ptr,
                    );
                    entry_ptr.captured_frame = next_frame;
                    return;
                }
            }
        } else unreachable;
    } else unreachable;
    //
    // TODO: Just overwrite the older frame and log a warning
    //
    std.log.err("Screencast internal buffer full", .{});
    stream_state = .fatal_error;
}
pub fn pause() void {}

// pub fn pause() void {
//     stream_state = .paused;
//     wayland_core.removeFrameTickCallback(
//         frametick_callback_index,
//     );

//     //
//     // Throw away all currently captured frames as they'll
//     // be too old to use again when unpaused
//     //
//     comptime var i: usize = 0;
//     inline while (i < buffer_entry_count) : (i += 1) {
//         entry_buffer[i].frame_index = invalid_frame;
//     }
//     std.log.info("screencast: paused", .{});
// }
pub fn unpause() void {}

// pub fn unpause() void {
//     stream_state = .open;
//     frametick_callback_index = wayland_core.addFrameTickCallback(.{
//         .callback = &onFrameTick,
//         .data = undefined,
//     }) catch {
//         stream_state = .fatal_error;
//         std.log.err("Failed to setup frametick callback", .{});
//         return;
//     };
//     std.log.info("screencast: resumed", .{});
// }

pub fn close() void {}

// pub fn close() void {
//     if (stream_state == .open) {
//         wayland_core.removeFrameTickCallback(
//             frametick_callback_index,
//         );
//     }
//     stream_state = .closed;
//     std.log.info("screencast: closed", .{});
// }

var screenshot_output_path: []const u8 = undefined;

pub fn screenshot(file_path: []const u8) void {
    screenshot_output_path = file_path;

    const display_output = wayland_core.output_opt.?;
    const screencopy_manager = wayland_core.screencopy_manager_opt.?;
    screencapture_frame = screencopy_manager.captureOutput(1, display_output) catch return;
    screencapture_frame.setListener(
        *const void,
        screenshotFrameCaptureCallback,
        &{},
    );
}

fn finishedInitializationCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, _: *const void) void {
    switch (event) {
        .buffer => |buffer| {
            stream_state = .init_failed;

            defer frame.destroy();

            display_info.width = buffer.width;
            display_info.height = buffer.height;
            display_info.stride = buffer.stride;
            display_info.format = buffer.format;

            //
            // TODO: This should be part of pixel format validation and will be inside
            //       a switch prong for the specific type
            //
            std.debug.assert(display_info.stride == display_info.width * 4);
            switch (display_info.format) {
                .xbgr8888 => {},
                else => {
                    std.log.err("screencast: Pixel format conversion from {s} to rgba8888 not implemented", .{
                        @tagName(buffer.format),
                    });
                    return onOpenErrorCallback();
                },
            }

            std.log.info("screencast: Source pixel format: {s}", .{@tagName(buffer.format)});

            const bytes_per_frame = buffer.stride * buffer.height;
            const pool_size_bytes = bytes_per_frame * buffer_entry_count;

            buffer_allocator = WaylandBufferAllocator.init(
                pool_size_bytes,
                wayland_core.shared_memory,
            ) catch return onOpenErrorCallback();

            comptime var i: usize = 0;
            inline while (i < buffer_entry_count) : (i += 1) {
                var entry_ptr = &entry_buffer[i];
                entry_ptr.frame_index = invalid_frame;
                entry_ptr.buffer = buffer_allocator.create(
                    buffer.width,
                    buffer.height,
                    buffer.stride,
                    buffer.format,
                ) catch {
                    return onOpenErrorCallback();
                };
            }

            stream_state = .open;

            frametick_callback_index = wayland_core.addFrameTickCallback(.{
                .callback = &onFrameTick,
                .data = undefined,
            }) catch {
                std.log.err("Failed to setup frametick callback", .{});
                return onOpenErrorCallback();
            };

            onOpenSuccessCallback(buffer.width, buffer.height);
        },
        else => {},
    }
}

fn frameCaptureCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, entry: *Entry) void {
    if (stream_state != .open)
        return;

    switch (event) {
        .buffer_done => {
            frame.copy(entry.buffer.buffer);
        },
        .ready => {
            const buffer_memory = buffer_allocator.mappedMemoryForBuffer(&entry.buffer);
            const unconverted_pixels = @ptrCast([*]PixelType, buffer_memory.ptr);
            switch (display_info.format) {
                //
                // Nothing to do
                //
                .xbgr8888 => {},
                else => unreachable,
            }

            entry.frame_index = invalid_frame;
            frameReadyCallback(display_info.width, display_info.height, unconverted_pixels);
        },
        .failed => {
            std.log.err("screencast: Frame capture failed", .{});
            frame.destroy();
            stream_state = .fatal_error;
        },
        else => {},
    }
}

fn screenshotFrameCaptureCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, _: *const void) void {
    switch (event) {
        .buffer => |buffer| {
            display_info.width = buffer.width;
            display_info.height = buffer.height;
            display_info.stride = buffer.stride;
            display_info.format = buffer.format;
            const bytes_per_frame = buffer.stride * buffer.height;
            buffer_allocator = WaylandBufferAllocator.init(
                bytes_per_frame,
                wayland_core.shared_memory,
            ) catch return onOpenErrorCallback();
            screenshot_buffer = buffer_allocator.create(buffer.width, buffer.height, buffer.stride, buffer.format) catch return onOpenErrorCallback();
        },
        .buffer_done => frame.copy(screenshot_buffer.?.buffer),
        .ready => {
            const buffer_memory = buffer_allocator.mappedMemoryForBuffer(&screenshot_buffer.?);
            const unconverted_pixels = @ptrCast([*]PixelType, buffer_memory.ptr);
            // std.log.info("Format: {s}", .{@tagName(display_info.format)})
            _ = unconverted_pixels;
            switch (display_info.format) {
                //
                // Nothing to do
                //
                .xbgr8888 => {},
                else => unreachable,
            }
            std.log.info("\nScreenshot successful\n", .{});
            // frameReadyCallback(display_info.width, display_info.height, unconverted_pixels);
        },
        .failed => {
            std.log.err("screencast: Frame capture failed", .{});
            frame.destroy();
            stream_state = .fatal_error;
        },
        else => {},
    }
}