// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wlr = wayland.client.zwlr;

const geometry = @import("../geometry.zig");
const graphics = @import("../graphics.zig");

const WaylandBufferAllocator = @import("BufferAllocator.zig");

pub const State = enum(u8) {
    uninitialized,
    init_pending,
    init_failed,
    open,
    closed,
};

const ScreenRecordBuffer = struct {
    frame_index: u64 = std.math.maxInt(u64),
    captured_frame: *wlr.ScreencopyFrameV1,
    buffer: WaylandBufferAllocator.Buffer,
};

const DisplayInfo = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: wl.Shm.Format,
};

//
// TODO: Not a priority as we're only storing 3 entries, but this is rather space inefficient
//
const Entry = struct {
    const Flags = packed struct(u32) {
        ready: bool,
        reserved: u31,
    };

    buffer: WaylandBufferAllocator.Buffer,
    captured_frame: *wlr.ScreencopyFrameV1,
    frame_index: u32,
    flags: Flags,
};

//
// Public Variables
//

//
// TODO: This should be exposed via a function to make it read-only, however I'm not sure about the naming scheme
//       It might make sense to use "member" prefixes like "_state" as I've run into this a couple of times. I'll
//       have a think about it and revisit.
//
pub var state: State = .uninitialized;

pub const OpenOnSuccessFn = fn (width: u32, height: u32) void;
pub const OpenOnErrorFn = fn () void;

//
// Internal Variables
//

const PixelType = graphics.RGBA(u8);
const FrameImage = graphics.Image(PixelType);
const buffer_entry_count = 3;
const invalid_frame = std.math.maxInt(u32);

var on_success_handler: *const OpenOnSuccessFn = undefined;
var on_error_handler: *const OpenOnErrorFn = undefined;

var display_info: DisplayInfo = undefined;

var shared_memory_ref: *wl.Shm = undefined;
var display_output_ref: *wl.Output = undefined;
var screencopy_manager_ref: *wlr.ScreencopyManagerV1 = undefined;
var buffer_allocator: WaylandBufferAllocator = undefined;

var entry_buffer: [buffer_entry_count]Entry = undefined;

var image_buffer: []PixelType = undefined;

//
// Public Interface
//

pub fn open(
    display_output: *wl.Output,
    screencopy_manager: *wlr.ScreencopyManagerV1,
    shared_memory: *wl.Shm,
    on_success_cb: *const OpenOnSuccessFn,
    on_error_cb: *const OpenOnErrorFn,
) !void {
    on_success_handler = on_success_cb;
    on_error_handler = on_error_cb;

    shared_memory_ref = shared_memory;
    display_output_ref = display_output;
    screencopy_manager_ref = screencopy_manager;

    //
    // We need to know about the display (monitor) to complete initialization. This is done in the following
    // callback and we set state to `init_pending` meanwhile. Once the callback successfully completes, state
    // will be set to `.open` and `captureFrame` can be called on the current frame
    //
    const frame = try screencopy_manager.captureOutput(1, display_output);
    frame.setListener(
        *const void,
        finishedInitializationCallback,
        &{},
    );

    state = .init_pending;
}

pub fn close() void {
    state = .closed;
}

pub fn captureFrame(frame_index: u32) !void {
    std.debug.assert(state == .open);
    var i: usize = 0;
    while (i < buffer_entry_count) : (i += 1) {
        var entry_ptr = &entry_buffer[i];
        if (entry_ptr.frame_index == std.math.maxInt(u32)) {
            entry_ptr.frame_index = frame_index;
            const next_frame = try screencopy_manager_ref.captureOutput(1, display_output_ref);
            next_frame.setListener(
                *Entry,
                frameCaptureCallback,
                entry_ptr,
            );
            entry_ptr.flags.ready = false;
            entry_ptr.captured_frame = next_frame;
            return;
        }
    }

    //
    // TODO: We should override the older entry
    //
    return error.BufferFull;
}

/// Get the "next" screen image that has been saved into the internal buffer
/// We define "next" as the entry with the lowest valid index
pub fn nextFrameImage() ?FrameImage {
    var closest_frame_index: u32 = std.math.maxInt(u32);
    var closest_entry_index: u32 = std.math.maxInt(u32);
    {
        comptime var i: usize = 0;
        inline while (i < buffer_entry_count) : (i += 1) {
            const entry_ptr = &entry_buffer[i];
            if (entry_ptr.frame_index != invalid_frame) {
                if (entry_ptr.flags.ready) {
                    if (entry_ptr.frame_index < closest_frame_index) {
                        closest_frame_index = entry_ptr.frame_index;
                        closest_entry_index = @intCast(u32, i);
                    }
                }
            }
        }
    }

    if (closest_frame_index == std.math.maxInt(u32))
        return null;

    var entry_ptr = &entry_buffer[closest_entry_index];
    const buffer_memory = buffer_allocator.mappedMemoryForBuffer(&entry_ptr.buffer);
    const unconverted_pixels = @ptrCast([*]graphics.RGBA(u8), buffer_memory.ptr);
    entry_ptr.frame_index = invalid_frame;

    return FrameImage{
        .width = @intCast(u16, display_info.width),
        .height = @intCast(u16, display_info.height),
        .pixels = unconverted_pixels,
    };
}

//
// Private Interface
//

fn finishedInitializationCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, _: *const void) void {
    switch (event) {
        .buffer => |buffer| {
            state = .init_failed;

            defer frame.destroy();

            display_info.width = buffer.width;
            display_info.height = buffer.height;
            display_info.stride = buffer.stride;
            display_info.format = buffer.format;

            const bytes_per_frame = buffer.stride * buffer.height;
            const pool_size_bytes = bytes_per_frame * buffer_entry_count;

            buffer_allocator = WaylandBufferAllocator.init(pool_size_bytes, shared_memory_ref) catch return on_error_handler();

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
                    return on_error_handler();
                };
            }
            state = .open;
            on_success_handler(buffer.width, buffer.height);
        },
        else => {},
    }
}

fn frameCaptureCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, entry: *Entry) void {
    switch (event) {
        .buffer_done => frame.copy(entry.buffer.buffer),
        .ready => entry.flags.ready = true,
        //
        // TODO: Handle this properly
        //
        .failed => {
            std.log.err("wayland_client: Frame capture failed", .{});
            frame.destroy();
        },
        else => {},
    }
}
