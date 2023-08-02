// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const Model = @import("../Model.zig");
const UIState = @import("wayland/UIState.zig");
const audio_utils = @import("wayland/audio.zig");
const utils = @import("../utils.zig");
const math = utils.math;
const Timer = utils.Timer;
const Profiler = utils.Profiler;

const wayland_core = @import("../wayland_core.zig");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;

var cursor_theme: *wl.CursorTheme = undefined;
var cursor: *wl.Cursor = undefined;
var cursor_surface: *wl.Surface = undefined;

// Called every time the compositor is ready to accept a new frame
var frame_callback: *wl.Callback = undefined;
var xdg_toplevel: *xdg.Toplevel = undefined;
var xdg_surface: *xdg.Surface = undefined;
var surface: *wl.Surface = undefined;

pub const FrameTickCallbackFn = fn (frame_index: u32) void;
pub var frame_listener_callbacks_count: usize = 0;
pub var frame_listener_callbacks: [10]*const FrameTickCallbackFn = undefined;

pub fn addOnFrameCallback(callback: *const FrameTickCallbackFn) void {
    frame_listener_callbacks[frame_listener_callbacks_count] = callback;
    frame_listener_callbacks_count += 1;
}

const layout_1920x1080 = @import("wayland/layouts/1920x1080.zig");

const geometry = @import("../geometry.zig");
const Dimensions2D = geometry.Dimensions2D;
const Extent2D = geometry.Extent2D;
const Extent3D = geometry.Extent3D;
const Coordinates2D = geometry.Coordinates2D;
const Coordinates3D = geometry.Coordinates3D;
const ScaleFactor2D = geometry.ScaleFactor2D;
const ui_layer = geometry.ui_layer;

const mini_heap = @import("../utils/mini_heap.zig");

const event_system = @import("wayland/event_system.zig");
const MouseEventEntry = event_system.MouseEventEntry;

const audio = @import("../audio_source.zig");

const graphics = @import("../graphics.zig");
const RGBA = graphics.RGBA(u8);
const RGB = graphics.RGB(u8);

const renderer = @import("../renderer.zig");

const widgets = @import("wayland/widgets.zig");
const Button = widgets.Button;
const IconButton = widgets.IconButton;
const CloseButton = widgets.CloseButton;
const Checkbox = widgets.Checkbox;
const Dropdown = widgets.Dropdown;
const Selector = widgets.Selector;
const TabbedSection = widgets.TabbedSection;

const app_core = @import("../app_core.zig");
const CoreUpdateDecoder = app_core.UpdateDecoder;
const CoreRequestEncoder = app_core.CoreRequestEncoder;
const CoreRequestDecoder = app_core.CoreRequestDecoder;

var ui_state: UIState = undefined;

const StreamDragContext = struct {
    start_coordinates: Coordinates2D(u16),
    start_mouse_coordinates: Coordinates2D(u16),
    mouse_event_slot_index: mini_heap.Index(MouseEventEntry),
    source_index: u16,
};
var stream_drag_context: ?StreamDragContext = null;

const SourceResizeContext = struct {
    edge: UIState.Edge,
    //
    // Relative value in pixels from the start edge
    //
    start_value: f32,
    source_index: u16,
    start_mouse_value: f32,
};
var source_resize_drag_context: ?SourceResizeContext = null;

const CursorState = enum {
    normal,
    pointer,
};

var loaded_cursor: CursorState = .normal;

const XCursor = struct {
    const arrow = "arrow";
    const hidden = "hidden";
    const left_ptr = "left_ptr";
    const text = "text";
    const xterm = "xterm";
    const hand = "hand";
    const link = "link";
    const hand1 = "hand1";
    const hand2 = "hand2";
    const move = "move";
    const fleur = "fleur";
    const grabbing = "grabbing";
    const pointer = "pointer";
    const openhand = "openhand";
    const pointer_move = "pointer-move";
    const top_left_corner = "top_left_corner";
    const top_right_corner = "top_right_corner";
    const bottom_left_corner = "bottom_left_corner";
    const bottom_right_corner = "bottom_right_corner";
    const left_side = "left_side";
    const right_side = "right_side";
    const top_side = "top_side";
    const bottom_side = "bottom_side";
};

/// Wayland uses linux' input-event-codes for keys and buttons. When a mouse button is
/// clicked one of these will be sent with the event.
/// https://wayland-book.com/seat/pointer.html
/// https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h
pub const MouseButton = enum(i32) {
    left = 0x110,
    right = 0x111,
    middle = 0x112,
    _,
};

pub const ButtonClicked = enum(u16) {
    none,
    right,
    middle,
    left,
};

const decoration_height_pixels = 32.0;

var is_draw_required: bool = true;
var is_render_requested: bool = true;

/// Is set to true when the first draw is complete. Some widgets require being drawn
/// before they can be updated
var have_drawn: bool = false;

/// Set when command buffers need to be (re)recorded. The following will cause that to happen
///   1. First command buffer recording
///   2. Screen resized
///   3. Push constants need to be updated
///   4. Number of vertices to be drawn has changed
var is_record_requested: bool = true;

var record_button_color_normal = RGBA{ .r = 15, .g = 15, .b = 15 };
var record_button_color_hover = RGBA{ .r = 25, .g = 25, .b = 25 };

const window_title = "reel";

pub var mouse_coordinates: geometry.Coordinates2D(f64) = undefined;

const initial_screen_dimensions = struct {
    const width = 1280;
    const height = 840;
};

pub var screen_dimensions: geometry.Dimensions2D(u32) = .{
    .width = initial_screen_dimensions.width,
    .height = initial_screen_dimensions.height,
};

pub var screen_scale = geometry.ScaleFactor2D(f32){
    .horizontal = 2.0 / @as(f32, initial_screen_dimensions.width),
    .vertical = 2.0 / @as(f32, initial_screen_dimensions.height),
};

