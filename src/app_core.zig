// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const log = std.log;
const zigimg = @import("zigimg");
const graphics = @import("graphics.zig");
const screencapture = @import("screencapture.zig");
const build_options = @import("build_options");
const frontend = @import("frontend.zig");
const Model = @import("Model.zig");
const Timer = @import("Timer.zig");
const zmath = @import("zmath");
const video_encoder = @import("video_record.zig");
const RequestBuffer = @import("RequestBuffer.zig");
const geometry = @import("geometry.zig");

const audio_input = @import("audio.zig");
var audio_input_interface: audio_input.Interface = undefined;

const wayland_core = if (build_options.have_wayland) @import("wayland_core.zig") else void;

pub const Request = enum(u8) {
    core_shutdown,

    record_start,
    record_pause,
    record_stop,
    record_quality_set,
    record_format_set,

    screenshot_output_set,
    screenshot_region_set,
    screenshot_display_set,
    screenshot_do,
};

pub const ScreenCaptureBackend = screencapture.Backend;

pub const InitOptions = struct {
    screencapture_order: []const ScreenCaptureBackend,
    frontend: frontend.InterfaceImplTag,
};

const State = enum {
    uninitialized,
    initialized,
    running,
    closed,
};

pub const InitError = error{
    IncorrectState,
    WaylandInitFail,
    NoScreencaptureBackend,
    ScreencaptureInitFail,
    FrontendInitFail,
    AudioInputInitFail,
    OutOfMemory,
};

var app_state: State = .uninitialized;
var screencapture_interface: screencapture.Interface = undefined;
var frontend_interface: frontend.Interface = undefined;

var model: Model = .{
    .input_audio_buffer = undefined,
    .audio_input_volume_db = -9.0,
    .desktop_capture_frame = null,
    .recording_context = .{
        .format = .mp4,
        .quality = .low,
        .start = 0,
        .video_streams = undefined,
        .audio_streams = undefined,
        .state = .idle,
    },
};

var model_mutex: std.Thread.Mutex = .{};

var screencapture_open: bool = false;
var screencapture_stream: ?screencapture.StreamInterface = null;
var frame_index: u64 = 0;

var gpa: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator, options: InitOptions) InitError!void {
    if (app_state != .uninitialized)
        return error.IncorrectState;

    gpa = allocator;

    std.debug.assert(options.screencapture_order.len != 0);

    if (comptime build_options.have_wayland) {
        wayland_core.init(gpa) catch |err| {
            log.err("Failed to initialize Wayland. Error: {}", .{err});
            return error.WaylandInitFail;
        };
    }

    const supported_screencapture_backends = screencapture.detectBackends();
    screencapture_interface = blk: for (options.screencapture_order) |ordered_backend| {
        inner: for (supported_screencapture_backends) |supported_backend| {
            if (ordered_backend == supported_backend) {
                log.info("Screencapture backend: {s}", .{@tagName(supported_backend)});
                break :blk screencapture.createInterface(supported_backend, onFrameReadyCallback) catch |err| {
                    log.err("Failed to create interface to screencapture backend ({s}). Error: {}", .{
                        @tagName(supported_backend),
                        err,
                    });
                    continue :inner;
                };
            }
        }
    } else return error.NoScreencaptureBackend;

    screencapture_interface.init(&screenCaptureInitSuccess, &screenCaptureInitFail);

    _ = wayland_core.sync();

    frontend_interface = frontend.interface(options.frontend);
    frontend_interface.init(gpa) catch return error.FrontendInitFail;

    //
    // Buffer size of ~10 milliseconds at a sample rate of 44100 and 2 channels
    //
    const buffer_capacity_samples: usize = @divExact(44100, 10) * 2;
    try model.input_audio_buffer.init(gpa, buffer_capacity_samples);

    audio_input_interface = audio_input.createBestInterface(&onAudioInputRead);

    audio_input_interface.init(
        &handleAudioInputInitSuccess,
        &handleAudioInputInitFail,
    ) catch return error.AudioInputInitFail;
}

