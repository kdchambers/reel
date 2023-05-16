// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
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

const max_stream_count = 8;
const frames_per_stream = 3;

const Stream = struct {
    frameReadyCallback: *const screencapture.OnFrameReadyFn,
    buffers: [frames_per_stream]WaylandBufferAllocator.Buffer, // u64
    captured_frames: [frames_per_stream]*wlr.ScreencopyFrameV1,
    frame_index_buffer: [frames_per_stream]u32,
    output_index: u32,
    width: u32,
    height: u32,
    stride: u32,
    stream_state: screencapture.StreamInterface.State,
    format: wl.Shm.Format,

    pub inline fn requiredMemory(self: *const @This()) usize {
        return self.height * self.stride * @as(usize, frames_per_stream);
    }
};

const invalid_frame = std.math.maxInt(u32);

var output_display_count: u32 = 0;
var initialized_stream_count: u32 = 0;

var stream_buffer: [max_stream_count]Stream = undefined;

var onOpenSuccessCallback: *const screencapture.OpenOnSuccessFn = undefined;
var onOpenErrorCallback: *const screencapture.OpenOnErrorFn = undefined;

var frametick_callback_index: u32 = 0;

var backend_state: screencapture.State = .uninitialized;

var frame_callback_registered: bool = false;

pub fn createInterface() screencapture.Interface {
    return .{
        .openStream = openStream,
        .init = init,
        .deinit = deinit,
        .screenshot = screenshot,
        .streamInfo = queryStreamInfo,
        .info = .{ .name = "wlroots", .query_streams = true },
    };
}

fn queryStreamInfo(allocator: std.mem.Allocator) []screencapture.StreamInfo {
    assert(wayland_core.outputs.len <= 32);
    var streams = allocator.alloc(screencapture.StreamInfo, wayland_core.outputs.len) catch unreachable;
    for (0..wayland_core.outputs.len) |i| {
        streams[i] = .{
            .name = wayland_core.outputs.buffer[i].name,
            .dimensions = .{
                .width = @intCast(u32, wayland_core.outputs.buffer[i].dimensions.width),
                .height = @intCast(u32, wayland_core.outputs.buffer[i].dimensions.height),
            },
            .pixel_format = null,
        };
        assert(streams[i].name.len <= 64);
    }
    return streams;
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

pub fn init(
    on_success_cb: *const screencapture.InitOnSuccessFn,
    on_error_cb: *const screencapture.InitOnErrorFn,
) void {
    onInitSuccessCallback = on_success_cb;
    onInitErrorCallback = on_error_cb;

    assert(backend_state == .uninitialized);
    assert(wayland_core.outputs.len > 0);

    const screencopy_manager = wayland_core.screencopy_manager_opt orelse
        return onInitErrorCallback(error.NoWaylandOutput);

    if (wayland_core.outputs.len > max_stream_count) {
        std.log.warn("Found {d} output displays. Max is {d}", .{
            wayland_core.outputs.len,
            max_stream_count,
        });
    }
    output_display_count = @intCast(u32, @min(max_stream_count, wayland_core.outputs.len));

    //
    // This perhaps isn't the most memory efficient, but we're going to capture a frame for each display
    // so that we know the dimensions + format for each of them. Once all have been accounted for
    // we allocate all the required memory to store `frames_per_stream` frames for each display
    //
    for (0..output_display_count) |i| {
        stream_buffer[i].output_index = @intCast(u32, i);
        stream_buffer[i].stream_state = .uninitialized;
        inline for (&stream_buffer[i].frame_index_buffer) |*index| {
            index.* = invalid_frame;
        }

        const display_output = wayland_core.outputs.buffer[i].handle;
        stream_buffer[i].captured_frames[0] = screencopy_manager.captureOutput(1, display_output) catch {
            return onInitErrorCallback(error.CaptureOutputFail);
        };
        stream_buffer[i].captured_frames[0].setListener(
            *Stream,
            &initFrameCaptureCallback,
            &stream_buffer[i],
        );
    }
}

pub fn deinit() void {}

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
    stream_index_opt: ?u16,
    onFrameReadyCallback: *const screencapture.OnFrameReadyFn,
    on_success_cb: *const screencapture.OpenStreamOnSuccessFn,
    on_error_cb: *const screencapture.OpenStreamOnErrorFn,
) void {
    _ = on_error_cb;

    if (!frame_callback_registered) {
        frame_callback_registered = true;
        wayland_client.addOnFrameCallback(&onFrameTick);
    }

    //
    // Check the stream state, if it's been initialized then we don't need to
    // do anything, just return
    //

    const stream_index: u16 = stream_index_opt orelse 0;

    assert(stream_buffer[stream_index].stream_state != .uninitialized);
    assert(stream_index < max_stream_count);

    stream_buffer[stream_index].stream_state = .running;
    stream_buffer[stream_index].frameReadyCallback = onFrameReadyCallback;

    on_success_cb(.{
        .index = stream_index,
        .pause = streamPause,
        .close = streamClose,
        .state = streamState,
        .pixel_format = .rgba,
        .dimensions = .{
            .width = stream_buffer[stream_index].width,
            .height = stream_buffer[stream_index].height,
        },
    });
}

pub fn state() screencapture.State {
    return backend_state;
}