pub var pending_swapchain_images_count: u32 = 1;
pub var frame_index: u32 = 0;

pub var is_mouse_in_screen: bool = true;

var framebuffer_resized: bool = false;

pub var button_clicked: ButtonClicked = .none;
pub var button_state: wl.Pointer.ButtonState = undefined;
pub var is_mouse_moved: bool = false;

var is_shutdown_requested: bool = false;

var allocator_ref: std.mem.Allocator = undefined;
var request_encoder: CoreRequestEncoder = .{};

var source_provider_label_buffer: [4][]const u8 = undefined;

pub const InitError = error{
    FontInitFail,
    InitializeEventSystemFail,
    WaylandClientInitFail,
    VulkanRendererInitFail,
    VulkanRendererCommitTextureFail,
    FontPenInitFail,
    AudioInputInitFail,
    TextureAtlasInitFail,
    OutOfMemory,
    LoadAssetFail,
};

pub const UpdateError = error{ VulkanRendererRenderFrameFail, UserInterfaceDrawFail };

var last_recording_state: Model.RecordingContext.State = .idle;
var last_preview_frame: u64 = 0;

var rendered_frame_count: u64 = 0;
var rendering_start: i128 = 0;

const ProfileTag = enum(u16) {
    frontend_update,
    render,
    draw,
    record_commands,
    mouse_input,
};
var profiler: Profiler(true, ProfileTag) = undefined;

pub inline fn requestDraw() void {
    is_draw_required = true;
}

pub inline fn requestRender() void {
    is_render_requested = true;
}

pub inline fn leftClickInFrame() bool {
    return button_state == .pressed;
}

pub fn init(allocator: std.mem.Allocator) !void {
    allocator_ref = allocator;

    ui_state.window_decoration_requested = true;

    ui_state.add_source_state = .closed;
    ui_state.video_source_mouse_event_count = 0;
    ui_state.sidebar_state = .closed;
    // ui_state.add_scene_popup_state = .closed;

    initWaylandClient() catch return error.WaylandClientInitFail;

    event_system.init() catch |err| {
        std.log.err("Failed to initialize the event system. Error: {}", .{err});
        return error.InitializeEventSystemFail;
    };

    profiler.init();

    renderer.init(
        allocator,
        @ptrCast(wayland_core.display),
        @ptrCast(surface),
        screen_dimensions,
    ) catch |err| {
        std.log.err("Failed to initialize vulkan renderer. Error: {}", .{err});
        return error.VulkanRendererInitFail;
    };
    errdefer renderer.deinit();

    ui_state.window_region.left = -1.0;
    ui_state.window_region.right = 1.0;
    ui_state.window_region.bottom = 1.0;
    ui_state.window_region.top = -1.0;

    ui_state.close_app_button.init();
    ui_state.close_app_button.on_hover_background_color = RGBA.fromInt(0, 0, 0, 20);
    ui_state.close_app_button.on_hover_icon_color = RGBA.black;
    ui_state.close_app_button.background_color = RGBA.transparent;
    ui_state.close_app_button.icon_color = RGBA.black;
    ui_state.close_app_button.icon = .close_32px;

    ui_state.open_settings_button.init();
    ui_state.open_settings_button.on_hover_background_color = RGBA{ .r = 255, .g = 255, .b = 255, .a = 20 };
    ui_state.open_settings_button.on_hover_icon_color = RGBA.white;
    ui_state.open_settings_button.background_color = RGBA.transparent;
    ui_state.open_settings_button.icon_color = RGBA{ .r = 202, .g = 202, .b = 202, .a = 255 };
    ui_state.open_settings_button.icon = .settings_32px;

    ui_state.open_sidemenu_button.init();
    ui_state.open_sidemenu_button.on_hover_icon_color = RGBA.white;
    ui_state.open_sidemenu_button.background_color = RGBA.fromInt(36, 39, 47, 255);
    ui_state.open_sidemenu_button.icon_color = RGBA{ .r = 202, .g = 202, .b = 202, .a = 255 };
    ui_state.open_sidemenu_button.icon = .arrow_back_32px;
    ui_state.open_sidemenu_button.on_hover_background_color = ui_state.open_sidemenu_button.background_color;

    ui_state.add_source_button.init();
    ui_state.add_source_button.on_hover_background_color = RGBA{ .r = 255, .g = 255, .b = 255, .a = 20 };
    ui_state.add_source_button.on_hover_icon_color = RGBA.white;
    ui_state.add_source_button.background_color = RGBA.transparent;
    ui_state.add_source_button.icon_color = RGBA{ .r = 202, .g = 202, .b = 202, .a = 255 };
    ui_state.add_source_button.icon = .add_circle_24px;

    ui_state.select_video_source_popup.init();
    ui_state.select_video_source_popup.border_color = RGBA.fromInt(0, 0, 0, 255);
    ui_state.select_video_source_popup.background_color = RGBA.fromInt(28, 30, 35, 255);
    ui_state.select_video_source_popup.entry_background_color = RGBA.transparent;
    ui_state.select_video_source_popup.entry_background_hovered_color = RGBA.fromInt(0, 0, 0, 50);
    ui_state.select_video_source_popup.title = "Select Display";

    ui_state.select_webcam_source_popup.init();
    ui_state.select_webcam_source_popup.border_color = RGBA.fromInt(0, 0, 0, 255);
    ui_state.select_webcam_source_popup.background_color = RGBA.fromInt(28, 30, 35, 255);
    ui_state.select_webcam_source_popup.entry_background_color = RGBA.transparent;
    ui_state.select_webcam_source_popup.entry_background_hovered_color = RGBA.fromInt(0, 0, 0, 50);
    ui_state.select_webcam_source_popup.title = "Webcam Devices";

    ui_state.activity_section.init(&UIState.activity_labels);

    ui_state.activity_start_button.init();

    ui_state.scene_volume_level.init();

    ui_state.record_format_selector.init();
    ui_state.record_format_selector.labels = &UIState.format_labels;
    ui_state.record_format_selector.background_color = RGBA.fromInt(66, 66, 66, 255);
    ui_state.record_format_selector.border_color = RGBA.fromInt(166, 166, 166, 255);
    ui_state.record_format_selector.active_background_color = RGBA.fromInt(40, 40, 40, 255);
    ui_state.record_format_selector.hovered_background_color = RGBA.fromInt(40, 40, 40, 255);

    ui_state.record_quality_selector.init();
    ui_state.record_quality_selector.labels = &UIState.recording_quality_labels;
    ui_state.record_quality_selector.background_color = RGBA.fromInt(66, 66, 66, 255);
    ui_state.record_quality_selector.border_color = RGBA.fromInt(166, 166, 166, 255);
    ui_state.record_quality_selector.active_background_color = RGBA.fromInt(40, 40, 40, 255);
    ui_state.record_quality_selector.hovered_background_color = RGBA.fromInt(40, 40, 40, 255);

    ui_state.record_bitrate_slider.init();
    ui_state.record_bitrate_slider.background_color = RGBA.fromInt(57, 59, 63, 255);
    ui_state.record_bitrate_slider.knob_outer_color = RGBA.fromInt(220, 220, 220, 255);
    ui_state.record_bitrate_slider.knob_inner_color = RGBA.fromInt(17, 20, 26, 255);
    ui_state.record_bitrate_slider.label_buffer = &UIState.bitrate_value_labels;
    ui_state.record_bitrate_slider.title = "Bit Rate";
    ui_state.record_bitrate_slider.active_index = 7;

    ui_state.source_provider_list.init();
    ui_state.source_provider_list.title = "Source Providers";
    ui_state.source_provider_list.categories = &[_][]const u8{ "Screen Capture", "Webcam", "Audio Input" };
    ui_state.source_provider_list.entry_labels = &[_][]const u8{};
    ui_state.source_provider_list.entry_categories = undefined;
    ui_state.source_provider_list.label_background = RGBA.transparent;
    ui_state.source_provider_list.background_color = RGBA.fromInt(28, 30, 35, 255);
    ui_state.source_provider_list.label_background_hovered = RGBA.fromInt(0, 0, 0, 50);

    for (&ui_state.video_source_entry_buffer) |*entry| {
        entry.remove_icon.init();
        entry.remove_icon.icon_color = RGBA.fromInt(220, 220, 220, 255);
        entry.remove_icon.on_hover_icon_color = RGBA.white;
        entry.remove_icon.background_color = RGBA.transparent;
        entry.remove_icon.on_hover_background_color = RGBA.fromInt(0, 0, 0, 30);
        entry.remove_icon.icon = .delete_16px;
    }

    ui_state.scene_selector.init();
    ui_state.scene_selector.background_color = RGBA.fromInt(57, 59, 63, 255);
    ui_state.scene_selector.background_color_hovered = RGBA.fromInt(77, 79, 83, 255);
    ui_state.scene_selector.accent_color = RGBA.fromInt(220, 220, 220, 255);

    // ui_state.add_scene_button.init();
    // ui_state.add_scene_button.on_hover_icon_color = RGBA.white;
    // ui_state.add_scene_button.background_color = RGBA.fromInt(36, 39, 47, 255);
    // ui_state.add_scene_button.icon_color = RGBA.fromInt(200, 200, 200, 255);
    // ui_state.add_scene_button.icon = .add_circle_24px;
    // ui_state.add_scene_button.on_hover_background_color = ui_state.add_scene_button.background_color;

    //
    // TODO: Don't hardcode bin count
    //
    ui_state.audio_source_mel_bins = allocator.alloc(f32, 64) catch return error.OutOfMemory;
    math.fftInitUnityTable(&audio_utils.unity_table);
}

