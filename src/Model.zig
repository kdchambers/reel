// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const geometry = @import("geometry.zig");
const Dimensions2D = geometry.Dimensions2D;

const graphics = @import("graphics.zig");
const RGBA = graphics.RGBA;

const AudioSampleRingBuffer = @import("AudioSampleRingBuffer.zig");

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
    source_index: u16,
    provider_ref: VideoProviderRef,
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

//
// This defines all state that is relevant to the user interface
//

video_source_providers: []VideoSourceProvider,
webcam_source_providers: []WebcamSourceProvider,
audio_source_providers: []AudioSourceProvider,

canvas_dimensions: Dimensions2D(u32),

audio_streams: []AudioStream,
video_streams: []VideoStream,

recording_context: RecordingContext,
screenshot_format: ImageFormat,
