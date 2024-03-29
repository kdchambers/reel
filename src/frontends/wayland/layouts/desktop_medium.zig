// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const Model = @import("../../../Model.zig");
const UIState = @import("../UIState.zig");
const audio = @import("../audio.zig");

const Timer = @import("../../../utils/Timer.zig");

const renderer = @import("../../../renderer.zig");

const widgets = @import("../widgets.zig");
const Section = widgets.Section;
const TabbedSection = widgets.TabbedSection;

const utils = @import("../../../utils.zig");
const Duration = utils.Duration;

const geometry = @import("../../../geometry.zig");
const Radius2D = geometry.Radius2D;
const Extent2D = geometry.Extent2D;
const Extent3D = geometry.Extent3D;
const Dimensions2D = geometry.Dimensions2D;
const Coordinates2D = geometry.Coordinates2D;
const Coordinates3D = geometry.Coordinates3D;
const ScaleFactor2D = geometry.ScaleFactor2D;

const graphics = @import("../../../graphics.zig");
const RGBA = graphics.RGBA(u8);
const RGB = graphics.RGB(u8);
const QuadFace = graphics.QuadFace;

var record_button_color_normal = RGBA{ .r = 20, .g = 20, .b = 20 };
var record_button_color_hover = RGBA{ .r = 25, .g = 25, .b = 25 };

const Anchors = struct {
    left: ?f32 = null,
    right: ?f32 = null,
    top: ?f32 = null,
    bottom: ?f32 = null,
};

const Margins = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,
};

const Region = struct {
    anchor: Anchors = .{},
    margin: Margins = .{},
    width: ?f32 = null,
    height: ?f32 = null,

    pub inline fn top(self: @This()) f32 {
        const base = self.anchor.top orelse self.anchor.bottom.? - self.margin.bottom - self.height.?;
        return base - self.margin.top;
    }

    pub inline fn bottom(self: @This()) f32 {
        const base = self.anchor.bottom orelse self.anchor.top.? + self.margin.top + self.height.?;
        return base - self.margin.bottom;
    }

    pub inline fn left(self: @This()) f32 {
        const base = self.anchor.left orelse self.anchor.right.? - self.width.? - self.margin.right;
        return base + self.margin.left;
    }

    pub inline fn right(self: @This()) f32 {
        const base = self.anchor.right orelse self.anchor.left.? + self.margin.left + self.width.?;
        return base - self.margin.right;
    }

    pub fn toExtent(self: @This()) Extent3D(f32) {
        const x = self.anchor.left orelse self.anchor.right.? - self.width.? - self.margin.right;
        const y = self.anchor.bottom orelse self.anchor.top.? + self.height.? + self.margin.top;
        const width = blk: {
            if (self.width) |width| {
                break :blk width;
            }
            if (self.anchor.right) |right_anchor| {
                break :blk (right_anchor - self.margin.right) - (x + self.margin.left);
            }
            std.debug.assert(false);
            unreachable;
        };
        const height = blk: {
            if (self.height) |height| {
                break :blk height;
            }
            if (self.anchor.top) |top_anchor| {
                break :blk (y - top_anchor) - self.margin.top;
            }
            std.debug.assert(false);
            unreachable;
        };
        return .{
            .x = x + self.margin.left,
            .y = y - self.margin.bottom,
            .z = 0.8,
            .width = width,
            .height = height,
        };
    }

    pub fn placement(self: @This()) Coordinates2D(f32) {
        const base_x = self.anchor.left orelse unreachable;
        const base_y = self.anchor.bottom orelse unreachable;
        return .{
            .x = base_x + self.margin.left,
            .y = base_y - self.margin.bottom,
        };
    }
};

// Buffer size (in characters) of record duration label
// Format: {hour}:{minute}:{second}:{millisecond} where each placeholder is 2 digits wide
const record_duration_label_buffer_size = 11;
const record_duration_label_format = "{d:0>2}:{d:0>2}:{d:0>2}:{d:0>2}";

var record_duration_label_arena: renderer.VertexRange = undefined;
var record_duration_label_extent: Extent3D(f32) = undefined;
const record_icon_color = graphics.RGBA(u8).fromInt(240, 20, 20, 255);

pub fn update(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
) !void {
    _ = ui_state;
    if (model.recording_context.state == .recording) {
        const record_duration = @as(u64, @intCast(std.time.nanoTimestamp() - model.recording_context.start));
        const duration = Duration.fromNanoseconds(record_duration);
        var string_buffer: [64]u8 = undefined;
        const duration_string = std.fmt.bufPrint(&string_buffer, record_duration_label_format, .{
            duration.hours,
            duration.minutes,
            duration.seconds,
            duration.milliseconds / 10,
        }) catch "00:00:00:00";

        renderer.overwriteText(
            record_duration_label_arena,
            duration_string,
            record_duration_label_extent,
            screen_scale,
            .small,
            RGBA.white,
            .center,
        );
    }
}