fn processWidgets(model: *const Model) !void {
    for (ui_state.video_source_mouse_event_buffer[0..ui_state.video_source_mouse_event_count], 0..) |slot, i| {
        const state_copy = slot.get().state;
        slot.getPtr().state.clear();
        if (state_copy.left_click_press) {
            stream_drag_context = .{
                .start_coordinates = renderer.sourceRelativePlacement(@intCast(i)),
                .start_mouse_coordinates = .{
                    .x = @intFromFloat(@floor(mouse_coordinates.x)),
                    .y = @intFromFloat(@floor(mouse_coordinates.y)),
                },
                .mouse_event_slot_index = slot,
                .source_index = @intCast(i),
            };
        }
    }

    {
        const mouse_x_coordinate: f32 = @as(f32, @floatCast(mouse_coordinates.x)) * screen_scale.horizontal;
        const response = ui_state.record_bitrate_slider.update(mouse_x_coordinate, button_state == .pressed, screen_scale);
        if (response.visual_change or response.active_index != null)
            is_render_requested = true;
    }

    if (model.audio_stream_blocks.len() != 0) {
        ui_state.scene_volume_level.update(model.audio_stream_blocks.ptrFromIndex(0).volume_db, screen_scale);
    }

    {
        const response = ui_state.record_format_selector.update();
        if (response.visual_change)
            is_render_requested = true;
        if (response.active_index) |active_index| {
            is_draw_required = true;
            request_encoder.write(.record_format_set) catch unreachable;
            request_encoder.writeInt(u16, active_index) catch unreachable;
        }
    }

    {
        const response = ui_state.record_quality_selector.update();
        if (response.visual_change)
            is_render_requested = true;
        if (response.active_index) |active_index| {
            is_draw_required = true;
            request_encoder.write(.record_quality_set) catch unreachable;
            request_encoder.writeInt(u16, active_index) catch unreachable;
        }
    }

    if (ui_state.sidebar_state == .open) {
        const active_scene_ptr = model.activeScenePtr();
        const video_stream_count: usize = active_scene_ptr.videoStreamCount();
        const source_entries = ui_state.video_source_entry_buffer[0..video_stream_count];
        for (source_entries, 0..) |*entry, i| {
            const entry_response = entry.remove_icon.update();
            if (entry_response.clicked) {
                request_encoder.write(.remove_source) catch unreachable;
                request_encoder.writeInt(u16, @as(u16, @intCast(i))) catch unreachable;
            }
            if (entry_response.modified)
                is_render_requested = true;
        }
    }

    //
    // TODO: This is kind of a hack. In this case this button isn't valid but still has a
    //       mouse event slot index that's pointing to another widgets mouse event. If it triggers
    //       it will update some random vertices and clear the hover state so that the widget it
    //       actually belongs to won't trigger an update. Come up with a proper way to invalid
    //       widgets that aren't redrawn so that updates are gauranteed to have no effect
    //
    if (screen_dimensions.width < 1200) {
        const response = ui_state.open_sidemenu_button.update();
        if (response.clicked) {
            switch (ui_state.sidebar_state) {
                .open => {
                    ui_state.sidebar_state = .closed;
                },
                .closed => {
                    ui_state.sidebar_state = .open;
                },
            }
            is_draw_required = true;
        }
        if (response.modified)
            is_render_requested = true;
    }

    {
        const result = ui_state.open_settings_button.update();
        if (result.clicked)
            std.log.info("Settings button clicked", .{});
        if (result.modified)
            is_render_requested = true;
    }

    {
        const response = ui_state.activity_section.update();
        if (response.visual_change)
            is_render_requested = true;
        if (response.tab_index != null)
            is_draw_required = true;
    }

    {
        const response = ui_state.activity_start_button.update();
        if (response.clicked) {
            switch (@as(UIState.Activity, @enumFromInt(ui_state.activity_section.active_index))) {
                .record => {
                    switch (model.recording_context.state) {
                        .idle => request_encoder.write(.record_start) catch unreachable,
                        .paused => request_encoder.write(.record_resume) catch unreachable,
                        .recording => request_encoder.write(.record_stop) catch unreachable,
                        else => {},
                    }
                },
                .stream => request_encoder.write(.stream_start) catch unreachable,
                .screenshot => request_encoder.write(.screenshot_do) catch unreachable,
            }
        }
        if (response.modified)
            is_render_requested = true;
    }

    switch (ui_state.add_source_state) {
        .closed => {},
        .select_source_provider => {
            const response = ui_state.source_provider_list.update();
            if (response.item_clicked) |item_index| {
                const video_source_range = model.video_source_providers.len;
                const webcam_source_range = video_source_range + model.webcam_source_providers.len;
                const audio_source_range = webcam_source_range + model.audio_source_providers.len;
                assert(item_index < audio_source_range);
                if (item_index < video_source_range) {
                    const selected_source_provider_ptr = &model.video_source_providers[item_index];
                    if (selected_source_provider_ptr.query_support) {
                        const sources = selected_source_provider_ptr.sources orelse unreachable;
                        for (sources, 0..) |source, source_index| {
                            ui_state.select_video_source_popup.label_buffer[source_index] = source.name;
                        }
                        ui_state.select_video_source_popup.label_count = @intCast(sources.len);
                        ui_state.add_source_state = .select_source;
                    } else {
                        //
                        // If sources for provider is null, that means that interspection and selecting
                        // a specific source from the client isn't supported. Instead we simply request
                        // *a* source from the provider which might be selected via an external interface
                        //
                        request_encoder.write(.screencapture_request_source) catch unreachable;
                        ui_state.add_source_state = .closed;
                    }
                    is_draw_required = true;
                } else if (item_index < webcam_source_range) {
                    // request_encoder.write(.webcam_add_source) catch unreachable;
                    // request_encoder.writeInt(u16, 0) catch unreachable;
                    ui_state.add_source_state = .select_webcam;
                    is_draw_required = true;
                } else if (item_index < audio_source_range) {
                    std.log.info("Audio source provider clicked", .{});
                } else unreachable;
            }
            if (response.closed) {
                assert(ui_state.add_source_state == .select_source_provider);
                ui_state.add_source_state = .closed;
                is_draw_required = true;
            }
        },
        .select_source => {
            const response = ui_state.select_video_source_popup.update();
            if (response.visual_change)
                is_render_requested = true;
            if (response.item_clicked) |item_index| {
                assert(item_index < model.video_source_providers[0].sources.?.len);
                request_encoder.write(.screencapture_add_source) catch unreachable;
                request_encoder.writeInt(u16, item_index) catch unreachable;
                ui_state.add_source_state = .closed;
                //
                // Close the righthand sidebar once we've finished adding a new source
                //
                ui_state.sidebar_state = .closed;
                is_draw_required = true;
            }
        },
        .select_webcam => {
            const response = ui_state.select_webcam_source_popup.update();
            if (response.visual_change)
                is_render_requested = true;
            if (response.item_clicked) |item_index| {
                assert(item_index < model.webcam_source_providers[0].sources.len);
                request_encoder.write(.webcam_add_source) catch unreachable;
                request_encoder.writeInt(u16, item_index) catch unreachable;
                ui_state.add_source_state = .closed;
                //
                // Close the righthand sidebar once we've finished adding a new source
                //
                ui_state.sidebar_state = .closed;
                is_draw_required = true;
            }
        },
    }

    {
        for (ui_state.video_source_mouse_edge_buffer[0..ui_state.video_source_mouse_event_count], 0..) |edges, i| {
            if (edges.edgeClicked()) |edge| {
                const relative_extent = renderer.sourceRelativeExtent(@intCast(i));
                switch (edge) {
                    .left => {
                        std.log.info("Left edge of source {d} clicked", .{i});
                        source_resize_drag_context = .{
                            .edge = .left,
                            .start_value = @floatFromInt(relative_extent.x),
                            .start_mouse_value = @as(f32, @floatCast(mouse_coordinates.x)),
                            .source_index = @intCast(i),
                        };
                    },
                    .right => {
                        std.log.info("Right edge of source {d} clicked", .{i});
                        source_resize_drag_context = .{
                            .edge = .right,
                            .start_value = @floatFromInt(relative_extent.x + relative_extent.width),
                            .start_mouse_value = @as(f32, @floatCast(mouse_coordinates.x)),
                            .source_index = @intCast(i),
                        };
                    },
                    .top => {
                        std.log.info("Top edge of source {d} clicked", .{i});
                        source_resize_drag_context = .{
                            .edge = .top,
                            .start_value = @fabs(@as(f32, @floatFromInt(relative_extent.y)) - @as(f32, @floatFromInt(relative_extent.height))),
                            .start_mouse_value = @floatCast(mouse_coordinates.y),
                            .source_index = @intCast(i),
                        };
                    },
                    .bottom => {
                        std.log.info("Bottom edge of source {d} clicked", .{i});
                        source_resize_drag_context = .{
                            .edge = .bottom,
                            .start_value = @floatFromInt(relative_extent.y),
                            .start_mouse_value = @as(f32, @floatCast(mouse_coordinates.y)),
                            .source_index = @intCast(i),
                        };
                    },
                    else => unreachable,
                }
            }
        }
    }

    {
        const response = ui_state.add_source_button.update();
        if (response.clicked) {
            assert(ui_state.sidebar_state == .open);
            ui_state.add_source_state = switch (ui_state.add_source_state) {
                .closed => .select_source_provider,
                else => .closed,
            };
            is_draw_required = true;
        }
        if (response.modified)
            is_render_requested = true;
    }

    {
        const response = ui_state.scene_selector.update();
        if (response.visual_change) {
            is_render_requested = true;
        }
        if (response.active_index) |scene_index| {
            request_encoder.write(.scene_set_active) catch unreachable;
            request_encoder.writeInt(u16, scene_index) catch unreachable;
        }
        if (response.redraw) {
            is_draw_required = true;
        }
    }

    // {
    //     const response = ui_state.add_scene_button.update();
    //     if (response.clicked) {
    //         std.log.info("Adding scene..", .{});
    //         ui_state.add_scene_popup_state = .open;
    //         is_draw_required = true;
    //     }
    //     if (response.modified)
    //         is_render_requested = true;
    // }
}

