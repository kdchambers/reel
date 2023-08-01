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

const BlockIndex = utils.mem.BlockIndex;
const ClusterIndex = utils.mem.ClusterIndex;
const BlockStableArray = utils.mem.BlockStableArray;
const ClusterArray = utils.mem.ClusterArray;

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
    const video_stream_count: usize = 16;
    const audio_stream_count: usize = 16;

    name: []const u8 = "",
    video_streams: [video_stream_count]BlockIndex = [1]BlockIndex{BlockIndex.invalid} ** video_stream_count,
    audio_streams: [audio_stream_count]BlockIndex = [1]BlockIndex{BlockIndex.invalid} ** audio_stream_count,

    pub inline fn appendVideoStreamID(self: *@This(), stream_id: BlockIndex) !usize {
        for (&self.video_streams, 0..) |*video_stream, stream_i| {
            if (video_stream.isNull()) {
                video_stream.* = stream_id;
                return stream_i;
            }
        }
        return error.VideoStreamLimitReached;
    }

    pub inline fn removeVideoStream(self: *@This(), index: usize) void {
        assert(!self.video_streams[index].isNull());
        self.video_streams[index].setNull();
    }

    pub inline fn removeAudioStream(self: *@This(), index: usize) void {
        assert(!self.audio_streams[index].isNull());
        self.audio_streams[index].setNull();
    }

    pub inline fn appendAudioStreamID(self: *@This(), stream_id: BlockIndex) !usize {
        for (&self.audio_streams, 0..) |*audio_stream, stream_i| {
            if (audio_stream.isNull()) {
                audio_stream.* = stream_id;
                return stream_i;
            }
        }
        return error.AudioStreamLimitReached;
    }

    pub inline fn videoStreamCount(self: @This()) usize {
        assert(!self.isNull());
        var valid_count: usize = 0;
        for (self.video_streams) |video_stream| {
            if (!video_stream.isNull()) {
                valid_count += 1;
            }
        }
        return valid_count;
    }

    pub inline fn audioStreamCount(self: @This()) usize {
        assert(!self.isNull());
        var valid_count: usize = 0;
        for (self.audio_streams) |audio_stream| {
            if (audio_stream != BlockIndex.invalid) {
                valid_count += 1;
            }
        }
        return valid_count;
    }

    pub inline fn isNull(self: @This()) bool {
        return self.name.len == 0;
    }

    pub inline fn setNull(self: *@This()) void {
        self.name = "";
        assert(self.isNull());
    }
};

pub fn addScene(self: *@This(), name: []const u8) !void {
    const scene: Scene = .{ .name = name };
    _ = self.scene_clusters.add(&scene) catch |err| return err;
}

pub fn removeScene(self: *@This(), scene_index: u16) void {
    //
    // We also need to remove all associated streams
    //
    const scene_ptr = scenePtrFromIndex(scene_index);
    for (scene_ptr.audio_streams) |*block_index| {
        self.audio_stream_blocks.remove(block_index);
        block_index = BlockIndex.invalid;
    }
    for (scene_ptr.video_streams) |*block_index| {
        self.video_stream_blocks.remove(block_index);
        block_index = BlockIndex.invalid;
    }
    self.scene_clusters.remove(scene_index);
}

pub inline fn activeScenePtr(self: @This()) *const Scene {
    return self.scenePtrFromIndex(self.active_scene_index);
}

pub inline fn activeScenePtrMut(self: @This()) *Scene {
    return self.scenePtrMutFromIndex(self.active_scene_index);
}

pub inline fn scenePtrMutFromIndex(self: @This(), scene_index: usize) *Scene {
    assert(scene_index < max_scene_count);
    var local_index: usize = scene_index;
    for (&self.scene_clusters.clusters) |*scene_cluster| {
        if (local_index < scene_cluster.len) {
            return scene_cluster.atPtr(local_index);
        }
        local_index -= scene_cluster.len;
    }
    unreachable;
}

pub inline fn scenePtrFromIndex(self: @This(), scene_index: usize) *const Scene {
    assert(scene_index < max_scene_count);
    var local_index: usize = scene_index;
    for (&self.scene_clusters.clusters) |*scene_cluster| {
        if (local_index < scene_cluster.len) {
            return scene_cluster.atPtr(local_index);
        }
        local_index -= scene_cluster.len;
    }
    unreachable;
}

pub inline fn videoStreamPtrFromBlockIndex(self: @This(), block_index: BlockIndex) *const VideoStream {
    return self.video_stream_blocks.blocks[block_index.block_i].ptrFromIndex(block_index.item_i);
}

