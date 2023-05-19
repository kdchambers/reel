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

const Region = @import("../layout.zig").Region;

const renderer = @import("../../../renderer.zig");

const Model = @import("../../../Model.zig");
const UIState = @import("../UIState.zig");

const event_system = @import("../event_system.zig");

const sidebar_color = RGBA{ .r = 17, .g = 20, .b = 26, .a = 255 };

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
            close_sidebar_button_region.margin.top = 10 * screen_scale.vertical;
            close_sidebar_button_region.margin.left = 10 * screen_scale.horizontal;

            ui_state.open_sidemenu_button.icon = .arrow_forward_32px;
            // ui_state.open_sidemenu_button.background_color = sidebar_color;
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
            _ = renderer.drawText("Sources", header_bar_text_extent, screen_scale, .small, RGBA.white, .middle, .middle);

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
                    _ = renderer.drawText(source_name, extent, screen_scale, .small, RGBA.white, .middle, .middle);
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
    activity_region.anchor.left = icon_bar_region.right();
    activity_region.anchor.bottom = window.bottom;
    activity_region.anchor.right = window.right;
    activity_region.height = 300.0 * screen_scale.vertical;
    _ = renderer.drawQuad(activity_region.toExtent(), RGBA.fromInt(50, 100, 24, 255), .bottom_left);

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
                event_system.writeMouseEventSlot(ui_state.video_source_mouse_event_buffer[i], absolute_extent, .{});
            }
        }
    }
}