pub fn update(model: *const Model, core_updates: *CoreUpdateDecoder) UpdateError!CoreRequestDecoder {
    request_encoder.used = 0;

    profiler.reset();
    _ = profiler.push(.frontend_update);

    while (core_updates.next()) |core_update| {
        switch (core_update) {
            .video_source_list_modified, .scene_active_changed => is_draw_required = true,
            .source_provider_list_modified => syncSourceProviders(model),
            .scene_list_modified => reloadSceneList(model),
        }
    }

    if (ui_state.close_app_button.update().clicked) {
        request_encoder.write(.core_shutdown) catch unreachable;
        return request_encoder.decoder();
    }

    if (have_drawn)
        try processWidgets(model);

    if (model.video_stream_blocks.len() != 0)
        is_render_requested = true;

    if (model.recording_context.state != last_recording_state) {
        last_recording_state = model.recording_context.state;
        is_draw_required = true;
    }

    if (is_shutdown_requested) {
        request_encoder.write(.core_shutdown) catch unreachable;
        return request_encoder.decoder();
    }

    if (framebuffer_resized) {
        framebuffer_resized = false;
        renderer.resizeSwapchain(screen_dimensions) catch |err| {
            std.log.err("Failed to recreate swapchain. Error: {}", .{err});
        };
        is_draw_required = true;
    }

    _ = profiler.push(.mouse_input);

    const mouse_input_timer = Timer.now();
    const mouse_position = mouseCoordinatesNDCR();
    switch (button_clicked) {
        .left => event_system.handleMouseClick(&mouse_position, .left, button_state),
        .right => event_system.handleMouseClick(&mouse_position, .right, button_state),
        .middle => event_system.handleMouseClick(&mouse_position, .middle, button_state),
        else => {},
    }
    button_clicked = .none;

    if (is_mouse_moved) {
        is_mouse_moved = false;
        const changes = event_system.handleMouseMovement(&mouse_position);
        if (changes.hover_enter and loaded_cursor != .pointer)
            setCursorState(.pointer);
        if (changes.hover_exit and loaded_cursor != .normal)
            setCursorState(.normal);
    }
    _ = profiler.pop(.mouse_input);
    mouse_input_timer.durationLog("Mouse input");

    if (is_draw_required) {
        _ = profiler.push(.draw);
        defer profiler.pop(.draw);

        is_draw_required = false;
        renderer.resetVertexBuffers();

        //
        // Redrawing invalidates all of the hover zones. This clears the internal
        // mouse events buffer
        //
        event_system.invalidateEvents();

        //
        // Reset cursor back to normal. Hoverzones have been invalidated
        //
        setCursorState(.normal);

        if (ui_state.window_decoration_requested) {
            //
            // We just reset the face_writer so a failure shouldn't really be possible
            // NOTE: This will modify ui_state.window_region to make sure we don't
            //       draw over the window decoration
            //
            drawWindowDecoration() catch unreachable;
        }

        //
        // Switch here based on screen dimensions
        //
        layout_1920x1080.draw(
            model,
            &ui_state,
            screen_scale,
        ) catch |err| {
            std.log.info("Failed to draw ui. Error: {}", .{err});
            return error.UserInterfaceDrawFail;
        };

        have_drawn = true;

        is_record_requested = true;
    } else {
        layout_1920x1080.update(
            model,
            &ui_state,
            screen_scale,
        ) catch return error.UserInterfaceDrawFail;
    }

    if (is_record_requested) {
        is_record_requested = false;

        _ = profiler.push(.record_commands);
        renderer.recordDrawCommands() catch return error.UserInterfaceDrawFail;
        profiler.pop(.record_commands);

        is_render_requested = true;
    }

    if (pending_swapchain_images_count > 0) {
        if (is_render_requested) {
            is_render_requested = false;
            pending_swapchain_images_count -= 1;

            if (rendering_start == 0)
                rendering_start = std.time.nanoTimestamp();

            _ = profiler.push(.render);
            renderer.renderFrame() catch |err| {
                switch (err) {
                    error.SwapchainOutdated => renderer.resizeSwapchain(screen_dimensions) catch return error.VulkanRendererRenderFrameFail,
                    else => return error.VulkanRendererRenderFrameFail,
                }
            };
            profiler.pop(.render);

            rendered_frame_count += 1;
        }
    }

    event_system.mouse_click_coordinates = null;
    profiler.pop(.frontend_update);

    profiler.log(0, 0, std.time.us_per_ms * 1);

    return request_encoder.decoder();
}

