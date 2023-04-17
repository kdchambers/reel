// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const Model = @import("../../../Model.zig");
const UIState = @import("../UIState.zig");
const audio = @import("../audio.zig");

const renderer = @import("../../../vulkan_renderer.zig");

const widgets = @import("../widgets.zig");
const Section = widgets.Section;
const TabbedSection = widgets.TabbedSection;

const utils = @import("../../../utils.zig");
const Duration = utils.Duration;

const geometry = @import("../../../geometry.zig");
const Extent2D = geometry.Extent2D;
const Coordinates2D = geometry.Coordinates2D;
const ScaleFactor2D = geometry.ScaleFactor2D;

const TextWriterInterface = struct {
    quad_writer: *FaceWriter,
    pub fn write(
        self: *@This(),
        screen_extent: Extent2D(f32),
        texture_extent: Extent2D(f32),
    ) !void {
        (try self.quad_writer.create(QuadFace)).* = graphics.quadTextured(
            screen_extent,
            texture_extent,
            .bottom_left,
        );
    }
};

const fontana = @import("fontana");
const Font = fontana.Font(.{
    .backend = .freetype_harfbuzz,
    .type_overrides = .{
        .Extent2DPixel = Extent2D(u32),
        .Extent2DNative = Extent2D(f32),
        .Coordinates2DNative = Coordinates2D(f32),
        .Scale2D = ScaleFactor2D(f32),
    },
});
const pen_options = fontana.PenOptions{
    .pixel_format = .r32g32b32a32,
    .PixelType = RGBA,
};
const Pen = Font.PenConfig(pen_options);

const graphics = @import("../../../graphics.zig");
const RGBA = graphics.RGBA(f32);
const RGB = graphics.RGB(f32);
const QuadFace = graphics.QuadFace;
const FaceWriter = graphics.FaceWriter;

