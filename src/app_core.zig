// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const zigimg = @import("zigimg");
const graphics = @import("graphics.zig");
const screencapture = @import("screencapture.zig");
const build_options = @import("build_options");
const frontend = @import("frontend.zig");
const Model = @import("Model.zig");
const utils = @import("utils.zig");
const DateTime = utils.DateTime;
const Timer = utils.Timer;
const zmath = @import("zmath");
const video_encoder = @import("video_record.zig");
const geometry = @import("geometry.zig");
const Dimensions2D = geometry.Dimensions2D;
const Extent2D = geometry.Extent2D;
const WebcamStream = @import("WebcamStream.zig").WebcamStream;
const AudioSampleRingBuffer = @import("AudioSampleRingBuffer.zig");

// TODO: Audit, doesn't renderer belong here?
const renderer = @import("renderer.zig");

const audio_source = @import("audio_source.zig");
var audio_source_interface: audio_source.Interface = undefined;

const wayland_core = if (build_options.have_wayland) @import("wayland_core.zig") else void;

pub const CoreUpdate = enum {
    video_source_added,
    source_provider_added,
};

pub const Request = enum(u8) {
    core_shutdown,

    record_start,
    record_pause,
    record_resume,
    record_stop,
    record_quality_set,
    record_format_set,

    stream_start,

    screencapture_add_source,
    screencapture_request_source,

    webcam_enable,
    webcam_disable,

    screenshot_format_set,
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

const max_audio_streams = 2;
var audio_stream_buffer: [max_audio_streams]Model.AudioStream = undefined;

const max_video_streams = 2;
var video_stream_buffer: [max_video_streams]Model.VideoStream = undefined;

pub const CoreRequestEncoder = utils.Encoder(Request, 512);
pub const CoreRequestDecoder = CoreRequestEncoder.Decoder;

pub const UpdateEncoder = utils.Encoder(CoreUpdate, 512);
pub const UpdateDecoder = UpdateEncoder.Decoder;

var update_encoder: UpdateEncoder = .{};
var update_encoder_mutex: std.Thread.Mutex = .{};

var video_source_provider_buffer: [2]Model.VideoSourceProvider = undefined;
var audio_source_provider_buffer: [2]Model.AudioSourceProvider = undefined;

var model: Model = .{
    .video_source_providers = &.{},
    .audio_source_providers = &.{},
    .audio_streams = &.{},
    .video_streams = &.{},
    .recording_context = .{
        .format = .mp4,
        .quality = .low,
        .start = 0,
        .video_streams = undefined,
        .audio_streams = undefined,
        .state = .idle,
    },
    .screenshot_format = .png,
    .webcam_stream = .{
        .dimensions = .{ .width = 640, .height = 480 },
        .last_frame = undefined,
        .last_frame_index = std.math.maxInt(u64),
    },
    .canvas_dimensions = .{ .width = 1920, .height = 1080 },
};

var model_mutex: std.Thread.Mutex = .{};

var webcam_opt: ?WebcamStream = null;

var screencapture_open: bool = false;
var frame_index: u64 = 0;

var last_audio_source_timestamp: i128 = 0;
var last_screencapture_input_timestamp: i128 = 0;
var last_video_frame_written_ns: i128 = 0;

var recording_audio_sample_index: usize = 0;
var recording_start_timestamp: i128 = 0;

var recording_sample_count: u64 = 0;
var recording_sample_base_index: u64 = 0;
var recording_frame_index_base: u64 = 0;

var gpa: std.mem.Allocator = undefined;

var microphone_audio_stream = audio_source.StreamHandle{ .index = std.math.maxInt(u32) };
var desktop_audio_stream = audio_source.StreamHandle{ .index = std.math.maxInt(u32) };
var audio_sources_ref: []audio_source.SourceInfo = undefined;

var active_audio_stream: *audio_source.StreamHandle = &microphone_audio_stream;

//
// TODO: This should probably be heap allocated
//
const sample_multiple = 2048; // ~50ms
var sample_buffer: [sample_multiple * 3]f32 = undefined;

var screencapture_start: ?i128 = null;

var stream_count: u32 = 0;

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
                break :blk screencapture.createInterface(supported_backend) catch |err| {
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

    audio_source_interface = audio_source.bestInterface();

    audio_source_interface.init(
        &handleAudioSourceInitSuccess,
        &handleAudioSourceInitFail,
    ) catch return error.AudioInputInitFail;
}

pub fn run() !void {
    const input_fps = 60;
    const ns_per_frame: u64 = @divFloor(std.time.ns_per_s, input_fps);

    app_loop: while (true) {
        const frame_timer = Timer.now();

        _ = wayland_core.sync();

        if (webcam_opt) |*webcam| {
            if (try webcam.getFrame(model.webcam_stream.last_frame, 0, 0, model.webcam_stream.dimensions.width)) {
                model.webcam_stream.last_frame_index += 1;
            }
        }

        const frontend_timer = Timer.now();
        model_mutex.lock();
        var update_decoder = update_encoder.decoder();
        var request_buffer = frontend_interface.update(&model, &update_decoder) catch |err| {
            std.log.err("Runtime User Interface error. {}", .{err});
            return;
        };
        model_mutex.unlock();
        frontend_timer.durationLog("Frontend");

        update_encoder_mutex.lock();
        update_encoder.reset();
        update_encoder_mutex.unlock();

        request_loop: while (request_buffer.next()) |request| {
            switch (request) {
                .core_shutdown => {
                    std.log.info("core: shutdown request", .{});
                    break :app_loop;
                },
                .screencapture_add_source => {
                    const stream_index = request_buffer.readInt(u16) catch unreachable;
                    std.log.info("core: Opening screencapture stream {d}", .{stream_index});
                    screencapture_interface.openStream(
                        stream_index,
                        &onFrameReadyCallback,
                        &openStreamSuccessCallback,
                        &openStreamErrorCallback,
                        &.{},
                    );
                },
                .screencapture_request_source => {
                    //
                    // Passing null for `stream_index` indicates that any stream is fine, or
                    // can it be decided by an external interface. This is required for the pipewire
                    // backend which prompts the user which display to open a screencapture for
                    //
                    screencapture_interface.openStream(
                        null,
                        &onFrameReadyCallback,
                        &openStreamSuccessCallback,
                        &openStreamErrorCallback,
                        &.{},
                    );
                },
                .screenshot_do => screencapture_interface.screenshot(&onScreenshotReady),
                .screenshot_format_set => {
                    const format_index = request_buffer.readInt(u16) catch 0;
                    assert(format_index < @typeInfo(Model.ImageFormat).Enum.fields.len);
                    model.screenshot_format = @intToEnum(Model.ImageFormat, format_index);
                    std.log.info("Screenshot output format set to: {s}", .{@tagName(model.screenshot_format)});
                },
                .screenshot_display_set => {
                    const display_index = request_buffer.readInt(u16) catch 0;
                    const display_list = displayList();
                    std.log.info("Screenshot display set to: {s}", .{display_list[display_index]});
                },
                .record_start => {
                    if (model.video_streams.len == 0 or model.audio_streams.len == 0) {
                        std.log.err("Cannot start recording without streams", .{});
                        continue :request_loop;
                    }

                    const RecordOptions = video_encoder.RecordOptions;
                    const quality: RecordOptions.Quality = switch (model.recording_context.quality) {
                        .low => .low,
                        .medium => .medium,
                        .high => .high,
                    };
                    const extension: RecordOptions.Format = switch (model.recording_context.format) {
                        .mp4 => .mp4,
                        .avi => .avi,
                        // .mkv => .mkv,
                    };
                    var file_name_buffer: [256]u8 = undefined;
                    const date_time = DateTime.now();
                    const output_file_name = std.fmt.bufPrint(&file_name_buffer, "reel_{d}_{d}_{d}{d}{d}", .{
                        date_time.year,
                        date_time.month,
                        date_time.hour,
                        date_time.minute,
                        date_time.second,
                    }) catch blk: {
                        std.log.err("Failed to generate unique name for recording. Saving as `reel_recording`", .{});
                        break :blk "reel_recording";
                    };
                    const options = RecordOptions{
                        .output_name = output_file_name,
                        .dimensions = model.canvas_dimensions,
                        .format = extension,
                        .quality = quality,
                        .fps = 60,
                    };

                    assert(video_encoder.state == .uninitialized or video_encoder.state == .closed);

                    video_encoder.open(options) catch |err| {
                        std.log.err("app: Failed to start video encoder. Error: {}", .{err});
                        continue :request_loop;
                    };
                    model.recording_context.start = std.time.nanoTimestamp();
                    model.recording_context.state = .sync;
                },
                .record_stop => {
                    model.recording_context.state = .closing;
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
                .webcam_disable => {
                    if (model.webcam_stream.enabled()) {
                        webcam_opt.?.deinit() catch assert(false);
                        webcam_opt = null;
                        const pixels_count: usize = model.webcam_stream.dimensions.width * model.webcam_stream.dimensions.height;
                        gpa.free(model.webcam_stream.last_frame[0..pixels_count]);
                        model.webcam_stream.last_frame_index = std.math.maxInt(u64);
                        assert(!model.webcam_stream.enabled());
                        std.log.info("Webcam: disabled", .{});
                    } else assert(false);
                },
                .webcam_enable => {
                    //
                    // TODO: Implement
                    //
                    assert(false);
                },
                else => std.log.err("Invalid core request", .{}),
            }
        }

        var frame_duration_ns = frame_timer.duration();
        if (frame_duration_ns < ns_per_frame) {
            const remaining_ns = ns_per_frame - frame_duration_ns;
            // std.log.info("Frame duration: {d} ms", .{16 - @divFloor(remaining_ns, std.time.ns_per_ms)});
            std.time.sleep(remaining_ns);
        } else {
            std.log.warn("Frame overbudget", .{});
        }
    }

    const application_end = std.time.nanoTimestamp();
    if (screencapture_start) |start| {
        const screencapture_duration_ns = @intCast(u64, application_end - start);
        const screencapture_duration_seconds: f64 = @intToFloat(f64, screencapture_duration_ns) / @as(f64, std.time.ns_per_s);
        const screencapture_fps = @intToFloat(f64, frame_index) / screencapture_duration_seconds;
        std.log.info("Display FPS: {d:.2}", .{screencapture_fps});
    }
}

pub fn deinit() void {
    audio_source_interface.deinit();

    for (model.audio_streams) |*audio_stream| {
        audio_stream.sample_buffer.deinit(gpa);
    }

    //
    // TODO:
    //

    if (webcam_opt) |*webcam| {
        webcam.deinit() catch {};
    }

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

fn onFrameReadyCallback(stream_handle: screencapture.StreamHandle, width: u32, height: u32, pixels: [*]const screencapture.PixelType) void {
    model_mutex.lock();
    defer model_mutex.unlock();

    if (screencapture_start == null)
        screencapture_start = std.time.nanoTimestamp();

    for (model.video_streams) |*stream| {
        if (stream.source_index == stream_handle) {
            stream.pixels = pixels;
            assert(stream.provider_index == 0);
            assert(stream.dimensions.width == width);
            assert(stream.dimensions.height == height);
            stream.frame_index = frame_index;
        }
    }

    const pixel_count: usize = width * height;
    const renderer_source_index = stream_binding_buffer[stream_handle];
    renderer.writeStreamFrame(renderer_source_index, @ptrCast([*]const u8, pixels)[0 .. pixel_count * 4]) catch assert(false);

    const video_frame_to_encode: [*]const graphics.RGBA(u8) = pixels;

    //
    // Find the audio sample that corresponds to the start of the first video frame
    //
    if (model.recording_context.state == .sync) {
        model.recording_context.state = .recording;

        recording_start_timestamp = std.time.nanoTimestamp();

        const audio_buffer_opt: ?AudioSampleRingBuffer = if (model.audio_streams.len != 0) model.audio_streams[0].sample_buffer else null;
        const samples_for_frame = blk: {
            if (audio_buffer_opt) |audio_buffer| {
                const sample_index = audio_buffer.lastNSample(sample_multiple);
                recording_sample_base_index = sample_index;
                break :blk audio_buffer.samplesCopyIfRequired(
                    sample_index,
                    sample_multiple,
                    sample_buffer[0..sample_multiple],
                );
            } else break :blk sample_buffer[0..sample_multiple];
        };

        video_encoder.appendVideoFrame(video_frame_to_encode, 0) catch unreachable;
        video_encoder.appendAudioFrame(samples_for_frame) catch unreachable;

        recording_frame_index_base = frame_index;
        recording_sample_count = sample_multiple;
    } else if (model.recording_context.state == .recording) {
        const audio_buffer_opt: ?AudioSampleRingBuffer = if (model.audio_streams.len != 0) model.audio_streams[0].sample_buffer else null;
        const samples_to_encode = blk: {
            if (audio_buffer_opt) |audio_buffer| {
                const sample_index: u64 = recording_sample_base_index + recording_sample_count;
                const samples_in_buffer: u64 = audio_buffer.availableSamplesFrom(sample_index);
                const overflow: u64 = samples_in_buffer % sample_multiple;
                const samples_to_load: u64 = @min(samples_in_buffer - overflow, sample_multiple * 3);
                assert(samples_to_load % sample_multiple == 0);
                recording_sample_count += samples_to_load;
                break :blk if (samples_to_load > 0) audio_buffer.samplesCopyIfRequired(
                    sample_index,
                    samples_to_load,
                    sample_buffer[0..samples_to_load],
                ) else &[0]f32{};
            } else break :blk sample_buffer[0..sample_multiple];
        };

        const current_time_ns = std.time.nanoTimestamp();
        const ns_from_record_start = @intCast(i64, current_time_ns - recording_start_timestamp);
        const ms_from_record_start = @divFloor(ns_from_record_start, std.time.ns_per_ms);
        const ms_per_frame: f64 = 1000.0 / 60.0;
        const current_frame_index = @floatToInt(i64, @floor(@intToFloat(f64, ms_from_record_start) / ms_per_frame));
        last_video_frame_written_ns = current_time_ns;

        video_encoder.appendVideoFrame(video_frame_to_encode, current_frame_index) catch |err| {
            std.log.warn("Failed to write video frame. Error: {}", .{err});
        };
        if (samples_to_encode.len != 0) {
            video_encoder.appendAudioFrame(samples_to_encode) catch |err| {
                std.log.warn("Failed to write audio frame. Error: {}", .{err});
            };
        }
    } else if (model.recording_context.state == .closing) {
        const current_time_ns = std.time.nanoTimestamp();
        const recording_ns = @intCast(u64, current_time_ns - recording_start_timestamp);
        const recording_ms = @divFloor(recording_ns, std.time.ns_per_ms);
        const channel_count: f64 = 2.0;
        const audio_samples_ms = @floatToInt(u64, @floor(@intToFloat(f64, recording_sample_count) / (44.1 * channel_count)));
        const video_frames_ns = @intCast(u64, last_video_frame_written_ns - recording_start_timestamp);
        const video_frames_ms = @divFloor(video_frames_ns, std.time.ns_per_ms);
        std.log.info("{d} ms of video & {d} ms of audio written. {d} ms expected", .{
            video_frames_ms,
            audio_samples_ms,
            recording_ms,
        });
        if (video_frames_ms > audio_samples_ms) {
            const audio_required_ms = video_frames_ms - audio_samples_ms;
            const sample_count_required = audio_required_ms * 44;
            const audio_buffer: AudioSampleRingBuffer = model.audio_streams[0].sample_buffer;
            const samples_to_encode = blk: {
                const sample_index: u64 = recording_sample_base_index + recording_sample_count;
                const samples_in_buffer: u64 = audio_buffer.availableSamplesFrom(sample_index);
                const samples_to_load: u64 = @min(sample_count_required, samples_in_buffer);
                assert(samples_to_load <= sample_multiple * 3);
                recording_sample_count += samples_to_load;
                break :blk if (samples_to_load > 0) audio_buffer.samplesCopyIfRequired(
                    sample_index,
                    samples_to_load,
                    sample_buffer[0..samples_to_load],
                ) else &[0]f32{};
            };
            video_encoder.appendAudioFrame(samples_to_encode) catch |err| {
                std.log.warn("Failed to write video frame. Error: {}", .{err});
            };
        } else if ((audio_samples_ms + 8) > video_frames_ms) {
            const ns_from_record_start = @intCast(i64, current_time_ns - recording_start_timestamp);
            const ms_from_record_start = @divFloor(ns_from_record_start, std.time.ns_per_ms);
            const current_frame_index = @divFloor(ms_from_record_start, 16);
            video_encoder.appendVideoFrame(video_frame_to_encode, current_frame_index) catch |err| {
                std.log.warn("Failed to write video frame. Error: {}", .{err});
            };
        }
        video_encoder.close();
        model.recording_context.state = .idle;
    }

    last_screencapture_input_timestamp = std.time.nanoTimestamp();

    frame_index += 1;
}

// NOTE: This will be called on a separate thread
pub fn onAudioSamplesReady(stream: audio_source.StreamHandle, pcm_buffer: []i16) void {
    if (active_audio_stream.*.index == stream.index) {
        // NOTE: model_mutex is also protecting `last_audio_source_timestamp` here
        model_mutex.lock();
        defer model_mutex.unlock();
        last_audio_source_timestamp = std.time.nanoTimestamp();

        //
        // TODO
        //
        model.audio_streams[0].sample_buffer.appendOverwrite(pcm_buffer);
    }
}

fn handleAudioSourceInitSuccess() void {
    assert(model.audio_source_providers.len == 0);
    audio_source_provider_buffer[0].name = audio_source_interface.info.name;
    model.audio_source_providers = audio_source_provider_buffer[0..1];
    assert(model.audio_source_providers.len == 1);
    update_encoder_mutex.lock();
    update_encoder.write(.source_provider_added) catch unreachable;
    update_encoder_mutex.unlock();
    audio_source_interface.listSources(gpa, handleSourceListReady);
}

fn handleSourceListReady(audio_sources: []audio_source.SourceInfo) void {
    std.log.info("Audio devices found: {d}", .{audio_sources.len});
    audio_sources_ref = audio_sources;
    var have_microphone: bool = false;
    // var have_desktop: bool = false;
    for (audio_sources, 0..) |source, source_i| {
        std.log.info("  {d}: name: {s} desc: {s} type {s}", .{ source_i, source.name, source.description, @tagName(source.source_type) });
        if (!have_microphone and source.source_type == .microphone) {
            audio_source_interface.createStream(
                @intCast(u32, source_i),
                &onAudioSamplesReady,
                &handleAudioSourceCreateStreamSuccess,
                &handleAudioSourceCreateStreamFail,
            ) catch |err| {
                std.log.err("audio_source: Failed to connect to device. Error: {}", .{err});
                continue;
            };
            std.log.info("Microphone connected: {d}", .{source_i});
            microphone_audio_stream = .{ .index = @intCast(u32, source_i) };
            have_microphone = true;
            assert(active_audio_stream.index == microphone_audio_stream.index);
            continue;
        }
        // if (!have_desktop and source.source_type == .desktop) {
        //     audio_source_interface.createStream(
        //         @intCast(u32, source_i),
        //         &onAudioSamplesReady,
        //         &handleAudioSourceCreateStreamSuccess,
        //         &handleAudioSourceCreateStreamFail,
        //     ) catch |err| {
        //         std.log.err("audio_source: Failed to connect to device. Error: {}", .{err});
        //         continue;
        //     };
        //     std.log.info("Desktop connected: {d}", .{source_i});
        //     desktop_audio_stream = .{ .index = @intCast(u32, source_i) };
        //     have_desktop = true;
        // }
    }
}

fn handleAudioSourceInitFail(err: audio_source.InitError) void {
    std.log.err("Failed to initialize audio input system. Error: {}", .{err});
}

fn handleAudioSourceCreateStreamSuccess(stream: audio_source.StreamHandle) void {
    const model_stream_index = model.audio_streams.len;
    const source_info = audio_sources_ref[stream.index];
    //
    // Buffer size of ~100 milliseconds at a sample rate of 44100 and 2 channels
    //
    const buffer_capacity_samples: usize = @divExact(44100, 10) * 2;
    audio_stream_buffer[model_stream_index].sample_buffer.init(gpa, buffer_capacity_samples) catch |err| {
        std.log.err("Failed to allocate audio stream. Error: {}", .{err});
        return;
    };
    audio_stream_buffer[model_stream_index].state = .open;
    audio_stream_buffer[model_stream_index].source_name = std.mem.span(source_info.name);
    audio_stream_buffer[model_stream_index].source_type = switch (source_info.source_type) {
        .desktop => .desktop,
        .microphone, .unknown => .microphone,
    };
    model.audio_streams = audio_stream_buffer[0 .. model_stream_index + 1];
}

fn handleAudioSourceCreateStreamFail(err: audio_source.CreateStreamError) void {
    std.log.err("Failed to open audio input device. Error: {}", .{err});
}

//
// Screen capture callbacks
//

var stream_binding_buffer: [8]u32 = undefined;

fn openStreamSuccessCallback(stream_handle: screencapture.StreamHandle, _: *anyopaque) void {
    const stream_info = screencapture_interface.streamInfo(stream_handle);
    const supported_image_format: renderer.SupportedVideoImageFormat = switch (stream_info.pixel_format.?) {
        .rgba => .rgba,
        .bgrx => .bgrx,
        else => unreachable,
    };
    stream_binding_buffer[stream_handle] = renderer.createStream(supported_image_format, stream_info.dimensions) catch unreachable;

    //
    // Draw this source to the canvas at 50% of it's size
    //
    const relative_extent = Extent2D(f32){
        .x = 0.0,
        .y = 0.0,
        .width = 1.0,
        .height = 1.0,
    };
    renderer.addVideoSource(stream_binding_buffer[stream_handle], relative_extent);

    std.log.info("Stream opened!", .{});

    model.video_streams = video_stream_buffer[0 .. stream_count + 1];
    model.video_streams[stream_count] = .{
        .frame_index = 0,
        .pixels = undefined,
        .provider_index = 0,
        .source_index = stream_handle,
        .dimensions = stream_info.dimensions,
    };
    stream_count += 1;

    update_encoder_mutex.lock();
    update_encoder.write(.video_source_added) catch unreachable;
    update_encoder_mutex.unlock();
}

fn openStreamErrorCallback(_: *anyopaque) void {
    // TODO:
    std.log.err("Failed to open screencapture stream", .{});
}

fn screenCaptureInitSuccess() void {
    assert(model.video_source_providers.len == 0);
    model.video_source_providers = video_source_provider_buffer[0..1];
    model.video_source_providers[0].name = screencapture_interface.info.name;
    if (screencapture_interface.info.query_streams) {
        std.log.info("Screencapture backend initialized. Streams..", .{});
        const streams = screencapture_interface.queryStreams(gpa);
        assert(streams.len <= 16);
        model.video_source_providers[0].sources = gpa.alloc(Model.VideoSourceProvider.Source, streams.len) catch unreachable;
        var sources_ptr = &(model.video_source_providers[0].sources.?);
        for (streams, 0..) |stream, i| {
            std.log.info("  {s} {d} x {d}", .{ stream.name, stream.dimensions.width, stream.dimensions.height });
            sources_ptr.*[i].name = stream.name;
            sources_ptr.*[i].dimensions = stream.dimensions;
        }
    }
}

fn screenCaptureInitFail(errcode: screencapture.InitErrorSet) void {
    // TODO: Handle
    std.log.err("app: Failed to open screen capture stream. Code: {}", .{errcode});
    std.debug.assert(false);
}

fn onScreenshotReady(width: u32, height: u32, pixels: [*]const graphics.RGBA(u8)) void {
    model_mutex.lock();
    const format = model.screenshot_format;
    model_mutex.unlock();

    const save_image_thread = std.Thread.spawn(.{}, saveImageToFile, .{ width, height, pixels, format }) catch |err| {
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
    file_format: Model.ImageFormat,
) void {
    var file_name_buffer: [256]u8 = undefined;
    const date_time = DateTime.now();
    const file_name = std.fmt.bufPrint(&file_name_buffer, "screenshot_{d}_{d}_{d}{d}{d}.{s}", .{
        date_time.year,
        date_time.month,
        date_time.hour,
        date_time.minute,
        date_time.second,
        @tagName(file_format),
    }) catch blk: {
        std.log.err("Failed to generate unique name for screenshot image. Saving as `reel_screenshot.png`", .{});
        break :blk "reel_screenshot.png";
    };

    const pixel_count: usize = @intCast(usize, width) * height;
    var pixels_copy = gpa.dupe(graphics.RGBA(u8), pixels[0..pixel_count]) catch unreachable;
    var image = zigimg.Image.create(gpa, width, height, .rgba32) catch {
        std.log.err("Failed to create screenshot image", .{});
        return;
    };
    const converted_pixels = @ptrCast([*]zigimg.color.Rgba32, pixels_copy.ptr)[0..pixel_count];
    image.pixels = .{ .rgba32 = converted_pixels };

    const write_options: zigimg.Image.EncoderOptions = switch (file_format) {
        .png => .{ .png = .{} },
        .qoi => .{ .qoi = .{} },
    };

    image.writeToFilePath(file_name, write_options) catch |err| {
        std.log.err("Failed to write screenshot to {s}. Error: {}", .{ file_name, err });
        return;
    };

    std.log.info("Screenshot saved to {s}", .{file_name});
}
