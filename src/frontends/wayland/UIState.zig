// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const widgets = @import("widgets.zig");
const Model = @import("../../Model.zig");
const VideoFormat = Model.VideoFormat;
const ImageFormat = Model.ImageFormat;

//
// TODO: Use a comptime function to generate format_labels & image_format_labels
//

pub const format_labels = [_][]const u8{
    @tagName(VideoFormat.mp4),
    @tagName(VideoFormat.avi),
    // @tagName(VideoFormat.mkv),
};

pub const image_format_labels = [_][]const u8{
    // @tagName(ImageFormat.bmp),
    // @tagName(ImageFormat.jpg),
    @tagName(ImageFormat.png),
    @tagName(ImageFormat.qoi),
};

pub const tab_headings = [_][]const u8{
    "RECORD",
    "SCREENSHOT",
    "STREAM",
};

pub const RegionAnchors = struct {
    left: f32 = -1.0,
    right: f32 = 1.0,
    top: f32 = -1.0,
    bottom: f32 = 1.0,

    pub inline fn width(self: @This()) f32 {
        return @fabs(self.left - self.right);
    }

    pub inline fn height(self: @This()) f32 {
        return @fabs(self.top - self.bottom);
    }
};

pub const quality_labels = [_][]const u8{ "low", "medium", "high" };

window_decoration_requested: bool,
window_region: RegionAnchors,

action_tab: widgets.TabbedSection,

record_button: widgets.Button,
record_format: widgets.Dropdown,
record_quality: widgets.Dropdown,

screenshot_button: widgets.Button,
screenshot_format: widgets.Dropdown,

preview_display_selector: widgets.Selector,

enable_preview_checkbox: widgets.Checkbox,
audio_input_spectogram: widgets.AudioSpectogram,
audio_volume_level: widgets.AudioVolumeLevelHorizontal,

audio_input_mel_bins: []f32,
