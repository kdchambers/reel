// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const graphics = @import("../../../graphics.zig");
const RGBA = graphics.RGBA(u8);
const RGB = graphics.RGB(u8);

const geometry = @import("../../../geometry.zig");
const ui_layer = geometry.ui_layer;
const Extent3D = geometry.Extent3D;
const Dimensions2D = geometry.Dimensions2D;
const Coordinates3D = geometry.Coordinates3D;
const ScaleFactor2D = geometry.ScaleFactor2D;

const ui_root = @import("../../wayland.zig");

const layout = @import("../layout.zig");
const Region = layout.Region;
const Placement = layout.Placement;

const renderer = @import("../../../renderer.zig");

const Model = @import("../../../Model.zig");
const UIState = @import("../UIState.zig");

const event_system = @import("../event_system.zig");

const sidebar_color = RGBA{ .r = 17, .g = 20, .b = 26, .a = 255 };
const window_color = RGBA.fromInt(28, 30, 35, 255);

pub fn update(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
) !void {
    _ = model;
    _ = ui_state;
    _ = screen_scale;
}

pub fn draw(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
) !void {
    const window = ui_state.window_region;

    var icon_bar_region: Region = .{};
    {
        icon_bar_region.anchor.left = window.left;
        icon_bar_region.anchor.bottom = window.bottom;
        icon_bar_region.height = window.height();
        icon_bar_region.width = 48.0 * screen_scale.horizontal;
        _ = renderer.drawQuad(icon_bar_region.toExtent(), sidebar_color, .bottom_left);

        {
            const placement = Coordinates3D(f32){
                .x = -1.0 + (8.0 * screen_scale.horizontal),
                .y = 1.0 - (10.0 * screen_scale.vertical),
                .z = ui_layer.middle,
            };
            const color = RGB{ .r = 202, .g = 202, .b = 202 };
            _ = renderer.drawIcon(placement, .help_32px, screen_scale, color.toRGBA(), .bottom_left);
        }

        {
            const placement = Coordinates3D(f32){
                .x = -1.0,
                .y = 1.0 - (48.0 * screen_scale.vertical),
                .z = ui_layer.middle,
            };
            const margin_pixels: f32 = 8.0;
            ui_state.open_settings_button.draw(placement, margin_pixels, screen_scale);
        }
    }

    var right_sidebar_region: Region = .{};
    switch (ui_state.sidebar_state) {
        .open => {
            right_sidebar_region.anchor.right = window.right;
            right_sidebar_region.anchor.top = window.top;
            right_sidebar_region.z = ui_layer.middle_lower;
            right_sidebar_region.width = 400.0 * screen_scale.horizontal;
            right_sidebar_region.anchor.bottom = window.bottom;

            var close_sidebar_button_region: Region = .{};
            close_sidebar_button_region.anchor.left = right_sidebar_region.left();
            close_sidebar_button_region.anchor.top = right_sidebar_region.top();
            close_sidebar_button_region.z = ui_layer.middle;
            close_sidebar_button_region.width = 32.0 * screen_scale.horizontal;
            close_sidebar_button_region.height = 32.0 * screen_scale.vertical;
            close_sidebar_button_region.margin.top = 10.0 * screen_scale.vertical;
            close_sidebar_button_region.margin.left = 10.0 * screen_scale.horizontal;

            ui_state.open_sidemenu_button.icon = .arrow_forward_32px;
            ui_state.open_sidemenu_button.draw(close_sidebar_button_region.placement(), 4.0, screen_scale);

            const scene_controls_background_color = RGBA{ .r = 36, .g = 39, .b = 47, .a = 255 };
            const scene_controls_extent = right_sidebar_region.toExtent();
            assert(scene_controls_extent.z == right_sidebar_region.z);
            _ = renderer.drawQuad(scene_controls_extent, scene_controls_background_color, .bottom_left);

            const top_margin: f32 = 44.0 * screen_scale.vertical;

            const header_bar_extent = Extent3D(f32){
                .x = scene_controls_extent.x,
                .y = -1.0 + (40.0 * screen_scale.vertical) + top_margin,
                .z = ui_layer.middle,
                .width = scene_controls_extent.width,
                .height = 40.0 * screen_scale.vertical,
            };
            const header_bar_text_extent = Extent3D(f32){
                .x = scene_controls_extent.x,
                .y = -1.0 + (40.0 * screen_scale.vertical) + 0.001 + top_margin,
                .z = ui_layer.middle,
                .width = scene_controls_extent.width / 4.0,
                .height = 40.0 * screen_scale.vertical,
            };
            const header_bar_color = RGBA{ .r = 30, .g = 33, .b = 39, .a = 255 };
            _ = renderer.drawQuad(header_bar_extent, header_bar_color, .bottom_left);
            _ = renderer.drawText("Sources", header_bar_text_extent, screen_scale, .medium, .regular, RGBA.white, .center);

            {
                const add_circle_placement = Coordinates3D(f32){
                    .x = 1.0 - (40.0 * screen_scale.horizontal),
                    .y = -1.0 + (40.0 * screen_scale.vertical) + top_margin,
                    .z = ui_layer.middle,
                };
                ui_state.add_source_button.draw(add_circle_placement, 8.0, screen_scale);
            }

            {
                const item_height: f32 = 40.0 * screen_scale.vertical;
                const margin_right: f32 = 10.0 * screen_scale.horizontal;
                const item_width: f32 = 400.0 * screen_scale.horizontal;
                for (model.video_streams, 0..) |stream, i| {
                    const extent = Extent3D(f32){
                        .x = right_sidebar_region.left() + margin_right,
                        .y = header_bar_extent.y + (@intToFloat(f32, i + 1) * item_height),
                        .z = ui_layer.middle,
                        .width = item_width,
                        .height = item_height,
                    };
                    std.log.info("Source stream: {d}", .{stream.source_index});
                    const source_name = model.video_source_providers[stream.provider_index].sources.?[stream.source_index].name;
                    _ = renderer.drawText(source_name, extent, screen_scale, .medium, .regular, RGBA.white, .center);
                }
            }

            switch (ui_state.add_source_state) {
                .select_source_provider => {
                    const menu_item_height: f32 = 40.0 * screen_scale.vertical;
                    const menu_item_width: f32 = 200 * screen_scale.horizontal;
                    const menu_placement = Coordinates3D(f32){
                        .x = 1.0 - (40.0 * screen_scale.horizontal) - menu_item_width,
                        .y = -1.0 + (200.0 * screen_scale.vertical),
                        .z = ui_layer.middle,
                    };
                    ui_state.select_source_provider_popup.draw(
                        menu_placement,
                        menu_item_width,
                        menu_item_height,
                        screen_scale,
                    );
                },
                .select_source => {
                    const menu_item_height: f32 = 40.0 * screen_scale.vertical;
                    const menu_item_width: f32 = 300 * screen_scale.horizontal;
                    const menu_placement = Coordinates3D(f32){
                        .x = 1.0 - (80.0 * screen_scale.horizontal) - menu_item_width,
                        .y = -1.0 + (200.0 * screen_scale.vertical),
                        .z = ui_layer.middle,
                    };
                    ui_state.select_video_source_popup.draw(
                        menu_placement,
                        menu_item_width,
                        menu_item_height,
                        screen_scale,
                    );
                },
                else => {},
            }
        },
        .closed => {
            var open_sidebar_button_region: Region = .{};
            open_sidebar_button_region.anchor.right = window.right;
            open_sidebar_button_region.anchor.top = window.top;
            open_sidebar_button_region.z = ui_layer.middle_lower;
            open_sidebar_button_region.width = 32.0 * screen_scale.horizontal;
            open_sidebar_button_region.height = 32.0 * screen_scale.vertical;
            open_sidebar_button_region.margin.top = 12 * screen_scale.vertical;
            open_sidebar_button_region.margin.right = 20 * screen_scale.horizontal;
            ui_state.open_sidemenu_button.draw(open_sidebar_button_region.placement(), 4.0, screen_scale);
        },
    }

    var activity_region: Region = .{};
    {
        activity_region.anchor.left = icon_bar_region.right();
        activity_region.anchor.bottom = window.bottom;
        activity_region.anchor.right = window.right;
        activity_region.height = 300.0 * screen_scale.vertical;

        _ = renderer.drawQuad(activity_region.toExtent(), window_color, .bottom_left);

        var topbar_region: Region = .{};
        topbar_region.anchor.top = activity_region.top();
        topbar_region.anchor.left = activity_region.left();
        topbar_region.anchor.right = activity_region.right();
        topbar_region.height = 40.0 * screen_scale.vertical;

        ui_state.activity_section.draw(topbar_region.toExtent(), screen_scale);

        //
        // Drawable region for whichever activity is selected
        //
        var region = Region{};
        region.anchor.left = activity_region.left();
        region.anchor.right = activity_region.right();
        region.anchor.bottom = activity_region.bottom();
        region.height = activity_region.height.? - topbar_region.height.?;

        switch (@intToEnum(UIState.Activity, ui_state.activity_section.active_index)) {
            .record => {
                var start_button_region = Region{};
                start_button_region.anchor.right = region.right();
                start_button_region.anchor.bottom = region.bottom();
                start_button_region.margin.bottom = 10.0 * screen_scale.vertical;
                start_button_region.margin.right = 10.0 * screen_scale.horizontal;

                start_button_region.height = 32.0 * screen_scale.vertical;
                start_button_region.width = 120.0 * screen_scale.horizontal;

                ui_state.activity_start_button.label = switch (model.recording_context.state) {
                    .closing, .recording => "Stop",
                    .idle, .sync => "Record",
                    .paused => "Resume",
                };

                ui_state.activity_start_button.color = RGBA.fromInt(55, 55, 55, 255);
                ui_state.activity_start_button.color_hovered = RGBA.fromInt(65, 65, 65, 255);
                ui_state.activity_start_button.text_color = RGBA.white;

                ui_state.activity_start_button.draw(
                    start_button_region.toExtent(),
                    screen_scale,
                    .{ .rounding_radius = 4.0 },
                );

                var format_label_region = Region{};
                format_label_region.anchor.left = region.left();
                format_label_region.anchor.top = region.top();
                format_label_region.margin.top = 10.0 * screen_scale.vertical;
                format_label_region.margin.left = 20.0 * screen_scale.horizontal;
                format_label_region.width = 80.0 * screen_scale.horizontal;
                format_label_region.height = 30.0 * screen_scale.vertical;

                _ = renderer.drawText(
                    "File Format",
                    format_label_region.toExtent(),
                    screen_scale,
                    .small,
                    .regular,
                    RGBA.fromInt(210, 210, 210, 255),
                    .center,
                );

                var format_button_region = Region{};
                format_button_region.anchor.left = format_label_region.left();
                format_button_region.anchor.top = region.top();
                format_button_region.margin.top = 40.0 * screen_scale.vertical;
                format_button_region.width = 120.0 * screen_scale.horizontal;
                format_button_region.height = 30.0 * screen_scale.vertical;

                ui_state.record_format_selector.draw(
                    format_button_region.placement(),
                    screen_scale,
                );

                var quality_label_region = Region{};
                quality_label_region.anchor.left = format_button_region.right();
                quality_label_region.anchor.bottom = format_label_region.bottom();
                quality_label_region.margin.left = 40.0 * screen_scale.horizontal;
                quality_label_region.width = 60.0 * screen_scale.horizontal;
                quality_label_region.height = 30.0 * screen_scale.vertical;

                _ = renderer.drawText(
                    "Quality",
                    quality_label_region.toExtent(),
                    screen_scale,
                    .small,
                    .regular,
                    RGBA.fromInt(210, 210, 210, 255),
                    .center,
                );

                var quality_selector_region = Region{};
                quality_selector_region.anchor.left = quality_label_region.left();
                quality_selector_region.anchor.top = quality_label_region.bottom();
                quality_selector_region.width = 120.0 * screen_scale.horizontal;
                quality_selector_region.height = 30.0 * screen_scale.vertical;
                ui_state.record_quality_selector.draw(quality_selector_region.placement(), screen_scale);

                var bitrate_slider_region = Region{};
                bitrate_slider_region.anchor.top = quality_selector_region.bottom();
                bitrate_slider_region.anchor.left = region.left();
                bitrate_slider_region.margin.left = 20.0 * screen_scale.horizontal;
                bitrate_slider_region.margin.top = 20.0 * screen_scale.vertical;
                bitrate_slider_region.width = 400 * screen_scale.horizontal;
                bitrate_slider_region.height = 50 * screen_scale.vertical;

                ui_state.record_bitrate_slider.draw(bitrate_slider_region.toExtent(), screen_scale, UIState.bitrate_value_label_max_length);
            },
            .stream => {
                _ = renderer.drawText("Stream", activity_region.toExtent(), screen_scale, .medium, .regular, RGBA.white, .center);
            },
            .screenshot => {
                _ = renderer.drawText("Screenshot", activity_region.toExtent(), screen_scale, .medium, .regular, RGBA.white, .center);
            },
        }
    }

    var preview_region: Region = .{};
    {
        const frame_dimensions: geometry.Dimensions2D(u32) = blk: {
            break :blk .{
                .width = 1920,
                .height = 1080,
            };
        };
        const dimensions_pixels = geometry.Dimensions2D(f32){
            .width = @intToFloat(f32, frame_dimensions.width),
            .height = @intToFloat(f32, frame_dimensions.height),
        };

        const margin_pixels: f32 = 10.0;
        const margin_horizontal: f32 = margin_pixels * screen_scale.horizontal;

        const margin_top: f32 = 50.0 * screen_scale.vertical;
        const margin_bottom: f32 = 10.0 * screen_scale.vertical;
        const margin_vertical: f32 = margin_top + margin_bottom;

        const left_side = icon_bar_region.right();

        const right_anchor: f32 = if (ui_state.sidebar_state == .open and ui_root.screen_dimensions.width >= 1400)
            right_sidebar_region.left()
        else
            window.right;

        const horizontal_space = @fabs(left_side - right_anchor) - (margin_horizontal * 2.0);

        const top_anchor: f32 = window.top + margin_top;
        const bottom_anchor: f32 = activity_region.top();

        const vertical_space = @fabs(bottom_anchor - top_anchor) - margin_vertical;

        const dimensions = geometry.Dimensions2D(f32){
            .width = dimensions_pixels.width * screen_scale.horizontal,
            .height = dimensions_pixels.height * screen_scale.vertical,
        };

        //
        // What we would have to scale the source image by so they would fit into
        // the available horizontal and vertical space respectively.
        //
        const scale_horizontal: f32 = horizontal_space / dimensions.width;
        const scale_vertical: f32 = vertical_space / dimensions.height;

        assert(scale_horizontal < 1.0);
        assert(scale_vertical < 1.0);

        const scale = @min(scale_horizontal, scale_vertical);

        preview_region.anchor.left = icon_bar_region.right();
        preview_region.anchor.top = top_anchor;
        preview_region.height = dimensions.height * scale;
        preview_region.width = dimensions.width * scale;

        const horizontal_space_remaining: f32 = horizontal_space - preview_region.width.?;

        preview_region.margin.left = @max(margin_horizontal, horizontal_space_remaining / 2.0);

        var preview_extent = preview_region.toExtent();
        preview_region.z = ui_layer.low_lower;

        preview_region.anchor.left.? -= 2 * screen_scale.horizontal;
        preview_region.anchor.top.? -= 2 * screen_scale.vertical;

        preview_region.width.? += 4 * screen_scale.horizontal;
        preview_region.height.? += 4 * screen_scale.vertical;

        const background_color = if (model.recording_context.state == .recording)
            RGB.fromInt(150, 20, 20)
        else
            RGB.fromInt(150, 150, 150);

        _ = renderer.drawQuad(preview_region.toExtent(), background_color.toRGBA(), .bottom_left);

        if (model.video_streams.len > 0) {
            const canvas_dimensions_pixels: Dimensions2D(u32) = .{
                .width = @floatToInt(u32, @floor(@intToFloat(f32, frame_dimensions.width) * scale)),
                .height = @floatToInt(u32, @floor(@intToFloat(f32, frame_dimensions.height) * scale)),
            };
            try renderer.resizeCanvas(canvas_dimensions_pixels);
            preview_extent.z = ui_layer.low;
            renderer.drawVideoFrame(preview_extent);

            const video_source_extents = renderer.videoSourceExtents(screen_scale);
            ui_state.video_source_mouse_event_count = @intCast(u32, video_source_extents.len);
            for (video_source_extents, 0..) |source_extent, i| {
                const absolute_extent = Extent3D(f32){
                    .x = source_extent.x + preview_extent.x,
                    .y = preview_extent.y - source_extent.y,
                    .z = source_extent.z + ui_layer.low_lower,
                    .width = source_extent.width,
                    .height = source_extent.height,
                };
                std.log.info("Source extent: {d} x {d}", .{
                    absolute_extent.width,
                    absolute_extent.height,
                });
                ui_state.video_source_mouse_event_buffer[i] = event_system.writeMouseEventSlot(absolute_extent, .{});

                const edges_extent = Extent3D(f32){
                    .x = absolute_extent.x,
                    .y = absolute_extent.y,
                    .z = ui_layer.middle,
                    .width = absolute_extent.width,
                    .height = absolute_extent.height,
                };
                const border_width_pixels = 4;
                const border_h: f32 = border_width_pixels * screen_scale.horizontal;
                const border_v: f32 = border_width_pixels * screen_scale.vertical;
                ui_state.video_source_mouse_edge_buffer[i].fromExtent(edges_extent, border_h, border_v);
            }
        }
    }
}