var record_button_color_normal = RGBA{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };
var record_button_color_hover = RGBA{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 };

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
        const base = self.anchor.left orelse unreachable;
        return base + self.margin.left;
    }

    pub inline fn right(self: @This()) f32 {
        const base = self.anchor.right orelse self.anchor.left.? + self.margin.left + self.width.?;
        return base - self.margin.right;
    }

    pub fn toExtent(self: @This()) Extent2D(f32) {
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

var record_duration_label_arena: FaceWriter = undefined;
var record_duration_label_extent: Extent2D(f32) = undefined;
const record_icon_color = graphics.RGB(f32).fromInt(240, 20, 20);

pub fn update(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
    pen: *Pen,
    face_writer: *FaceWriter,
) !void {
    _ = face_writer;
    _ = ui_state;
    if (model.recording_context.state == .recording) {
        record_duration_label_arena.reset();
        var text_writer_interface = TextWriterInterface{ .quad_writer = &record_duration_label_arena };
        const record_duration = @intCast(u64, std.time.nanoTimestamp() - model.recording_context.start);
        const duration = Duration.fromNanoseconds(record_duration);
        var string_buffer: [64]u8 = undefined;
        const duration_string = std.fmt.bufPrint(&string_buffer, record_duration_label_format, .{
            duration.hours,
            duration.minutes,
            duration.seconds,
            duration.milliseconds / 10,
        }) catch "00:00:00:00";
        pen.writeCentered(duration_string, record_duration_label_extent, screen_scale, &text_writer_interface) catch |err| {
            std.log.err("user_interface: Failed to update record duration label. Error: {}", .{err});
        };
    }
}

pub fn draw(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
    pen: *Pen,
    face_writer: *FaceWriter,
) !void {
    const window = ui_state.window_region;
    var information_bar_region: Region = .{};
    {
        information_bar_region.anchor.left = window.left;
        information_bar_region.anchor.bottom = window.bottom;
        information_bar_region.width = window.width();
        information_bar_region.height = 30 * screen_scale.vertical;
        const background_color = RGB.fromInt(50, 50, 50);
        (try face_writer.create(QuadFace)).* = graphics.quadColored(
            information_bar_region.toExtent(),
            background_color.toRGBA(),
            .bottom_left,
        );

        if (model.recording_context.state == .recording) {
            const record_icon_center = Coordinates2D(f32){
                .x = information_bar_region.anchor.left.? + (20.0 * screen_scale.horizontal),
                .y = information_bar_region.anchor.bottom.? - (information_bar_region.height.? / 2.0),
            };
            const radius_pixels: f32 = 4.0;
            try graphics.drawCircle(
                record_icon_center,
                radius_pixels,
                record_icon_color.toRGBA(),
                screen_scale,
                face_writer,
            );
            const record_duration = @intCast(u64, std.time.nanoTimestamp() - model.recording_context.start);
            const duration = Duration.fromNanoseconds(record_duration);
            var string_buffer: [64]u8 = undefined;
            const duration_string = std.fmt.bufPrint(&string_buffer, record_duration_label_format, .{
                duration.hours,
                duration.minutes,
                duration.seconds,
                @divFloor(duration.minutes, 100),
            }) catch "00:00:00:00";
            assert(duration_string.len == record_duration_label_buffer_size);

            record_duration_label_arena = face_writer.createArena(record_duration_label_buffer_size * 4);
            var text_writer_interface = TextWriterInterface{ .quad_writer = &record_duration_label_arena };

            const duration_string_width = pen.calculateRenderDimensions(duration_string).width * screen_scale.horizontal;
            record_duration_label_extent = Extent2D(f32){
                .x = information_bar_region.anchor.left.? + (30.0 * screen_scale.horizontal),
                .y = information_bar_region.anchor.bottom.?,
                .width = duration_string_width + (20.0 * screen_scale.horizontal),
                .height = information_bar_region.height.?,
            };
            try pen.writeCentered(duration_string, record_duration_label_extent, screen_scale, &text_writer_interface);

            assert(record_duration_label_arena.vertices_used == record_duration_label_arena.vertices.len);
            assert(record_duration_label_arena.indices_used == record_duration_label_arena.indices.len);
        }
    }

    var preview_region: Region = .{};
    {
        const max_height_pixels: f32 = 540;

        preview_region.anchor.left = window.left;
        preview_region.anchor.top = window.top;
        preview_region.anchor.right = window.right;
        preview_region.height = @divExact(1080, 2) * screen_scale.vertical;
        preview_region.margin.left = 15 * screen_scale.horizontal;
        preview_region.margin.right = 15 * screen_scale.horizontal;
        preview_region.margin.top = 15 * screen_scale.vertical;

        var preview_extent = preview_region.toExtent();

        //
        // TODO: Don't hardcode screen dimensions
        //
        const aspect_ratio: f32 = 1080.0 / 1920.0;
        const would_be_width_pixels = preview_extent.width / screen_scale.horizontal;
        const would_be_height_pixels = would_be_width_pixels * aspect_ratio;

        if (would_be_height_pixels > max_height_pixels) {
            const max_height = max_height_pixels * screen_scale.vertical;
            preview_region.height = max_height;
            const actual_width = (max_height_pixels / aspect_ratio) * screen_scale.horizontal;
            const margin = (2.0 - actual_width) / 2.0;
            preview_region.margin.left = margin;
            preview_region.margin.right = margin;
        } else {
            preview_region.height = would_be_height_pixels * screen_scale.vertical;
        }

        preview_extent = preview_region.toExtent();

        preview_region.margin.left -= 1 * screen_scale.horizontal;
        preview_region.margin.right -= 1 * screen_scale.horizontal;
        preview_region.margin.top -= 1 * screen_scale.vertical;
        preview_region.height.? += 2 * screen_scale.vertical;

        const background_color = if (model.recording_context.state == .recording)
            RGB.fromInt(150, 20, 20)
        else
            RGB.fromInt(150, 150, 150);

        (try face_writer.create(QuadFace)).* = graphics.quadColored(
            preview_region.toExtent(),
            background_color.toRGBA(),
            .bottom_left,
        );

        if (model.desktop_capture_frame != null) {
            // TODO: This hurts my soul
            renderer.video_stream_placement.x = preview_extent.x;
            renderer.video_stream_placement.y = preview_extent.y;
            renderer.video_stream_output_dimensions.width = preview_extent.width;
            renderer.video_stream_output_dimensions.height = preview_extent.height;

            const dimensions_pixels = geometry.Dimensions2D(f32){
                .width = @floor(preview_extent.width / screen_scale.horizontal),
                .height = @floor(preview_extent.height / screen_scale.vertical),
            };
            std.log.info("Preview scaled to: {d} x {d}", .{
                dimensions_pixels.width,
                dimensions_pixels.height,
            });
            renderer.video_stream_scaled_dimensions = dimensions_pixels;
        }

        {
            const placement = geometry.Coordinates2D(f32){
                .x = preview_extent.x,
                .y = preview_extent.y + (60.0 * screen_scale.vertical),
            };
            try ui_state.preview_display_selector.draw(
                placement,
                screen_scale,
                pen,
            );
        }
    }

    var action_tab_region: Region = .{};
    {
        action_tab_region.anchor.left = window.left;
        action_tab_region.anchor.right = window.right;
        action_tab_region.anchor.bottom = information_bar_region.top();
        action_tab_region.height = 200 * screen_scale.vertical;

        const background_color = RGB.fromInt(28, 28, 28);
        const background_quad_ptr = try face_writer.create(QuadFace);
        background_quad_ptr.* = graphics.quadColored(
            action_tab_region.toExtent(),
            background_color.toRGBA(),
            .bottom_left,
        );

        const extent = action_tab_region.toExtent();
        try ui_state.action_tab.draw(
            extent,
            screen_scale,
            pen,
            1 * screen_scale.horizontal,
        );
    }

    var audio_input_section_region: Region = .{};
    {
        audio_input_section_region.anchor.left = window.left;
        audio_input_section_region.anchor.bottom = action_tab_region.top();
        audio_input_section_region.margin.bottom = 15 * screen_scale.vertical;
        audio_input_section_region.margin.left = 15 * screen_scale.horizontal;
        audio_input_section_region.width = 400 * screen_scale.horizontal;
        audio_input_section_region.height = 200 * screen_scale.vertical;

        const section_title = "Audio Source";
        const section_border_color = graphics.RGBA(f32).fromInt(155, 155, 155, 255);

        try Section.draw(
            audio_input_section_region.toExtent(),
            section_title,
            screen_scale,
            pen,
            section_border_color,
            1 * screen_scale.horizontal,
        );

        {
            var spectrogram_region: Region = .{};
            spectrogram_region.anchor.left = audio_input_section_region.left();

            spectrogram_region.anchor.bottom = audio_input_section_region.bottom();
            spectrogram_region.margin.bottom = 40 * screen_scale.vertical;

            ui_state.audio_input_spectogram.min_cutoff_db = -7.0;
            ui_state.audio_input_spectogram.max_cutoff_db = -2.0;
            ui_state.audio_input_spectogram.height_pixels = 150;

            const sample_range = model.input_audio_buffer.sampleRange();
            const samples_per_frame = @floatToInt(usize, @divTrunc(44100.0, 1000.0 / 64.0));
            if (sample_range.count >= samples_per_frame) {
                const sample_offset: usize = sample_range.count - samples_per_frame;
                const sample_index = sample_range.base_sample + sample_offset;
                var sample_buffer: [samples_per_frame]f32 = undefined;
                const samples = model.input_audio_buffer.samplesCopyIfRequired(
                    sample_index,
                    samples_per_frame,
                    &sample_buffer,
                );

                const audio_power_spectrum = audio.samplesToPowerSpectrum(samples);
                const mel_scaled_bins = audio.powerSpectrumToMelScale(audio_power_spectrum, 64);
                try ui_state.audio_input_spectogram.draw(
                    mel_scaled_bins,
                    spectrogram_region.placement(),
                    screen_scale,
                );
            } else {
                const mel_scaled_bins_buffer = [1]f32{-9.0} ** 64;
                try ui_state.audio_input_spectogram.draw(
                    mel_scaled_bins_buffer[0..],
                    spectrogram_region.placement(),
                    screen_scale,
                );
            }

            {
                var volume_bar_region: Region = .{};
                volume_bar_region.anchor.left = audio_input_section_region.left();
                volume_bar_region.margin.left = 10 * screen_scale.horizontal;
                volume_bar_region.anchor.right = audio_input_section_region.right();
                volume_bar_region.margin.right = 10 * screen_scale.horizontal;

                volume_bar_region.anchor.bottom = audio_input_section_region.bottom();
                volume_bar_region.margin.bottom = 20 * screen_scale.vertical;
                volume_bar_region.height = 5 * screen_scale.vertical;

                ui_state.audio_volume_level.init(volume_bar_region.toExtent()) catch |err| {
                    std.log.err("Failed to init audio_volume_level widget. Error: {}", .{err});
                };
            }
        }
    }

    switch (ui_state.action_tab.active_index) {
        0 => try drawSectionRecord(model, ui_state, screen_scale, pen, face_writer, action_tab_region),
        1 => try drawSectionScreenshot(model, ui_state, screen_scale, pen, face_writer, action_tab_region),
        2 => try drawSectionStream(model, ui_state, screen_scale, pen, face_writer, action_tab_region),
        else => unreachable,
    }
}

fn drawSectionScreenshot(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
    pen: *Pen,
    face_writer: *FaceWriter,
    section_region: Region,
) !void {
    var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer };
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
            pen,
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
        const dropdown_label_dimensions = pen.calculateRenderDimensions(dropdown_label);
        format_region.width = (dropdown_label_dimensions.width + 10) * screen_scale.horizontal;
        format_region.height = 30 * screen_scale.vertical;

        const label_extent = format_region.toExtent();
        try pen.writeCentered(dropdown_label, label_extent, screen_scale, &text_writer_interface);

        var dropdown_region: Region = .{};
        dropdown_region.anchor.left = format_region.right();
        dropdown_region.margin.left = 20 * screen_scale.horizontal;
        dropdown_region.anchor.top = section_region.top();
        dropdown_region.margin.top = 60 * screen_scale.vertical;
        dropdown_region.width = 100 * screen_scale.horizontal;
        dropdown_region.height = format_region.height;

        try ui_state.screenshot_format.draw(
            dropdown_region.toExtent(),
            pen,
            screen_scale,
            record_button_color_normal,
        );
    }
}