pub fn deinit() void {
    std.log.info("wayland deinit", .{});

    frame_callback.destroy();
    cursor_surface.destroy();
    xdg_surface.destroy();

    const current_time_ns = std.time.nanoTimestamp();
    const rendering_duration = @as(u64, @intCast(current_time_ns - rendering_start));
    const rendering_duration_seconds = @as(f32, @floatFromInt(rendering_duration)) / std.time.ns_per_s;
    const frames_rendered_per_second = @as(f32, @floatFromInt(rendered_frame_count)) / rendering_duration_seconds;
    std.log.info("wayland fps: {d}", .{frames_rendered_per_second});
}

fn syncSourceProviders(model: *const Model) void {
    var i: usize = 0;
    for (model.video_source_providers) |source_provider| {
        source_provider_label_buffer[i] = source_provider.name;
        ui_state.source_provider_list.entry_categories[i] = 0;
        i += 1;
    }
    for (model.webcam_source_providers) |source_provider| {
        source_provider_label_buffer[i] = source_provider.name;
        ui_state.source_provider_list.entry_categories[i] = 1;
        i += 1;
    }
    for (model.audio_source_providers) |source_provider| {
        source_provider_label_buffer[i] = source_provider.name;
        ui_state.source_provider_list.entry_categories[i] = 2;
        i += 1;
    }
    ui_state.source_provider_list.entry_labels = source_provider_label_buffer[0..i];
    const source_provider_count = model.video_source_providers.len + model.audio_source_providers.len + model.webcam_source_providers.len;
    assert(ui_state.source_provider_list.entry_labels.len == source_provider_count);

    for (model.webcam_source_providers[0].sources, 0..) |source, source_index| {
        ui_state.select_webcam_source_popup.label_buffer[source_index] = source.name;
    }
    ui_state.select_webcam_source_popup.label_count = @intCast(model.webcam_source_providers[0].sources.len);
}