const StreamFrameReference = packed struct(u64) {
    stream_index: u32,
    frame_index: u32,
};
var stream_frame_reference_buffer: [max_stream_count * frames_per_stream]StreamFrameReference = undefined;

fn onFrameTick(frame_index: u32) void {
    const screencopy_manager = wayland_core.screencopy_manager_opt orelse unreachable;
    assert(initialized_stream_count == 2);
    stream_loop: for (0..initialized_stream_count) |i| {
        if (stream_buffer[i].stream_state != .running)
            continue :stream_loop;
        const display_output = wayland_core.outputs.buffer[i].handle;
        inline for (&stream_buffer[i].frame_index_buffer, 0..) |*index, frame_index_index| {
            if (index.* == invalid_frame) {
                assert(stream_buffer[i].stream_state != .uninitialized);
                assert(stream_buffer[i].stream_state != .paused);
                const next_frame = screencopy_manager.captureOutput(1, display_output) catch {
                    std.log.err("screencapture: Failed to capture next frame", .{});
                    stream_buffer[i].stream_state = .fatal_error;
                    return;
                };
                const reference_index: usize = (i * frames_per_stream) + frame_index_index;
                stream_frame_reference_buffer[reference_index] = .{
                    .stream_index = @intCast(u32, i),
                    .frame_index = frame_index_index,
                };
                next_frame.setListener(
                    *const StreamFrameReference,
                    streamFrameCaptureCallback,
                    &stream_frame_reference_buffer[reference_index],
                );
                index.* = frame_index;
                continue :stream_loop;
            }
        }
        std.log.warn("wlroots screencapture: No free buffers to capture frame for stream #{d}", .{i});
    }
}

var screenshot_callback: *const screencapture.OnScreenshotReadyFn = undefined;
var screenshot_requested: bool = false;

pub fn screenshot(callback: *const screencapture.OnScreenshotReadyFn) void {
    screenshot_callback = callback;
    screenshot_requested = true;
}

fn streamFrameCaptureCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, frame_reference: *const StreamFrameReference) void {
    var stream_ptr = &stream_buffer[frame_reference.stream_index];
    switch (event) {
        .buffer_done => frame.copy(stream_ptr.buffers[frame_reference.frame_index].buffer),
        .ready => {
            const buffer_memory = buffer_allocator.mappedMemoryForBuffer(&stream_ptr.buffers[frame_reference.frame_index]);
            const unconverted_pixels = @ptrCast([*]PixelType, buffer_memory.ptr);
            switch (stream_ptr.format) {
                //
                // Nothing to do
                //
                .xbgr8888 => {},
                else => unreachable,
            }
            stream_ptr.*.frame_index_buffer[frame_reference.frame_index] = invalid_frame;
            assert(stream_buffer[0].frame_index_buffer[frame_reference.frame_index] == invalid_frame);
            stream_ptr.frameReadyCallback(stream_ptr.width, stream_ptr.height, unconverted_pixels);
        },
        .failed => {
            std.log.err("screencapture: Frame capture failed", .{});
            frame.destroy();
            stream_ptr.stream_state = .fatal_error;
            assert(false);
        },
        else => {},
    }
}

fn initFrameCaptureCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, stream: *Stream) void {
    switch (event) {
        .buffer => |buffer| {
            stream.width = buffer.width;
            stream.height = buffer.height;
            stream.stride = buffer.stride;
            stream.format = buffer.format;

            std.log.info("Display {d} registered with dimensions {d} x {d}", .{
                stream.output_index,
                stream.width,
                stream.height,
            });

            initialized_stream_count += 1;

            if (initialized_stream_count == output_display_count) {
                //
                // All displays have been accounted for, we can how calculate how much
                // memory we need to allocate and invoke the success callback function
                //
                const required_memory = blk: {
                    var counter: usize = 0;
                    for (0..initialized_stream_count) |i| {
                        counter += stream_buffer[i].requiredMemory();
                    }
                    break :blk counter;
                };
                // TODO: Round up to 8 bytes at least?
                buffer_allocator = WaylandBufferAllocator.init(
                    required_memory,
                    wayland_core.shared_memory,
                ) catch return onInitErrorCallback(error.AllocateWaylandBuffersFail);

                for (0..initialized_stream_count) |i| {
                    for (0..frames_per_stream) |c| {
                        stream_buffer[i].buffers[c] = buffer_allocator.create(
                            stream_buffer[i].width,
                            stream_buffer[i].height,
                            stream_buffer[i].stride,
                            stream_buffer[i].format,
                        ) catch return onInitErrorCallback(error.AllocateWaylandBuffersFail);
                        stream_buffer[i].frame_index_buffer[c] = invalid_frame;
                    }
                    stream_buffer[i].stream_state = .paused;
                }
                //
                // Good job team
                //
                assert(backend_state == .uninitialized);
                backend_state = .active;
                onInitSuccessCallback();
            }
        },
        //
        // There's no point copying the image into out allocated buffers
        // since we don't know if the user wants to state the stream yet.
        //
        .buffer_done => frame.destroy(),
        //
        // Seeing as we're destroying the frame at the `buffer_done` step,
        // it should never get here.
        //
        .ready => unreachable,
        .failed => {
            frame.destroy();
            onInitErrorCallback(error.WaylandScreencaptureFail);
        },
        else => {},
    }
}
