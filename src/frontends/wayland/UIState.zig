// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const geometry = @import("../../geometry.zig");
const Extent3D = geometry.Extent3D;

const widgets = @import("widgets.zig");
const Model = @import("../../Model.zig");
const VideoFormat = Model.VideoFormat;
const ImageFormat = Model.ImageFormat;

const mini_heap = @import("../../utils/mini_heap.zig");
const Index = mini_heap.Index;

const event_system = @import("event_system.zig");
const MouseEventEntry = event_system.MouseEventEntry;

//
// TODO: Use a comptime function to generate format_labels & image_format_labels
//

pub const format_labels = [_][]const u8{
    "MP4",
    "AVI",
};

pub const recording_quality_labels = [_][]const u8{
    "Low",
    "Medium",
    "High",
};

pub const image_format_labels = [_][]const u8{
    @tagName(ImageFormat.png),
    @tagName(ImageFormat.qoi),
};

pub const bitrate_value_labels = [10][]const u8{
    "1 MB",
    "1.5 MB",
    "2 MB",
    "3 MB",
    "4 MB",
    "5 MB",
    "7 MB",
    "8 MB",
    "10 MB",
    "12 MB",
};
pub const bitrate_value_label_max_length = 6;

pub const activity_labels = [_][]const u8{
    "Record",
    "Stream",
    "Screenshot",
};

pub const Activity = enum(u16) {
    record = 0,
    stream = 1,
    screenshot = 2,
};

pub const RegionAnchors = struct {
    left: f32 = -1.0,
    right: f32 = 1.0,
    top: f32 = -1.0,
    bottom: f32 = 1.0,

    pub inline fn width(self: @This()) f32 {
        return @abs(self.left - self.right);
    }

    pub inline fn height(self: @This()) f32 {
        return @abs(self.top - self.bottom);
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

pub const Edge = enum {
    top_right,
    top_left,
    bottom_right,
    bottom_left,
    left,
    right,
    top,
    bottom,
};

pub const EdgeRegions = struct {
    // top_right: Index(MouseEventEntry),
    // top_left: Index(MouseEventEntry),
    // bottom_right: Index(MouseEventEntry),
    // bottom_left: Index(MouseEventEntry),
    left: Index(MouseEventEntry),
    right: Index(MouseEventEntry),
    top: Index(MouseEventEntry),
    bottom: Index(MouseEventEntry),

    pub fn fromExtent(self: *@This(), extent: Extent3D(f32), border_h: f32, border_v: f32) void {
        const left_extent = Extent3D(f32){
            .x = extent.x,
            .y = extent.y,
            .z = extent.z,
            .width = border_h,
            .height = extent.height,
        };
        const right_extent = Extent3D(f32){
            .x = extent.x + extent.width - border_h,
            .y = extent.y,
            .z = extent.z,
            .width = border_h,
            .height = extent.height,
        };
        const top_extent = Extent3D(f32){
            .x = extent.x + border_h,
            .y = extent.y - (extent.height - border_v),
            .z = extent.z,
            .width = extent.width - (border_h * 2.0),
            .height = border_v,
        };
        const bottom_extent = Extent3D(f32){
            .x = extent.x + border_h,
            .y = extent.y,
            .z = extent.z,
            .width = extent.width - (border_h * 2.0),
            .height = border_v,
        };

        self.left = event_system.writeMouseEventSlot(left_extent, .{});
        self.right = event_system.writeMouseEventSlot(right_extent, .{});
        self.top = event_system.writeMouseEventSlot(top_extent, .{});
        self.bottom = event_system.writeMouseEventSlot(bottom_extent, .{});
    }

    pub fn edgeClicked(self: @This()) ?Edge {
        // const top_right_state = self.top_right.getPtr().state;
        // const top_left_state = self.top_left.getPtr().state;
        // const bottom_right_state = self.bottom_right.getPtr().state;
        // const bottom_left_state = self.bottom_left.getPtr().state;
        const left_state = self.left.getPtr().state;
        const right_state = self.right.getPtr().state;
        const top_state = self.top.getPtr().state;
        const bottom_state = self.bottom.getPtr().state;

        // self.top_right.getPtr().state.clear();
        // self.top_left.getPtr().state.clear();
        // self.bottom_right.getPtr().state.clear();
        // self.bottom_left.getPtr().state.clear();
        self.left.getPtr().state.clear();
        self.right.getPtr().state.clear();
        self.top.getPtr().state.clear();
        self.bottom.getPtr().state.clear();

        // if (top_right_state.left_click_press)
        //     return .top_right;
        // if (top_left_state.left_click_press)
        //     return .top_left;
        // if (bottom_right_state.left_click_press)
        //     return .bottom_right;
        // if (bottom_left_state.left_click_press)
        //     return .bottom_left;
        if (left_state.left_click_press)
            return .left;
        if (right_state.left_click_press)
            return .right;
        if (top_state.left_click_press)
            return .top;
        if (bottom_state.left_click_press)
            return .bottom;
        return null;
    }
};

const SourceEntry = struct {
    remove_icon: widgets.IconButton,
};

pub const quality_labels = [_][]const u8{ "low", "medium", "high" };

window_decoration_requested: bool,
window_region: RegionAnchors,

open_sidemenu_button: widgets.IconButton,
open_settings_button: widgets.IconButton,
add_source_button: widgets.IconButton,

close_app_button: widgets.IconButton,

select_video_source_popup: widgets.ListSelectPopup,
select_webcam_source_popup: widgets.ListSelectPopup,

source_provider_list: widgets.CategoryList,

activity_section: widgets.TabbedSection,
activity_start_button: widgets.Button,

record_format_selector: widgets.Selector,
record_quality_selector: widgets.Selector,
record_bitrate_slider: widgets.Slider,

scene_volume_level: widgets.AudioVolumeLevelHorizontal,

scene_selector: widgets.Dropdown,
// add_scene_button: widgets.IconButton,

// add_scene_popup_state: enum { closed, open },

video_source_mouse_edge_buffer: [2]EdgeRegions,
video_source_mouse_event_buffer: [2]Index(MouseEventEntry),
video_source_mouse_event_count: u32,

video_source_entry_buffer: [16]SourceEntry,

add_source_state: enum {
    closed,
    select_source_provider,
    select_source,
    select_webcam,
},

sidebar_state: enum { closed, open },

audio_source_spectogram: widgets.AudioSpectogram,
audio_volume_level: widgets.AudioVolumeLevelHorizontal,

audio_source_mel_bins: []f32,
