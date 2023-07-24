// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const geometry = @import("geometry.zig");
const Dimensions2D = geometry.Dimensions2D;

const graphics = @import("graphics.zig");
const RGBA = graphics.RGBA;

const AudioSampleRingBuffer = @import("AudioSampleRingBuffer.zig");

const utils = @import("utils.zig");
const ThreadUtilMonitor = utils.ThreadUtilMonitor;

pub const ImageFormat = enum {
    // bmp,
    // jpg,
    png,
    qoi,
};

pub const AudioStreamHandle = u16;

pub const VideoFormat = enum(u8) {
    mp4,
    avi,
    // mkv,
};

pub const VideoQuality = enum(u8) {
    low,
    medium,
    high,
};

pub const RecordingContext = struct {
    pub const State = enum {
        idle,
        sync,
        closing,
        recording,
        paused,
    };

    format: VideoFormat,
    quality: VideoQuality,
    start: i128,
    video_streams: []u32,
    audio_streams: []AudioStreamHandle,
    state: State = .idle,
};

pub const VideoFrame = struct {
    index: u64,
    pixels: [*]const RGBA(u8),
    dimensions: Dimensions2D(u32),
};

pub const AudioStream = struct {
    state: enum { open, closed, paused },
    source_type: enum { microphone, desktop, unknown },
    source_name: []const u8,
    volume_db: f32,
    sample_buffer: AudioSampleRingBuffer,
};

pub const VideoProviderRef = packed struct(u16) {
    index: u10,
    kind: enum(u6) {
        screen_capture,
        webcam,
    },
};

pub const VideoStream = struct {
    frame_index: u64,
    /// Reference to the provider that provides the source.
    provider_ref: VideoProviderRef,
    /// The handle given by the provider that identifies the source
    source_handle: u16,
    renderer_handle: u32,
    pixels: []const RGBA(u8),
    dimensions: Dimensions2D(u32),
};

pub const VideoSourceProvider = struct {
    pub const Source = struct {
        name: []const u8,
        dimensions: Dimensions2D(u32),
        framerate: u32,
    };

    name: []const u8,
    sources: ?[]Source,
    query_support: bool,
};

pub const WebcamSourceProvider = struct {
    pub const Source = struct {
        name: []const u8,
        dimensions: Dimensions2D(u32),
        framerate: u32,
    };

    name: []const u8,
    sources: []Source,
};

pub const AudioSourceProvider = struct {
    name: []const u8,
};

pub const Scene = struct {
    name: []const u8 = "",
    audio_streams: [8]u16 = [1]u16{std.math.maxInt(u16)} ** 8,
    video_streams: [8]u16 = [1]u16{std.math.maxInt(u16)} ** 8,

    pub inline fn isNull(self: *@This()) bool {
        return self.name.len == 0;
    }

    pub inline fn setNull(self: *@This()) void {
        self.name = "";
        assert(self.isNull());
    }
};

pub fn addScene(self: *@This(), name: []const u8) usize {
    for (self.scenes, 0..) |*scene, scene_i| {
        if (scene.isNull()) {
            scene.name = name;
            return scene_i;
        }
    }
    std.log.err("Scene buffer full", .{});
    unreachable;
}

pub fn switchScene(self: *@This(), scene_index: usize) void {
    self.active_scene_index = scene_index;
}

pub fn rmScene(self: *@This(), scene_index: usize) void {
    assert(scene_index < self.scenes.len);
    assert(!self.scenes[scene_index].isNull());
    self.scenes[scene_index].setNull();
}

//
// This defines all state that is relevant to the user interface
//

scenes: []Scene,
active_scene_index: usize = 0,

video_source_providers: []VideoSourceProvider,
webcam_source_providers: []WebcamSourceProvider,
audio_source_providers: []AudioSourceProvider,

canvas_dimensions: Dimensions2D(u32),

audio_streams: []AudioStream,
video_streams: []VideoStream,

recording_context: RecordingContext,
screenshot_format: ImageFormat,
thread_util: ThreadUtilMonitor,
