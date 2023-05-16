// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const geometry = @import("../../geometry.zig");
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
    "Record",
    "Screenshot",
    "Stream",
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

    pub inline fn toExtent(self: @This()) geometry.Extent2D(f32) {
        return .{
            .x = self.left,
            .y = self.bottom,
            .width = self.right - self.left,
            .height = self.bottom - self.top,
        };
    }
};

pub const quality_labels = [_][]const u8{ "low", "medium", "high" };

window_decoration_requested: bool,
window_region: RegionAnchors,

action_tab: widgets.TabbedSection,

record_button: widgets.Button,
record_format: widgets.Dropdown,
record_quality: widgets.Dropdown,

open_sidemenu_button: widgets.IconButton,
open_settings_button: widgets.IconButton,
add_source_button: widgets.IconButton,

select_source_provider_popup: widgets.ListSelectPopup,
select_video_source_popup: widgets.ListSelectPopup,

add_source_state: enum {
    closed,
    select_source_provider,
    select_source,
},

sidebar_state: enum { closed, settings_menu_open, help_menu_open, add_menu_open },

screenshot_button: widgets.Button,
screenshot_format: widgets.Dropdown,

audio_source_spectogram: widgets.AudioSpectogram,
audio_volume_level: widgets.AudioVolumeLevelHorizontal,

audio_source_mel_bins: []f32,
