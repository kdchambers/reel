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

pub const WebcamStream = struct {
    dimensions: geometry.Dimensions2D(u32),
    last_frame_index: u64,
    last_frame: [*]graphics.RGBA(u8),
};

//
// This defines all state that is relevant to the user interface
//

input_audio_buffer: AudioSampleRingBuffer,
audio_input_volume_db: f32,
desktop_capture_frame: ?VideoFrame,
recording_context: RecordingContext,
screenshot_format: ImageFormat,
webcam_stream: WebcamStream,

// Frame containing desktop screencapture + overlayed webcam
combined_frame: ?[]graphics.RGBA(u8),
