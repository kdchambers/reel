// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wlr = wayland.client.zwlr;
const screencapture = @import("../../screencapture.zig");
const wayland_core = @import("../../wayland_core.zig");
const geometry = @import("../../geometry.zig");

const wayland_client = @import("../../frontends/wayland.zig");

const WaylandBufferAllocator = @import("BufferAllocator.zig");
var buffer_allocator: WaylandBufferAllocator = undefined;

const StreamInterface = screencapture.StreamInterface;

const PixelType = screencapture.PixelType;

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

pub var stream_state: screencapture.State = .uninitialized;

var display_info: DisplayInfo = undefined;

const buffer_entry_count = 4;
var entry_buffer: [buffer_entry_count]Entry = undefined;

var screencapture_frame: *wlr.ScreencopyFrameV1 = undefined;

var onOpenSuccessCallback: *const screencapture.OpenOnSuccessFn = undefined;
var onOpenErrorCallback: *const screencapture.OpenOnErrorFn = undefined;

var frameReadyCallback: *const screencapture.OnFrameReadyFn = undefined;

var frametick_callback_index: u32 = 0;

var frame_callback: *wlr.ScreencopyManagerV1 = undefined;
pub var screencopy_manager_opt: ?*wlr.ScreencopyManagerV1 = null;

// TODO:
var screenshot_output_path: []const u8 = undefined;

pub fn createInterface(
    onFrameReadyCallback: *const screencapture.OnFrameReadyFn,
) screencapture.Interface {
    frameReadyCallback = onFrameReadyCallback;
    return .{
        .openStream = openStream,
        .init = init,
        .deinit = deinit,
        .screenshot = screenshot,
    };
}

pub fn detectSupport() bool {
    return (wayland_core.screencopy_manager_opt != null and wayland_core.outputs.len > 0);
}

var onInitSuccessCallback: *const screencapture.InitOnSuccessFn = undefined;
var onInitErrorCallback: *const screencapture.InitOnErrorFn = undefined;

pub const InitErrorSet = error{
    NoWaylandDisplay,
    NoWaylandOutput,
    CaptureOutputFail,
    AllocateWaylandBuffersFail,
    WaylandScreencaptureFail,
    OutOfMemory,
};

pub fn deinit() void {}

pub fn init(
    on_success_cb: *const screencapture.InitOnSuccessFn,
    on_error_cb: *const screencapture.InitOnErrorFn,
) void {
    onInitSuccessCallback = on_success_cb;
    onInitErrorCallback = on_error_cb;

    std.debug.assert(wayland_core.outputs.buffer.len > 0);

    const display_output = wayland_core.outputs.buffer[0].handle;
    const screencopy_manager = wayland_core.screencopy_manager_opt orelse return onInitErrorCallback(error.NoWaylandOutput);

    screencapture_frame = screencopy_manager.captureOutput(1, display_output) catch {
        return onInitErrorCallback(error.CaptureOutputFail);
    };

    screencapture_frame.setListener(
        *const void,
        initFrameCaptureCallback,
        &{},
    );
}

fn streamPause(self: StreamInterface, is_paused: bool) void {
    _ = self;
    _ = is_paused;
}

fn streamState(self: StreamInterface) StreamInterface.State {
    _ = self;
    return .running;
}

fn streamClose(self: StreamInterface) void {
    _ = self;
}

pub fn openStream(
    on_success_cb: *const screencapture.OpenStreamOnSuccessFn,
    on_error_cb: *const screencapture.OpenStreamOnErrorFn,
) void {
    std.log.info("Opening wlroots screencapture backend", .{});
    _ = on_error_cb;

    wayland_client.addOnFrameCallback(&onFrameTick);

    on_success_cb(.{
        .index = 0,
        .pause = streamPause,
        .close = streamClose,
        .state = streamState,
    });
}

pub fn state() screencapture.State {
    return stream_state;
}

fn onFrameTick(frame_index: u32) void {
    if (wayland_core.screencopy_manager_opt) |screencopy_manager| {
        const display_output = wayland_core.outputs.buffer[0].handle;
        var i: usize = 0;
        while (i < buffer_entry_count) : (i += 1) {
            var entry_ptr = &entry_buffer[i];
            if (entry_ptr.frame_index == std.math.maxInt(u32)) {
                entry_ptr.frame_index = frame_index;
                const next_frame = screencopy_manager.captureOutput(1, display_output) catch {
                    std.log.err("screencapture: Failed to capture next frame", .{});
                    stream_state = .fatal_error;
                    return;
                };
                next_frame.setListener(
                    *Entry,
                    streamFrameCaptureCallback,
                    entry_ptr,
                );
                entry_ptr.captured_frame = next_frame;
                return;
            }
        }
    } else unreachable;
    //
    // TODO: Just overwrite the older frame and log a warning
    //
    std.log.err("screencapture internal buffer full", .{});
    stream_state = .fatal_error;
}

var screenshot_callback: *const screencapture.OnScreenshotReadyFn = undefined;
var screenshot_requested: bool = false;

pub fn screenshot(callback: *const screencapture.OnScreenshotReadyFn) void {
    screenshot_callback = callback;
    screenshot_requested = true;
}

fn streamFrameCaptureCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, entry: *Entry) void {
    switch (event) {
        .buffer_done => frame.copy(entry.buffer.buffer),
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

            if (screenshot_requested) {
                screenshot_requested = false;
                screenshot_callback(display_info.width, display_info.height, unconverted_pixels);
            }
        },
        .failed => {
            std.log.err("screencapture: Frame capture failed", .{});
            frame.destroy();
            stream_state = .fatal_error;
        },
        else => {},
    }
}

fn initFrameCaptureCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, _: *const void) void {
    switch (event) {
        .buffer => |buffer| {
            display_info.width = buffer.width;
            display_info.height = buffer.height;
            display_info.stride = buffer.stride;
            display_info.format = buffer.format;
            const bytes_per_frame = buffer.stride * buffer.height;
            buffer_allocator = WaylandBufferAllocator.init(
                bytes_per_frame * buffer_entry_count,
                wayland_core.shared_memory,
            ) catch return onInitErrorCallback(error.AllocateWaylandBuffersFail);

            for (&entry_buffer) |*screen_buffer| {
                screen_buffer.buffer = buffer_allocator.create(
                    buffer.width,
                    buffer.height,
                    buffer.stride,
                    buffer.format,
                ) catch return onInitErrorCallback(error.AllocateWaylandBuffersFail);
                screen_buffer.frame_index = invalid_frame;
            }
        },
        .buffer_done => frame.copy(entry_buffer[0].buffer.buffer),
        .ready => onInitSuccessCallback(),
        .failed => {
            frame.destroy();
            stream_state = .fatal_error;
            onInitErrorCallback(error.WaylandScreencaptureFail);
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
            entry_buffer[0].buffer = buffer_allocator.create(
                buffer.width,
                buffer.height,
                buffer.stride,
                buffer.format,
            ) catch return onOpenErrorCallback();
        },
        .buffer_done => frame.copy(entry_buffer[0].buffer.buffer),
        .ready => {
            const buffer_memory = buffer_allocator.mappedMemoryForBuffer(&entry_buffer[0].buffer);
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
        },
        .failed => {
            std.log.err("screencast: Frame capture failed", .{});
            frame.destroy();
            stream_state = .fatal_error;
        },
        else => {},
    }
}