pub fn draw(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
) !void {
    const window = ui_state.window_region;
    var information_bar_region: Region = .{};
    {
        information_bar_region.anchor.left = window.left;
        information_bar_region.anchor.bottom = window.bottom;
        information_bar_region.width = window.width();
        information_bar_region.height = 30 * screen_scale.vertical;
        const background_color = RGB.fromInt(50, 50, 50);
        _ = renderer.drawQuad(information_bar_region.toExtent(), background_color.toRGBA(), .bottom_left);

        if (model.recording_context.state == .recording) {
            const record_icon_center = Coordinates3D(f32){
                .x = information_bar_region.anchor.left.? + (20.0 * screen_scale.horizontal),
                .y = information_bar_region.anchor.bottom.? - (information_bar_region.height.? / 2.0),
            };
            const radius_pixels: f32 = 4.0;
            const radius = Radius2D(f32){ .h = radius_pixels * screen_scale.horizontal, .v = radius_pixels * screen_scale.vertical };
            _ = renderer.drawCircle(record_icon_center, radius, record_icon_color, @as(u16, radius_pixels * 20.0));

            const record_duration = @as(u64, @intCast(std.time.nanoTimestamp() - model.recording_context.start));
            const duration = Duration.fromNanoseconds(record_duration);
            var string_buffer: [32]u8 = undefined;
            const duration_string = std.fmt.bufPrint(&string_buffer, record_duration_label_format, .{
                duration.hours,
                duration.minutes,
                duration.seconds,
                @divFloor(duration.minutes, 100),
            }) catch "00:00:00:00";
            assert(duration_string.len == record_duration_label_buffer_size);

            const duration_string_width = 150.0 * screen_scale.horizontal;
            // const duration_string_width = pen.calculateRenderDimensions(duration_string).width * screen_scale.horizontal;
            record_duration_label_extent = Extent3D(f32){
                .x = information_bar_region.anchor.left.? + (30.0 * screen_scale.horizontal),
                .y = information_bar_region.anchor.bottom.?,
                .width = duration_string_width + (20.0 * screen_scale.horizontal),
                .height = information_bar_region.height.?,
            };
            const result = renderer.drawText(duration_string, record_duration_label_extent, screen_scale, .small, .regular, RGBA.white, .center);
            record_duration_label_arena = .{
                .start = result.vertex_start,
                .count = result.vertex_count,
            };
        }
    }

    var action_tab_region: Region = .{};
    {
        action_tab_region.anchor.left = window.left;
        action_tab_region.anchor.right = window.right;
        action_tab_region.anchor.bottom = information_bar_region.top();
        action_tab_region.height = 200 * screen_scale.vertical;

        const background_color = RGB.fromInt(28, 28, 28);
        const extent = action_tab_region.toExtent();
        _ = renderer.drawQuad(extent, background_color.toRGBA(), .bottom_left);
        try ui_state.action_tab.draw(
            extent,
            screen_scale,
            1 * screen_scale.horizontal,
        );
    }

    switch (ui_state.action_tab.active_index) {
        0 => try drawSectionRecord(model, ui_state, screen_scale, action_tab_region),
        1 => try drawSectionScreenshot(model, ui_state, screen_scale, action_tab_region),
        2 => try drawSectionStream(model, ui_state, screen_scale, action_tab_region),
        else => unreachable,
    }

    //
    // We need to define vertical dimensions here as preview will reference them
    // After preview is rendered `audio_source_section_region` will calculate it's width
    // based off of it.
    //
    var audio_source_section_region: Region = .{};
    audio_source_section_region.anchor.bottom = action_tab_region.top();
    audio_source_section_region.margin.bottom = 10 * screen_scale.vertical;
    audio_source_section_region.height = 180 * screen_scale.vertical;

    var preview_region: Region = .{};
    {
        const frame_dimensions: geometry.Dimensions2D(u32) = blk: {
            if (model.desktop_capture_frame) |frame|
                break :blk frame.dimensions;
            break :blk .{
                .width = 1920,
                .height = 1080,
            };
        };
        const dimensions_pixels = geometry.Dimensions2D(f32){
            .width = @as(f32, @floatFromInt(frame_dimensions.width)),
            .height = @as(f32, @floatFromInt(frame_dimensions.height)),
        };

        const margin_pixels: f32 = 10.0;
        const margin_horizontal: f32 = margin_pixels * screen_scale.horizontal;
        const margin_vertical: f32 = margin_pixels * screen_scale.vertical;

        const left_side = -1.0 + (300.0 * screen_scale.horizontal);

        const horizontal_space = @abs(left_side - window.right) - (margin_horizontal * 2.0);
        const vertical_space = @abs(audio_source_section_region.top() - window.top) - (margin_vertical * 2.0);

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
        preview_region.anchor.top = window.top;
        preview_region.height = dimensions.height * scale;
        preview_region.width = dimensions.width * scale;

        preview_region.margin.right = margin_horizontal;
        preview_region.margin.top = margin_vertical;

        var preview_extent = preview_region.toExtent();

        preview_region.anchor.right.? += 1 * screen_scale.horizontal;
        preview_region.anchor.top.? -= 1 * screen_scale.vertical;

        preview_region.width.? += 2 * screen_scale.horizontal;
        preview_region.height.? += 2 * screen_scale.vertical;

        const background_color = if (model.recording_context.state == .recording)
            RGB.fromInt(150, 20, 20)
        else
            RGB.fromInt(150, 150, 150);

        _ = renderer.drawQuad(preview_region.toExtent(), background_color.toRGBA(), .bottom_left);

        if (model.desktop_capture_frame != null) {
            const canvas_dimensions_pixels: Dimensions2D(u32) = .{
                .width = @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(frame_dimensions.width)) * scale))),
                .height = @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(frame_dimensions.height)) * scale))),
            };
            try renderer.resizeCanvas(canvas_dimensions_pixels);
            std.log.info("Drawing preview at {d} x {d}", .{ canvas_dimensions_pixels.width, canvas_dimensions_pixels.height });
            preview_extent.z = 0.0;
            renderer.drawVideoFrame(preview_extent);
        }

        // if (model.desktop_capture_frame != null) {
        //     // TODO: This hurts my soul
        //     renderer.video_stream_placement.x = preview_extent.x;
        //     renderer.video_stream_placement.y = preview_extent.y;
        //     renderer.video_stream_output_dimensions.width = preview_extent.width;
        //     renderer.video_stream_output_dimensions.height = preview_extent.height;

        //     renderer.video_stream_scaled_dimensions = .{
        //         .width = dimensions_pixels.width * scale,
        //         .height = dimensions_pixels.height * scale,
        //     };
        //     std.log.info("Preview scaled to: {d} x {d}", .{
        //         renderer.video_stream_scaled_dimensions.width,
        //         renderer.video_stream_scaled_dimensions.height,
        //     });
        // }
    }

    // {
    //     //
    //     // Enable webcam checkbox
    //     //
    //     const margin_top_pixels = 30;
    //     const margin_left_pixels = 20;
    //     const radius_pixels: f32 = 10;
    //     const center_point = geometry.Coordinates2D(f32){
    //         .x = -1.0 + ((margin_left_pixels + radius_pixels) * screen_scale.horizontal),
    //         .y = window.top + ((margin_top_pixels + radius_pixels) * screen_scale.vertical),
    //     };
    //     const color = graphics.RGBA(u8){ .r = 50, .g = 50, .b = 50, .a = 255 };
    //     try ui_state.enable_webcam_checkbox.draw(
    //         center_point,
    //         radius_pixels,
    //         screen_scale,
    //         color,
    //         model.webcam_stream.enabled(),
    //     );

    //     const label_text = "Enable webcam";
    //     var text_writer_interface = TextWriterInterface{ .color = RGBA.white };
    //     const label_text_dimensions = pen.calculateRenderDimensions(label_text);
    //     const label_margin_left = 10;
    //     const label_extent = geometry.Extent2D(f32){
    //         .x = -1.0 + ((margin_left_pixels + (radius_pixels * 2.0) + label_margin_left) * screen_scale.horizontal),
    //         .y = window.top + (((radius_pixels * 2.0) + margin_top_pixels) * screen_scale.vertical),
    //         .width = (label_text_dimensions.width + 5.0) * screen_scale.horizontal,
    //         .height = (radius_pixels * 2.0) * screen_scale.vertical,
    //     };
    //     try pen.writeCentered(label_text, label_extent, screen_scale, &text_writer_interface);
    // }

    {
        audio_source_section_region.anchor.right = window.right;
        audio_source_section_region.anchor.left = preview_region.left();

        audio_source_section_region.margin.right = 10 * screen_scale.horizontal;

        const widget_width: f32 = @abs(audio_source_section_region.anchor.right.? - audio_source_section_region.anchor.left.?);

        const section_title = "Audio Source";
        const section_border_color = graphics.RGBA(u8){ .r = 155, .g = 155, .b = 155, .a = 255 };

        try Section.draw(
            audio_source_section_region.toExtent(),
            section_title,
            screen_scale,
            section_border_color,
            1 * screen_scale.horizontal,
        );

        {
            var spectrogram_region: Region = .{};
            spectrogram_region.anchor.left = audio_source_section_region.left();
            spectrogram_region.anchor.right = audio_source_section_region.right();

            const margin_horizontal: f32 = widget_width * 0.05;

            spectrogram_region.margin.left = margin_horizontal;
            spectrogram_region.margin.right = margin_horizontal;

            spectrogram_region.anchor.bottom = audio_source_section_region.bottom();
            spectrogram_region.margin.bottom = 40 * screen_scale.vertical;
            spectrogram_region.height = 150.0 * screen_scale.vertical;
            spectrogram_region.width = widget_width - (margin_horizontal * 2.0);

            ui_state.audio_source_spectogram.min_cutoff_db = -7.0;
            ui_state.audio_source_spectogram.max_cutoff_db = -2.0;

            const default_freq_bins = [1]f32{-9.0} ** 64;
            const frequency_bins: []const f32 = blk: {
                if (model.audio_streams.len == 0)
                    break :blk default_freq_bins[0..];

                const audio_buffer = model.audio_streams[0].sample_buffer;
                const sample_range = audio_buffer.sampleRange();
                const samples_per_frame = @as(usize, @intFromFloat(@divTrunc(44100.0, 1000.0 / 64.0)));

                if (sample_range.count < samples_per_frame)
                    break :blk default_freq_bins[0..];

                const sample_offset: usize = sample_range.count - samples_per_frame;
                const sample_index = sample_range.base_sample + sample_offset;
                var sample_buffer: [samples_per_frame]f32 = undefined;
                const samples = audio_buffer.samplesCopyIfRequired(
                    sample_index,
                    samples_per_frame,
                    &sample_buffer,
                );
                const audio_power_spectrum = audio.samplesToPowerSpectrum(samples);
                break :blk audio.powerSpectrumToMelScale(audio_power_spectrum, 64);
            };

            try ui_state.audio_source_spectogram.draw(
                frequency_bins[3..],
                spectrogram_region.toExtent(),
                screen_scale,
            );

            {
                var volume_bar_region: Region = .{};
                volume_bar_region.anchor.left = audio_source_section_region.left();
                volume_bar_region.anchor.right = audio_source_section_region.right();

                volume_bar_region.margin.left = margin_horizontal;
                volume_bar_region.margin.right = margin_horizontal;

                volume_bar_region.anchor.bottom = audio_source_section_region.bottom();
                volume_bar_region.margin.bottom = 20 * screen_scale.vertical;
                volume_bar_region.height = 5 * screen_scale.vertical;

                ui_state.audio_volume_level.init(volume_bar_region.toExtent()) catch |err| {
                    std.log.err("Failed to init audio_volume_level widget. Error: {}", .{err});
                };
            }
        }
    }
}