fn drawSectionRecord(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
    pen: *Pen,
    face_writer: *FaceWriter,
    section_region: Region,
) !void {
    var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer };

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
            pen,
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
        const dropdown_label_dimensions = pen.calculateRenderDimensions(dropdown_label);
        record_quality_region.width = (dropdown_label_dimensions.width + 10) * screen_scale.horizontal;
        record_quality_region.height = 30 * screen_scale.vertical;

        const label_extent = record_quality_region.toExtent();
        try pen.writeCentered(dropdown_label, label_extent, screen_scale, &text_writer_interface);

        var dropdown_region: Region = .{};
        dropdown_region.anchor.left = record_quality_region.right();
        dropdown_region.margin.left = 20 * screen_scale.horizontal;
        dropdown_region.anchor.bottom = section_region.bottom();
        dropdown_region.margin.bottom = 60 * screen_scale.vertical;
        dropdown_region.width = 100 * screen_scale.horizontal;
        dropdown_region.height = record_quality_region.height;

        try ui_state.record_quality.draw(
            dropdown_region.toExtent(),
            pen,
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
        const dropdown_label_dimensions = pen.calculateRenderDimensions(dropdown_label);
        record_format_region.width = (dropdown_label_dimensions.width + 10) * screen_scale.horizontal;
        record_format_region.height = 30 * screen_scale.vertical;

        const label_extent = record_format_region.toExtent();

        try pen.writeCentered(dropdown_label, label_extent, screen_scale, &text_writer_interface);

        var dropdown_region: Region = .{};
        dropdown_region.anchor.left = record_quality_region.right();
        dropdown_region.margin.left = 20 * screen_scale.horizontal;
        dropdown_region.anchor.bottom = record_quality_region.top();
        dropdown_region.margin.bottom = 20 * screen_scale.vertical;
        dropdown_region.width = 100 * screen_scale.horizontal;
        dropdown_region.height = record_format_region.height;

        try ui_state.record_format.draw(
            dropdown_region.toExtent(),
            pen,
            screen_scale,
            record_button_color_normal,
        );
    }
}

fn drawSectionStream(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
    pen: *Pen,
    face_writer: *FaceWriter,
    section_region: Region,
) !void {
    _ = section_region;
    _ = model;
    _ = ui_state;
    _ = screen_scale;
    _ = pen;
    _ = face_writer;
}
