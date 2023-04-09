// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const geometry = @import("geometry.zig");
const Dimensions2D = geometry.Dimensions2D;

const graphics = @import("graphics.zig");
const RGBA = graphics.RGBA;

const AudioSampleRingBuffer = @import("AudioSampleRingBuffer.zig");

pub const VideoSource = enum(u8) {
    desktop,
    webcam,
};

pub const VideoStream = struct {
    source: VideoSource,
    index: u8,
};

pub const AudioStream = struct {
    index: u8,
};

pub const VideoFormat = enum(u8) {
    mp4,
    avi,
    mkv,
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
        recording,
        paused,
    };

    format: VideoFormat,
    quality: VideoQuality,
    start: i128,
    video_streams: []VideoStream,
    audio_streams: []AudioStream,
    state: State = .idle,
};

pub const VideoFrame = struct {
    index: u64,
    pixels: [*]const RGBA(u8),
    dimensions: Dimensions2D(u32),
};

//
// This defines all state that is relevant to the user interface
//

input_audio_buffer: AudioSampleRingBuffer,
audio_input_volume_db: f32,
desktop_capture_frame: ?VideoFrame,
recording_context: RecordingContext,
