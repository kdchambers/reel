// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wlr = wayland.client.zwlr;
const screencast = @import("../../screencast.zig");
const wayland_client = @import("../../wayland_client.zig");
const geometry = @import("../../geometry.zig");

const WaylandBufferAllocator = @import("BufferAllocator.zig");

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
var buffer_allocator: WaylandBufferAllocator = undefined;

const buffer_entry_count = 4;
var entry_buffer: [buffer_entry_count]Entry = undefined;

var onOpenSuccessCallback: *const screencast.OpenOnSuccessFn = undefined;
var onOpenErrorCallback: *const screencast.OpenOnErrorFn = undefined;

var frameReadyCallback: *const screencast.OnFrameReadyFn = undefined;

var frametick_callback_index: u32 = 0;

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
    };
}

pub fn detectSupport() bool {
    return (wayland_client.screencopy_manager_opt != null and wayland_client.output_opt != null);
}

pub fn open(
    on_success_cb: *const screencast.OpenOnSuccessFn,
    on_error_cb: *const screencast.OpenOnErrorFn,
) InitErrorSet!void {
    std.log.info("Opening wlroots screencast backend", .{});

    std.debug.assert(stream_state == .uninitialized);

    onOpenSuccessCallback = on_success_cb;
    onOpenErrorCallback = on_error_cb;

    //
    // We need to know about the display (monitor) to complete initialization. This is done in the following
    // callback and we set state to `init_pending` meanwhile. Once the callback successfully completes, state
    // will be set to `.open` and `captureFrame` can be called on the current frame
    //
    if (wayland_client.screencopy_manager_opt) |screencopy_manager| {
        if (wayland_client.output_opt) |display_output| {
            const frame = try screencopy_manager.captureOutput(1, display_output);

            frame.setListener(
                *const void,
                finishedInitializationCallback,
                &{},
            );
            stream_state = .init_pending;
        }
    }
}

pub fn state() screencast.State {
    return stream_state;
}

fn onFrameTick(frame_index: u32, data: *void) void {
    _ = data;
    std.debug.assert(stream_state == .open);
    if (wayland_client.screencopy_manager_opt) |screencopy_manager| {
        if (wayland_client.output_opt) |display_output| {
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

pub fn pause() void {
    stream_state = .paused;
    wayland_client.removeFrameTickCallback(
        frametick_callback_index,
    );

    //
    // Throw away all currently captured frames as they'll
    // be too old to use again when unpaused
    //
    comptime var i: usize = 0;
    inline while (i < buffer_entry_count) : (i += 1) {
        entry_buffer[i].frame_index = invalid_frame;
    }
    std.log.info("screencast: paused", .{});
}

pub fn unpause() void {
    stream_state = .open;
    frametick_callback_index = wayland_client.addFrameTickCallback(.{
        .callback = &onFrameTick,
        .data = undefined,
    }) catch {
        stream_state = .fatal_error;
        std.log.err("Failed to setup frametick callback", .{});
        return;
    };
    std.log.info("screencast: resumed", .{});
}

pub fn close() void {
    if (stream_state == .open) {
        wayland_client.removeFrameTickCallback(
            frametick_callback_index,
        );
    }
    stream_state = .closed;
    std.log.info("screencast: closed", .{});
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
                wayland_client.shared_memory,
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

            frametick_callback_index = wayland_client.addFrameTickCallback(.{
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