pub fn run() !void {
    const input_fps = 60;
    const ns_per_frame = @divFloor(std.time.ns_per_s, input_fps);

    while (true) {
        const frame_timer = Timer.now();
        _ = wayland_core.sync();

        model_mutex.lock();
        var request_buffer = frontend_interface.update(&model) catch |err| {
            std.log.err("Runtime User Interface error. {}", .{err});
            return;
        };
        model_mutex.unlock();

        while (request_buffer.next()) |request| {
            switch (request) {
                .core_shutdown => {
                    std.log.info("core: shutdown request", .{});
                    return;
                },
                .screenshot_do => {
                    std.log.info("Taking screenshot!", .{});
                    screencapture_interface.screenshot(&onScreenshotReady);
                },
                .screenshot_display_set => {
                    const display_index = request_buffer.readInt(u16) catch 0;
                    const display_list = displayList();
                    std.log.info("Screenshot display set to: {s}", .{display_list[display_index]});
                },
                .record_start => {
                    const options = video_encoder.RecordOptions{
                        .output_path = "reel_test.mp4",
                        .dimensions = .{
                            .width = 1920,
                            .height = 1080,
                        },
                        .fps = 60,
                    };
                    video_encoder.open(options) catch |err| {
                        std.log.err("app: Failed to start video encoder. Error: {}", .{err});
                    };
                    model.recording_context = .{
                        .format = .mp4,
                        .quality = .low,
                        .start = std.time.nanoTimestamp(),
                        .video_streams = undefined,
                        .audio_streams = undefined,
                        .state = .recording,
                    };
                },
                .record_stop => {
                    video_encoder.close();
                    model.recording_context.state = .idle;
                    std.log.info("Video terminated", .{});
                },
                .record_format_set => {
                    const format_index = request_buffer.readInt(u16) catch 0;
                    model.recording_context.format = @intToEnum(Model.VideoFormat, format_index);
                    std.log.info("Video format set to {s}", .{@tagName(model.recording_context.format)});
                },
                .record_quality_set => {
                    const quality_index = request_buffer.readInt(u16) catch 0;
                    model.recording_context.quality = @intToEnum(Model.VideoQuality, quality_index);
                    std.log.info("Video quality set to {s}", .{@tagName(model.recording_context.quality)});
                },
                else => std.log.err("Invalid core request", .{}),
            }
        }

        //
        // if recording, and have a complete video + audio frame, send it to the encoder
        //

        const frame_duration = frame_timer.duration();
        if (frame_duration < ns_per_frame) {
            std.time.sleep(ns_per_frame - frame_duration);
        }
    }
}

pub fn deinit() void {
    audio_input_interface.close();

    model.input_audio_buffer.deinit(gpa);

    frontend_interface.deinit();
    if (comptime build_options.have_wayland) wayland_core.deinit();

    log.info("Shutting down app core", .{});
}

pub fn displayList() [][]const u8 {
    if (comptime build_options.have_wayland) {
        return wayland_core.display_list.items;
    }
    unreachable;
}

fn onFrameReadyCallback(width: u32, height: u32, pixels: [*]const screencapture.PixelType) void {
    model_mutex.lock();
    defer model_mutex.unlock();
    model.desktop_capture_frame = .{
        .dimensions = .{ .width = width, .height = height },
        .index = frame_index,
        .pixels = pixels,
    };
    frame_index += 1;
}

/// NOTE: This will be called on a separate thread
pub fn onAudioInputRead(pcm_buffer: []i16) void {
    model_mutex.lock();
    defer model_mutex.unlock();

    model.input_audio_buffer.appendOverwrite(pcm_buffer);
}

fn handleAudioInputInitSuccess() void {
    std.log.info("audio input system initialized", .{});
    audio_input_interface.open(
        // devices[0].name,
        null,
        &handleAudioInputOpenSuccess,
        &handleAudioInputOpenFail,
    ) catch |err| {
        std.log.err("audio_input: Failed to connect to device. Error: {}", .{err});
    };
    // audio_input_interface.inputList(general_allocator, handleAudioDeviceInputsList);
}

fn handleAudioInputInitFail(err: audio_input.InitError) void {
    std.log.err("Failed to initialize audio input system. Error: {}", .{err});
}

fn handleAudioInputOpenSuccess() void {
    std.log.info("Audio input stream opened", .{});
}

fn handleAudioInputOpenFail(err: audio_input.OpenError) void {
    std.log.err("Failed to open audio input device. Error: {}", .{err});
}

//
// Screen capture callbacks
//

fn openStreamSuccessCallback(opened_stream: screencapture.StreamInterface) void {
    screencapture_stream = opened_stream;
}

fn openStreamErrorCallback() void {
    // TODO:
    std.log.err("Failed to open screencapture stream", .{});
}

fn screenCaptureInitSuccess() void {
    screencapture_interface.openStream(
        &openStreamSuccessCallback,
        &openStreamErrorCallback,
    );
}

fn screenCaptureInitFail(errcode: screencapture.InitErrorSet) void {
    // TODO: Handle
    std.log.err("app: Failed to open screen capture stream. Code: {}", .{errcode});
    std.debug.assert(false);
}

fn onScreenshotReady(width: u32, height: u32, pixels: [*]const graphics.RGBA(u8)) void {
    const save_image_thread = std.Thread.spawn(.{}, saveImageToFile, .{ width, height, pixels, "screenshot.png" }) catch |err| {
        std.log.err("Failed to create thread to open pipewire screencast. Error: {}", .{
            err,
        });
        return;
    };
    save_image_thread.detach();
}

fn saveImageToFile(
    width: u32,
    height: u32,
    pixels: [*]const graphics.RGBA(u8),
    file_path: []const u8,
) void {
    const pixel_count: usize = @intCast(usize, width) * height;
    var pixels_copy = gpa.dupe(graphics.RGBA(u8), pixels[0..pixel_count]) catch unreachable;
    var image = zigimg.Image.create(gpa, width, height, .rgba32) catch {
        std.log.err("Failed to create screenshot image", .{});
        return;
    };
    const converted_pixels = @ptrCast([*]zigimg.color.Rgba32, pixels_copy.ptr)[0..pixel_count];
    image.pixels = .{ .rgba32 = converted_pixels };
    image.writeToFilePath(file_path, .{ .png = .{} }) catch {
        std.log.err("Failed to write screenshot to path", .{});
        return;
    };
    std.log.info("Screenshot saved!", .{});
}
