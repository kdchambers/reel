// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const geometry = @import("geometry.zig");
const Dimensions2D = geometry.Dimensions2D;

const graphics = @import("graphics.zig");
const RGB = graphics.RGB;

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
};

pub const VideoQuality = enum(u8) {
    low,
    medium,
    high,
};

pub const RecordingContext = struct {
    const State = enum {
        idle,
        recording,
        paused,
    };

    format: VideoFormat,
    quality: VideoQuality,
    start: i126,
    duration: u64,
    video_streams: []VideoStream,
    audio_streams: []AudioStream,
    state: State = .idle,
};

pub const VideoFrame = struct {
    pixels: [*]RGB(u8),
    dimensions: Dimensions2D(u16),
};

//
// This defines all state that is relevant to the user interface
//

audio_input_samples: ?[]i16,
audio_input_volume_db: f32,
desktop_capture_frame: ?VideoFrame,
recording_context: RecordingContext,
