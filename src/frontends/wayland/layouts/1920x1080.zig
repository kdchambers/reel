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

const Region = @import("../layout.zig").Region;

const renderer = @import("../../../renderer.zig");

const Model = @import("../../../Model.zig");
const UIState = @import("../UIState.zig");

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
            };
            const color = RGB{ .r = 202, .g = 202, .b = 202 };
            _ = renderer.drawIcon(placement, .help_32px, screen_scale, color.toRGBA(), .bottom_left);
        }

        {
            const placement = Coordinates3D(f32){
                .x = -1.0,
                .y = 1.0 - (48.0 * screen_scale.vertical),
            };
            const margin_pixels: f32 = 8.0;
            ui_state.open_settings_button.draw(placement, margin_pixels, screen_scale);
        }

        if (ui_state.sidebar_state == .add_menu_open) {
            const scene_controls_background_color = RGBA{ .r = 36, .g = 39, .b = 47, .a = 255 };
            const scene_controls_extent = Extent3D(f32){
                .x = 1.0 - (400.0 * screen_scale.horizontal),
                .y = 1.0,
                .width = 400.0 * screen_scale.horizontal,
                .height = 2.0,
            };
            _ = renderer.drawQuad(scene_controls_extent, scene_controls_background_color, .bottom_left);
            const header_bar_extent = Extent3D(f32){
                .x = scene_controls_extent.x,
                .y = -1.0 + (40.0 * screen_scale.vertical),
                .width = scene_controls_extent.width,
                .height = 40.0 * screen_scale.vertical,
            };
            const header_bar_text_extent = Extent3D(f32){
                .x = scene_controls_extent.x,
                .y = -1.0 + (40.0 * screen_scale.vertical) + 0.001,
                .width = scene_controls_extent.width / 4.0,
                .height = 40.0 * screen_scale.vertical,
            };
            const header_bar_color = RGBA{ .r = 30, .g = 33, .b = 39, .a = 255 };
            _ = renderer.drawQuad(header_bar_extent, header_bar_color, .bottom_left);
            _ = renderer.drawText("Sources", header_bar_text_extent, screen_scale, .small, RGBA.white, .middle, .middle);

            {
                const add_circle_placement = Coordinates3D(f32){
                    .x = 1.0 - (40.0 * screen_scale.horizontal),
                    .y = -1.0 + (40.0 * screen_scale.vertical),
                };
                ui_state.add_source_button.draw(add_circle_placement, 8.0, screen_scale);
            }

            switch (ui_state.add_source_state) {
                .select_source_provider => {
                    const menu_item_height: f32 = 40.0 * screen_scale.vertical;
                    const menu_item_width: f32 = 200 * screen_scale.horizontal;
                    const menu_placement = Coordinates3D(f32){
                        .x = 1.0 - (40.0 * screen_scale.horizontal) - menu_item_width,
                        .y = -1.0 + (200.0 * screen_scale.vertical),
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
        }
    }

    var right_sidebar_region: Region = .{};
    right_sidebar_region.anchor.right = window.right;
    right_sidebar_region.anchor.top = window.top;
    right_sidebar_region.width = 32.0 * screen_scale.horizontal;
    right_sidebar_region.height = 32.0 * screen_scale.vertical;
    right_sidebar_region.z = ui_layer.low_upper;
    right_sidebar_region.margin.top = 12 * screen_scale.vertical;
    right_sidebar_region.margin.right = 20 * screen_scale.horizontal;
    ui_state.open_sidemenu_button.draw(right_sidebar_region.placement(), 4.0, screen_scale);

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

        const margin_top: f32 = 10.0 * screen_scale.vertical;
        const margin_bottom: f32 = 10.0 * screen_scale.vertical;
        const margin_vertical: f32 = margin_top + margin_bottom;

        const left_side = icon_bar_region.right();

        const horizontal_space = @fabs(left_side - window.right) - (margin_horizontal * 2.0);
        const vertical_space = @fabs(window.bottom - window.top) - margin_vertical;

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

        preview_region.anchor.right = window.right;
        preview_region.anchor.top = right_sidebar_region.bottom();
        preview_region.height = dimensions.height * scale;
        preview_region.width = dimensions.width * scale;

        preview_region.margin.right = margin_horizontal;
        preview_region.margin.top = margin_top;

        var preview_extent = preview_region.toExtent();
        preview_extent.z = ui_layer.low_lower;

        preview_region.anchor.right.? += 1 * screen_scale.horizontal;
        preview_region.anchor.top.? -= 1 * screen_scale.vertical;

        preview_region.width.? += 2 * screen_scale.horizontal;
        preview_region.height.? += 2 * screen_scale.vertical;

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
        }
    }
}