pub fn reloadSceneList(model: *const Model) void {
    const scene_count: usize = model.scene_clusters.len();
    for (0..scene_count) |scene_i| {
        ui_state.scene_selector.model.labels[scene_i] = model.scene_clusters.ptrFromIndex(scene_i).name;
    }
    ui_state.scene_selector.model.label_count = scene_count;
}

inline fn setCursorState(cursor_state: CursorState) void {
    switch (cursor_state) {
        .pointer => {
            if (loaded_cursor == .pointer)
                return;

            cursor = cursor_theme.getCursor(XCursor.pointer) orelse blk: {
                break :blk cursor_theme.getCursor(XCursor.hand1) orelse {
                    std.log.info("Failed to load a cursor image for pointing", .{});
                    return;
                };
            };
            const image = cursor.images[0];
            const image_buffer = image.getBuffer() catch {
                std.log.warn("Failed to get cursor image buffer", .{});
                return;
            };
            cursor_surface.attach(image_buffer, 0, 0);
            cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            cursor_surface.commit();
            loaded_cursor = .pointer;
        },
        .normal => {
            if (loaded_cursor == .normal)
                return;
            cursor = cursor_theme.getCursor(XCursor.left_ptr).?;
            const image = cursor.images[0];
            const image_buffer = image.getBuffer() catch {
                std.log.warn("Failed to get cursor image buffer", .{});
                return;
            };
            cursor_surface.attach(image_buffer, 0, 0);
            cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            cursor_surface.commit();
            loaded_cursor = .normal;
        },
    }
}

fn drawWindowDecoration() !void {
    const height: f32 = decoration_height_pixels * screen_scale.vertical;
    {
        const background_color = RGB.fromInt(200, 200, 200);
        const extent = Extent3D(f32){
            .x = -1.0,
            .y = -1.0,
            .z = ui_layer.bottom,
            .width = 2.0,
            .height = height,
        };
        _ = renderer.drawQuad(extent, background_color.toRGBA(), .top_left);

        const button_width: f32 = 32.0 * screen_scale.horizontal;
        const button_height: f32 = 32.0 * screen_scale.vertical;
        const close_button_placement = Coordinates3D(f32){
            .x = 1.0 - button_width,
            .y = -1.0 + button_height,
            .z = ui_layer.middle,
        };
        ui_state.close_app_button.draw(close_button_placement, 0.0, screen_scale);

        const title_left_margin: f32 = 10.0 * screen_scale.horizontal;
        const window_title_extent = Extent3D(f32){
            .x = -1.0 + title_left_margin,
            .y = -1.0 + height,
            .z = ui_layer.middle,
            .width = 1.0,
            .height = height,
        };
        _ = renderer.drawText("Reel", window_title_extent, screen_scale, .medium, .regular, RGBA.black, .middle_left);
    }
    ui_state.window_region.top = -1.0 + height;
}