pub inline fn videoStreamPtrMutFromBlockIndex(self: *@This(), block_index: BlockIndex) *VideoStream {
    return self.video_stream_blocks.blocks[block_index.block_i].ptrMutFromIndex(block_index.item_i);
}

pub fn audioStreamCount(self: *@This()) usize {
    const active_scene_ptr: *const Scene = self.activeScenePtr();
    return active_scene_ptr.audioStreamCount();
}

pub fn audioStreamAt(self: *@This(), index: usize) *AudioStream {
    const active_scene_ptr: *const Scene = self.activeScenePtr();
    assert(active_scene_ptr.audio_streams[index] != BlockIndex.invalid);
    return self.audio_stream_clusters.ptrFromIndex(active_scene_ptr.audio_streams[index]);
}

pub fn addVideoStream(self: *@This(), video_stream: *const VideoStream) !usize {
    const active_scene_ptr: *Scene = self.activeScenePtrMut();
    const block_index = self.video_stream_blocks.add(video_stream) catch return error.VideoStreamLimitReached;
    errdefer self.video_stream_blocks.remove(block_index);
    return active_scene_ptr.appendVideoStreamID(block_index) catch return error.VideoStreamLimitReached;
}

/// Add audio stream to the current active scene
/// audio_stream will be copied so does not need to be valid after this call
pub fn addAudioStream(self: *@This(), audio_stream: *const AudioStream) !usize {
    const active_scene_ptr: *Scene = self.activeScenePtrMut();
    const block_index = self.audio_stream_blocks.add(audio_stream) catch return error.AudioStreamLimitReached;
    errdefer self.audio_stream_blocks.remove(block_index);
    return active_scene_ptr.appendAudioStreamID(block_index) catch return error.AudioStreamLimitReached;
}

pub fn removeVideoStream(self: *@This(), stream_index: usize) void {
    assert(stream_index < Scene.video_stream_count);
    const active_scene_ptr: *Scene = self.activeScenePtrMut();
    const block_index: BlockIndex = active_scene_ptr.video_streams[stream_index];
    assert(!block_index.isNull());
    self.video_stream_blocks.remove(block_index);
    active_scene_ptr.removeVideoStream(stream_index);
}

pub fn removeAudioStream(self: *@This(), stream_index: usize) void {
    assert(stream_index < Scene.audio_stream_count);
    const active_scene_ptr: *Scene = self.activeScenePtrMut();
    const block_index: BlockIndex = active_scene_ptr.audio_streams[stream_index];
    assert(block_index != BlockIndex.invalid);
    self.audio_stream_blocks.remove(block_index);
    active_scene_ptr.removeAudioStream(stream_index);
}

pub inline fn switchScene(self: *@This(), scene_index: usize) void {
    self.active_scene_index = scene_index;
}

const max_video_stream_per_scene_count = 16;
const max_audio_stream_per_scene_count = 16;

const scene_video_steam_cluster_capacity = 4;
const scene_audio_steam_cluster_capacity = 4;

const scene_video_stream_cluster_count = @divExact(max_video_stream_per_scene_count, scene_video_steam_cluster_capacity);
const scene_audio_stream_cluster_count = @divExact(max_audio_stream_per_scene_count, scene_audio_steam_cluster_capacity);

const max_scene_count = 32;
const max_video_stream_count = 32;
const max_audio_stream_count = 32;

const audio_stream_block_capacity = 4;
const video_stream_block_capacity = 4;

const video_stream_block_count = @divExact(max_video_stream_count, video_stream_block_capacity);
const audio_stream_block_count = @divExact(max_audio_stream_count, audio_stream_block_capacity);

const scene_cluster_capacity = 8;
const scene_cluster_count = @divExact(max_scene_count, scene_cluster_capacity);

//
// This defines all state that is relevant to the user interface
//

scene_clusters: ClusterArray(Scene, scene_cluster_count, scene_cluster_capacity) = .{},
audio_stream_blocks: BlockStableArray(AudioStream, audio_stream_block_count, audio_stream_block_capacity) = .{},
video_stream_blocks: BlockStableArray(VideoStream, video_stream_block_count, video_stream_block_capacity) = .{},

active_scene_index: usize = 0,

video_source_providers: []VideoSourceProvider,
webcam_source_providers: []WebcamSourceProvider,
audio_source_providers: []AudioSourceProvider,

canvas_dimensions: Dimensions2D(u32),

recording_context: RecordingContext,
screenshot_format: ImageFormat,
thread_util: ThreadUtilMonitor,