fn drawSectionScreenshot(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
    section_region: Region,
) !void {
    _ = model;
    var screenshot_button_region: Region = .{};
    {
        screenshot_button_region.anchor.right = section_region.right();
        screenshot_button_region.anchor.bottom = section_region.bottom();
        screenshot_button_region.margin.right = 10 * screen_scale.horizontal;
        screenshot_button_region.margin.bottom = 10 * screen_scale.vertical;
        screenshot_button_region.width = 140 * screen_scale.horizontal;
        screenshot_button_region.height = 30 * screen_scale.vertical;

        try ui_state.screenshot_button.draw(
            screenshot_button_region.toExtent(),
            record_button_color_normal,
            "Screenshot",
            screen_scale,
            .{ .rounding_radius = null },
        );
    }

    var format_region: Region = .{};
    {
        format_region.anchor.left = section_region.left();
        format_region.margin.left = 20 * screen_scale.horizontal;
        format_region.anchor.top = section_region.top();
        format_region.margin.top = 60 * screen_scale.vertical;

        const dropdown_label = "Format";
        const dropdown_label_dimensions: Dimensions2D(u32) = .{
            .width = 100,
            .height = 40,
        };
        // const dropdown_label_dimensions = pen.calculateRenderDimensions(dropdown_label);
        format_region.width = @as(f32, @floatFromInt(dropdown_label_dimensions.width + 10)) * screen_scale.horizontal;
        format_region.height = 30 * screen_scale.vertical;

        const label_extent = format_region.toExtent();
        _ = renderer.drawText(dropdown_label, label_extent, screen_scale, .small, .regular, RGBA.white, .center);

        var dropdown_region: Region = .{};
        dropdown_region.anchor.left = format_region.right();
        dropdown_region.margin.left = 20 * screen_scale.horizontal;
        dropdown_region.anchor.top = section_region.top();
        dropdown_region.margin.top = 60 * screen_scale.vertical;
        dropdown_region.width = 100 * screen_scale.horizontal;
        dropdown_region.height = format_region.height;

        try ui_state.screenshot_format.draw(
            dropdown_region.toExtent(),
            screen_scale,
            record_button_color_normal,
        );
    }
}

