// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const geometry = @import("../../geometry.zig");
const Extent3D = geometry.Extent3D;

const widgets = @import("widgets.zig");
const Model = @import("../../Model.zig");
const VideoFormat = Model.VideoFormat;
const ImageFormat = Model.ImageFormat;

const mini_heap = @import("mini_heap.zig");
const Index = mini_heap.Index;

const event_system = @import("event_system.zig");
const MouseEventEntry = event_system.MouseEventEntry;

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

pub const quality_labels = [_][]const u8{ "low", "medium", "high" };

window_decoration_requested: bool,
window_region: RegionAnchors,

open_sidemenu_button: widgets.IconButton,
open_settings_button: widgets.IconButton,
add_source_button: widgets.IconButton,

select_source_provider_popup: widgets.ListSelectPopup,
select_video_source_popup: widgets.ListSelectPopup,

activity_section: widgets.TabbedSection,

video_source_mouse_edge_buffer: [2]EdgeRegions,
video_source_mouse_event_buffer: [2]Index(MouseEventEntry),
video_source_mouse_event_count: u32,

add_source_state: enum {
    closed,
    select_source_provider,
    select_source,
},

sidebar_state: enum { closed, open },

audio_source_spectogram: widgets.AudioSpectogram,
audio_volume_level: widgets.AudioVolumeLevelHorizontal,

audio_source_mel_bins: []f32,