fn initWaylandClient() !void {
    surface = try wayland_core.compositor.createSurface();

    xdg_surface = try wayland_core.xdg_wm_base.getXdgSurface(surface);
    xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, surface);

    xdg_toplevel = try xdg_surface.getToplevel();
    xdg_toplevel.setListener(*bool, xdgToplevelListener, &is_shutdown_requested);

    xdg_toplevel.setTitle("Reel");

    var toplevel_decoration: *zxdg.ToplevelDecorationV1 = undefined;
    if (wayland_core.window_decorations_opt) |window_decorations| {
        toplevel_decoration = try window_decorations.getToplevelDecoration(xdg_toplevel);
        toplevel_decoration.setListener(*const void, toplevelDecorationListener, &{});
    }

    frame_callback = try surface.frame();
    frame_callback.setListener(*const void, frameListener, &{});

    wayland_core.pointer.setListener(*const void, pointerListener, &{});

    xdg_toplevel.setTitle(window_title);
    surface.commit();

    if (wayland_core.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    //
    // Load cursor theme
    //

    cursor_surface = try wayland_core.compositor.createSurface();

    const cursor_size = 24;
    cursor_theme = wl.CursorTheme.load("Adwaita", cursor_size, wayland_core.shared_memory) catch blk: {
        break :blk wl.CursorTheme.load(null, cursor_size, wayland_core.shared_memory) catch {
            return error.LoadCursorFail;
        };
    };
    cursor = cursor_theme.getCursor(XCursor.left_ptr).?;
}

fn toplevelDecorationListener(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, _: *const void) void {
    switch (event) {
        .configure => |configure| {
            switch (configure.mode) {
                .server_side => ui_state.window_decoration_requested = false,
                else => ui_state.window_decoration_requested = true,
            }
        },
    }
}