fn drawSectionRecord(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
    section_region: Region,
) !void {
    //
    // Draw Record Button
    //
    var record_button_region: Region = .{};
    {
        record_button_region.anchor.right = section_region.right();
        record_button_region.margin.right = 10 * screen_scale.horizontal;
        record_button_region.anchor.bottom = section_region.bottom();
        record_button_region.margin.bottom = 10 * screen_scale.vertical;
        record_button_region.width = 120 * screen_scale.horizontal;
        record_button_region.height = 31 * screen_scale.vertical;

        const label = switch (model.recording_context.state) {
            .idle,
            .sync,
            => "Record",
            .recording => "Stop",
            .paused => "Resume",
        };
        try ui_state.record_button.draw(
            record_button_region.toExtent(),
            record_button_color_normal,
            label,
            screen_scale,
            .{ .rounding_radius = null },
        );
    }

    var record_quality_region: Region = .{};
    {
        record_quality_region.anchor.left = section_region.left();
        record_quality_region.margin.left = 20 * screen_scale.horizontal;
        record_quality_region.anchor.bottom = section_region.bottom();
        record_quality_region.margin.bottom = 60 * screen_scale.vertical;

        const dropdown_label = "Quality";
        // const dropdown_label_dimensions = pen.calculateRenderDimensions(dropdown_label);
        const dropdown_label_dimensions: Dimensions2D(u32) = .{
            .width = 100,
            .height = 40,
        };

        record_quality_region.width = @as(f32, @floatFromInt(dropdown_label_dimensions.width + 10)) * screen_scale.horizontal;
        record_quality_region.height = 30 * screen_scale.vertical;

        const label_extent = record_quality_region.toExtent();
        _ = renderer.drawText(dropdown_label, label_extent, screen_scale, .small, .regular, RGBA.white, .center);

        var dropdown_region: Region = .{};
        dropdown_region.anchor.left = record_quality_region.right();
        dropdown_region.margin.left = 20 * screen_scale.horizontal;
        dropdown_region.anchor.bottom = section_region.bottom();
        dropdown_region.margin.bottom = 60 * screen_scale.vertical;
        dropdown_region.width = 100 * screen_scale.horizontal;
        dropdown_region.height = record_quality_region.height;

        try ui_state.record_quality.draw(
            dropdown_region.toExtent(),
            screen_scale,
            record_button_color_normal,
        );
    }

    var record_format_region: Region = .{};
    {
        record_format_region.anchor.left = section_region.left();
        record_format_region.margin.left = 20 * screen_scale.horizontal;
        record_format_region.anchor.bottom = record_quality_region.top();
        record_format_region.margin.bottom = 20 * screen_scale.vertical;

        const dropdown_label = "Format";
        // const dropdown_label_dimensions = pen.calculateRenderDimensions(dropdown_label);
        const dropdown_label_dimensions: Dimensions2D(u32) = .{
            .width = 100,
            .height = 40,
        };

        record_format_region.width = @as(f32, @floatFromInt(dropdown_label_dimensions.width + 10)) * screen_scale.horizontal;
        record_format_region.height = 30 * screen_scale.vertical;

        const label_extent = record_format_region.toExtent();

        _ = renderer.drawText(dropdown_label, label_extent, screen_scale, .small, .regular, RGBA.white, .center);

        var dropdown_region: Region = .{};
        dropdown_region.anchor.left = record_quality_region.right();
        dropdown_region.margin.left = 20 * screen_scale.horizontal;
        dropdown_region.anchor.bottom = record_quality_region.top();
        dropdown_region.margin.bottom = 20 * screen_scale.vertical;
        dropdown_region.width = 100 * screen_scale.horizontal;
        dropdown_region.height = record_format_region.height;

        try ui_state.record_format.draw(
            dropdown_region.toExtent(),
            screen_scale,
            record_button_color_normal,
        );
    }
}

fn drawSectionStream(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
    section_region: Region,
) !void {
    _ = section_region;
    _ = model;
    _ = ui_state;
    _ = screen_scale;
}
