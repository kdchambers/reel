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
        const base = self.anchor.top orelse self.anchor.bottom.? - self.height.?;
        return base - self.margin.top;
    }

    pub inline fn bottom(self: @This()) f32 {
        const base = self.anchor.bottom orelse unreachable;
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
                break :blk @fabs(y - top_anchor);
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

const window = struct {
    pub inline fn left() f32 {
        return -1.0;
    }

    pub inline fn right() f32 {
        return 1.0;
    }

    pub inline fn top() f32 {
        return -1.0;
    }

    pub inline fn bottom() f32 {
        return 1.0;
    }

    pub inline fn width() f32 {
        return 2.0;
    }

    pub inline fn height() f32 {
        return 2.0;
    }
};

pub fn draw(
    model: *const Model,
    ui_state: *UIState,
    screen_scale: ScaleFactor2D(f32),
    pen: *Pen,
    face_writer: *FaceWriter,
) !void {
    var information_bar_region: Region = .{};
    {
        information_bar_region.anchor.left = window.left();
        information_bar_region.anchor.bottom = window.bottom();
        information_bar_region.width = window.width();
        information_bar_region.height = 30 * screen_scale.horizontal;
        const background_color = RGB.fromInt(50, 50, 50);
        (try face_writer.create(QuadFace)).* = graphics.quadColored(
            information_bar_region.toExtent(),
            background_color.toRGBA(),
            .bottom_left,
        );
    }

    if (model.desktop_capture_frame != null) {
        const max_height_pixels: f32 = 540;

        var preview_region: Region = .{};
        preview_region.anchor.left = window.left();
        preview_region.anchor.top = window.top();
        preview_region.anchor.right = window.right();
        preview_region.height = @divExact(1080, 2) * screen_scale.vertical;
        preview_region.margin.left = 15 * screen_scale.horizontal;
        preview_region.margin.right = 15 * screen_scale.horizontal;
        preview_region.margin.top = 15 * screen_scale.vertical;

        var preview_extent = preview_region.toExtent();

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

        const background_color = RGB.fromInt(150, 150, 150);
        (try face_writer.create(QuadFace)).* = graphics.quadColored(
            preview_region.toExtent(),
            background_color.toRGBA(),
            .bottom_left,
        );

        // TODO: This hurts my soul
        renderer.video_stream_placement.x = preview_extent.x;
        renderer.video_stream_placement.y = preview_extent.y;
        renderer.video_stream_output_dimensions.width = preview_extent.width;
        renderer.video_stream_output_dimensions.height = preview_extent.height;
    }

    var audio_input_section_region: Region = .{};
    {
        audio_input_section_region.anchor.left = window.left();
        audio_input_section_region.anchor.bottom = information_bar_region.top();

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

        if (model.audio_input_samples) |audio_input_samples| {
            const audio_power_spectrum = audio.samplesToPowerSpectrum(audio_input_samples);
            const mel_scaled_bins = audio.powerSpectrumToMelScale(audio_power_spectrum, 64);

            var spectrogram_region: Region = .{};
            spectrogram_region.anchor.left = audio_input_section_region.left();

            spectrogram_region.anchor.bottom = audio_input_section_region.bottom();
            spectrogram_region.margin.bottom = 50 * screen_scale.vertical;

            ui_state.audio_input_spectogram.min_cutoff_db = -7.0;
            ui_state.audio_input_spectogram.max_cutoff_db = -2.0;
            ui_state.audio_input_spectogram.height_pixels = 200;

            try ui_state.audio_input_spectogram.draw(
                mel_scaled_bins,
                spectrogram_region.placement(),
                screen_scale,
            );

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

    var control_section_region: Region = .{};
    {
        control_section_region.anchor.right = window.right();
        control_section_region.anchor.left = audio_input_section_region.right();
        control_section_region.anchor.bottom = information_bar_region.top();

        control_section_region.margin.bottom = 15 * screen_scale.vertical;
        control_section_region.margin.right = 15 * screen_scale.horizontal;
        control_section_region.margin.left = 15 * screen_scale.horizontal;
        control_section_region.height = 200 * screen_scale.vertical;

        const section_title = "Recorder";
        const section_border_color = graphics.RGBA(f32).fromInt(155, 155, 155, 255);

        try Section.draw(
            control_section_region.toExtent(),
            section_title,
            screen_scale,
            pen,
            section_border_color,
            1 * screen_scale.horizontal,
        );

        {
            //
            // Draw Record Button
            //
            var record_button_region: Region = .{};
            record_button_region.anchor.right = control_section_region.right();
            record_button_region.margin.right = 10 * screen_scale.horizontal;
            record_button_region.anchor.bottom = control_section_region.bottom();
            record_button_region.margin.bottom = 10 * screen_scale.vertical;
            record_button_region.width = 120 * screen_scale.horizontal;
            record_button_region.height = 31 * screen_scale.vertical;

            const label = switch (model.recording_context.state) {
                .idle => "Record",
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

        var record_format_region: Region = .{};
        {
            record_format_region.anchor.left = control_section_region.left();
            record_format_region.margin.left = 70 * screen_scale.horizontal;
            record_format_region.anchor.top = control_section_region.top();
            record_format_region.margin.top = 10 * screen_scale.vertical;
            record_format_region.width = 100 * screen_scale.horizontal;
            record_format_region.height = 30 * screen_scale.vertical;

            const labels = [_][]const u8{
                "mp4",
                "avi",
                "mkv",
            };

            const dropdown_extent = record_format_region.toExtent();
            const dropdown_label = "Format";

            const dropdown_label_dimensions = pen.calculateRenderDimensions(dropdown_label);
            const label_extent = Extent2D(f32){
                .x = record_format_region.anchor.left.? + (10 * screen_scale.horizontal),
                .y = dropdown_extent.y,
                //
                // TODO: Seems like calculateRenderDimensions isn't calculating enough space for
                //       the glyphs. writeCentered is failing sometimes because it doesn't have enough
                //       space to fit the text into
                //
                .width = dropdown_label_dimensions.width * screen_scale.horizontal + 0.01,
                .height = dropdown_extent.height,
            };
            var text_writer_interface = TextWriterInterface{ .quad_writer = face_writer };
            try pen.writeCentered(dropdown_label, label_extent, screen_scale, &text_writer_interface);

            try ui_state.record_format.draw(
                dropdown_extent,
                &labels,
                0,
                pen,
                screen_scale,
                record_button_color_normal,
                false,
            );
        }
    }
}