fn xdgSurfaceListener(xdg_surface_ref: *xdg.Surface, event: xdg.Surface.Event, surface_ref: *wl.Surface) void {
    switch (event) {
        .configure => |configure| {
            std.log.info("wayland_client: xdg_surface configure", .{});
            xdg_surface_ref.ackConfigure(configure.serial);
            surface_ref.commit();
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, close_requested: *bool) void {
    switch (event) {
        .configure => |configure| {
            if (configure.width > 0 and configure.width != screen_dimensions.width) {
                framebuffer_resized = true;
                screen_dimensions.width = @intCast(configure.width);
                screen_scale.horizontal = 2.0 / @as(f32, @floatFromInt(screen_dimensions.width));
            }
            if (configure.height > 0 and configure.height != screen_dimensions.height) {
                framebuffer_resized = true;
                screen_dimensions.height = @intCast(configure.height);
                screen_scale.vertical = 2.0 / @as(f32, @floatFromInt(screen_dimensions.height));
            }
            std.log.info("xdg_toplevel configure. Dimensions {d} x {d}", .{
                screen_dimensions.width,
                screen_dimensions.height,
            });
            frame_callback.destroy();
            frame_callback = surface.frame() catch |err| {
                std.log.err("Failed to create new wayland frame -> {}", .{err});
                return;
            };
            frame_callback.setListener(*const void, frameListener, &{});
        },
        .close => close_requested.* = true,
    }
}

fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, _: *const void) void {
    switch (event) {
        .done => {
            callback.destroy();
            frame_callback = surface.frame() catch |err| {
                std.log.err("Failed to create new wayland frame -> {}", .{err});
                assert(false);
                return;
            };
            frame_callback.setListener(*const void, frameListener, &{});

            for (frame_listener_callbacks[0..frame_listener_callbacks_count]) |user_callback| {
                user_callback(frame_index);
            }

            frame_index += 1;
            pending_swapchain_images_count += 1;
        },
    }
}

fn mouseCoordinatesNDCR() geometry.Coordinates2D(f64) {
    return .{
        .x = -1.0 + (mouse_coordinates.x * screen_scale.horizontal),
        .y = -1.0 + (mouse_coordinates.y * screen_scale.vertical),
    };
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, _: *const void) void {
    switch (event) {
        .enter => |enter| {
            is_mouse_in_screen = true;
            mouse_coordinates.x = enter.surface_x.toDouble();
            mouse_coordinates.y = enter.surface_y.toDouble();

            //
            // When mouse enters application surface, update the cursor image
            //
            const image = cursor.images[0];
            const image_buffer = image.getBuffer() catch return;
            cursor_surface.attach(image_buffer, 0, 0);
            wayland_core.pointer.setCursor(enter.serial, cursor_surface, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
            cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            cursor_surface.commit();
        },
        .leave => |leave| {
            _ = leave;
            is_mouse_in_screen = false;
            stream_drag_context = null;
        },
        .motion => |motion| {
            if (!is_mouse_in_screen)
                return;

            const motion_mouse_x = motion.surface_x.toDouble();
            const motion_mouse_y = motion.surface_y.toDouble();

            mouse_coordinates.x = motion_mouse_x;
            mouse_coordinates.y = motion_mouse_y;

            if (stream_drag_context) |drag| {
                const mouse_delta = Coordinates2D(i32){
                    .x = @as(i32, @intFromFloat(motion_mouse_x)) - @as(i32, @intCast(drag.start_mouse_coordinates.x)),
                    .y = @as(i32, @intCast(drag.start_mouse_coordinates.y)) - @as(i32, @intFromFloat(motion_mouse_y)),
                };
                const new_placement = Coordinates2D(u16){
                    .x = @intCast(@max(0, drag.start_coordinates.x + mouse_delta.x)),
                    .y = @intCast(@max(0, drag.start_coordinates.y + mouse_delta.y)),
                };
                renderer.moveSource(drag.source_index, new_placement);
                is_record_requested = true;
            }

            if (source_resize_drag_context) |resize_edge| {
                switch (resize_edge.edge) {
                    .left => {
                        // Needs to be a normalized value
                        const mouse_delta_x: f32 = @floatCast(motion_mouse_x - resize_edge.start_mouse_value);
                        renderer.moveEdgeLeft(resize_edge.source_index, resize_edge.start_value + mouse_delta_x);
                    },
                    .right => {
                        const mouse_delta_x: f32 = @floatCast(motion_mouse_x - resize_edge.start_mouse_value);
                        renderer.moveEdgeRight(resize_edge.source_index, resize_edge.start_value + mouse_delta_x);
                    },
                    .bottom => {
                        const mouse_delta_y: f32 = @floatCast(resize_edge.start_mouse_value - motion_mouse_y);
                        renderer.moveEdgeBottom(resize_edge.source_index, resize_edge.start_value + mouse_delta_y);
                    },
                    .top => {
                        const mouse_delta_y: f32 = @floatCast(resize_edge.start_mouse_value - motion_mouse_y);
                        renderer.moveEdgeTop(resize_edge.source_index, resize_edge.start_value + mouse_delta_y);
                    },
                    else => unreachable,
                }
                is_record_requested = true;
            }

            is_mouse_moved = true;
        },
        .button => |button| {
            if (!is_mouse_in_screen) {
                return;
            }

            if (mouse_coordinates.x < 0 or mouse_coordinates.y < 0)
                return;

            event_system.mouse_click_coordinates = .{
                .x = mouse_coordinates.x,
                .y = mouse_coordinates.y,
            };

            const mouse_button: MouseButton = @enumFromInt(button.button);
            button_clicked = .none;

            if (mouse_button == .left)
                button_clicked = .left;

            if (mouse_button == .right)
                button_clicked = .right;

            if (mouse_button == .middle)
                button_clicked = .middle;

            button_state = button.state;

            if (mouse_button == .left and button_state == .released) {
                if (stream_drag_context) |drag| {
                    const mouse_delta = Coordinates2D(i32){
                        .x = @as(i32, @intFromFloat(mouse_coordinates.x)) - @as(i32, @intCast(drag.start_mouse_coordinates.x)),
                        .y = @as(i32, @intCast(drag.start_mouse_coordinates.y)) - @as(i32, @intFromFloat(mouse_coordinates.y)),
                    };
                    const extent_ptr: *Extent2D(f32) = &drag.mouse_event_slot_index.getPtr().extent;
                    extent_ptr.x += @as(f32, @floatFromInt(mouse_delta.x)) * screen_scale.horizontal;
                    extent_ptr.y += -@as(f32, @floatFromInt(mouse_delta.y)) * screen_scale.vertical;
                    stream_drag_context = null;
                }

                if (source_resize_drag_context) |_| {
                    //
                    // TODO: Implement
                    //
                    source_resize_drag_context = null;
                }
            }

            std.log.info("Button mouse coordinates: {d}, {d}", .{
                mouse_coordinates.x,
                mouse_coordinates.y,
            });

            {
                const mouse_x: u16 = @intFromFloat(mouse_coordinates.x);
                const mouse_y: u16 = @intFromFloat(mouse_coordinates.y);

                std.log.info("Mouse coords: {d}, {d}. Screen {d}, {d}", .{
                    mouse_x,
                    mouse_y,
                    screen_dimensions.width,
                    screen_dimensions.height,
                });

                if (mouse_x > screen_dimensions.width or mouse_y > screen_dimensions.height)
                    return;

                const edge_threshold = 6;
                const max_width = screen_dimensions.width - edge_threshold;
                const max_height = screen_dimensions.height - edge_threshold;

                if (mouse_x < edge_threshold and mouse_y < edge_threshold) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .top_left);
                }

                if (mouse_x < edge_threshold and mouse_y > max_height) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .bottom_left);
                    return;
                }

                if (mouse_x > max_width and mouse_y < edge_threshold) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .top_right);
                    return;
                }

                if (mouse_x > max_width and mouse_y > max_height) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .bottom_right);
                    return;
                }

                if (mouse_x < edge_threshold) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .left);
                    return;
                }

                if (mouse_x > max_width) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .right);
                    return;
                }

                if (mouse_y <= edge_threshold) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .top);
                    return;
                }

                if (mouse_y >= max_height) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .bottom);
                    return;
                }
            }

            if (@as(u16, @intFromFloat(mouse_coordinates.y)) > screen_dimensions.height)
                return;

            if (@as(u16, @intFromFloat(mouse_coordinates.x)) > screen_dimensions.width)
                return;

            if (ui_state.window_decoration_requested and mouse_button == .left) {
                // Start interactive window move if mouse coordinates are in window decorations bounds
                if (@as(u32, @intFromFloat(mouse_coordinates.y)) <= decoration_height_pixels) {
                    xdg_toplevel.move(wayland_core.seat, button.serial);
                }
            }
        },
        .axis => |axis| std.log.info("Mouse: axis {} {}", .{ axis.axis, axis.value.toDouble() }),
        .frame => |frame| _ = frame,
        .axis_source => |axis_source| std.log.info("Mouse: axis_source {}", .{axis_source.axis_source}),
        .axis_stop => |axis_stop| _ = axis_stop,
        .axis_discrete => |_| std.log.info("Mouse: axis_discrete", .{}),
    }
}
