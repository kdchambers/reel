// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const widgets = @import("widgets.zig");
const Model = @import("../../Model.zig");
const VideoFormat = Model.VideoFormat;

pub const format_labels = [_][]const u8{
    //
    // TODO: Use a comptime function to generate format_labels
    //
    @tagName(VideoFormat.mp4),
    @tagName(VideoFormat.avi),
    @tagName(VideoFormat.mkv),
};

pub const quality_labels = [_][]const u8{ "low", "medium", "high" };

record_button: widgets.Button,
record_format: widgets.Dropdown,
record_quality: widgets.Dropdown,

enable_preview_checkbox: widgets.Checkbox,
audio_input_spectogram: widgets.AudioSpectogram,
audio_volume_level: widgets.AudioVolumeLevelHorizontal,

audio_input_mel_bins: []f32,
