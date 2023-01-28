// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const linux = std.os.linux;
const img = @import("zigimg");
// const audio = @import("audio.zig");
const wayland_client = @import("wayland_client.zig");
const style = @import("app_styling.zig");
const geometry = @import("geometry.zig");
const event_system = @import("event_system.zig");
const screencast = @import("screencast_backends/pipewire/screencast_pipewire.zig");

const fontana = @import("fontana");
const Atlas = fontana.Atlas;
const Font = fontana.Font(.freetype_harfbuzz, .{
    .Extent2DPixel = geometry.Extent2D(u32),
    .Extent2DNative = geometry.Extent2D(f32),
    .Coordinates2DNative = geometry.Coordinates2D(f32),
    .Scale2D = geometry.ScaleFactor2D(f64),
});

const graphics = @import("graphics.zig");
const QuadFace = graphics.QuadFace;
const FaceWriter = graphics.FaceWriter;

const widget = @import("widgets.zig");
const renderer = @import("renderer.zig");

const Button = widget.Button;
const ImageButton = widget.ImageButton;

const texture_layer_dimensions = renderer.texture_layer_dimensions;

/// Change this to force the log level. Otherwise it is determined by release mode
pub const log_level: std.log.Level = .info;

const application_name = "reel";
const background_color = graphics.RGBA(f32).fromInt(u8, 90, 90, 90, 255);

const window_decorations = struct {
    const height_pixels = 40;
    const color = graphics.RGBA(f32).fromInt(u8, 200, 200, 200, 255);
    const exit_button = struct {
        const size_pixels = 24;
        const color_hovered = graphics.RGBA(f32).fromInt(u8, 180, 180, 180, 255);
    };
};

var draw_window_decorations_requested: bool = true;

/// Color to use for icon images
const icon_color = graphics.RGB(f32).fromInt(200, 200, 200);

pub const IconType = enum {
    add,
    arrow_back,
    check_circle,
    close,
    delete,
    favorite,
    home,
    logout,
    menu,
    search,
    settings,
    star,
};

/// Icon dimensions in pixels
const icon_dimensions = geometry.Dimensions2D(u32){
    .width = 48,
    .height = 48,
};

const icon_texture_row_count = 4;

/// Returns the normalized coordinates of the icon in the texture image
fn iconTextureLookup(icon_type: IconType) geometry.Coordinates2D(f32) {
    const icon_type_index = @enumToInt(icon_type);
    const x: u32 = icon_type_index % icon_texture_row_count;
    const y: u32 = icon_type_index / icon_texture_row_count;
    const x_pixel = x * icon_dimensions.width;
    const y_pixel = y * icon_dimensions.height;
    return .{
        .x = @intToFloat(f32, x_pixel) / @intToFloat(f32, texture_layer_dimensions.width),
        .y = @intToFloat(f32, y_pixel) / @intToFloat(f32, texture_layer_dimensions.height),
    };
}

const asset_path_icon = "assets/icons/";

const icon_path_list = [_][]const u8{
    asset_path_icon ++ "add.png",
    asset_path_icon ++ "arrow_back.png",
    asset_path_icon ++ "check_circle.png",
    asset_path_icon ++ "close.png",
    asset_path_icon ++ "delete.png",
    asset_path_icon ++ "favorite.png",
    asset_path_icon ++ "home.png",
    asset_path_icon ++ "logout.png",
    asset_path_icon ++ "menu.png",
    asset_path_icon ++ "search.png",
    asset_path_icon ++ "settings.png",
    asset_path_icon ++ "star.png",
};

const TextWriterInterface = struct {
    quad_writer: *FaceWriter,
    pub fn write(
        self: *@This(),
        screen_extent: geometry.Extent2D(f32),
        texture_extent: geometry.Extent2D(f32),
    ) !void {
        (try self.quad_writer.create(QuadFace)).* = graphics.quadTextured(
            screen_extent,
            texture_extent,
            .bottom_left,
        );
    }
};

var face_writer: FaceWriter = undefined;

var is_draw_required: bool = true;
var is_render_requested: bool = true;

/// Set when command buffers need to be (re)recorded. The following will cause that to happen
///   1. First command buffer recording
///   2. Screen resized
///   3. Push constants need to be updated
///   4. Number of vertices to be drawn has changed
var is_record_requested: bool = true;

// Used to collecting some basic performance data
var app_loop_iteration: u64 = 0;
var frames_presented_count: u64 = 0;
var slowest_frame_ns: u64 = 0;
var fastest_frame_ns: u64 = std.math.maxInt(u64);
var frame_duration_total_ns: u64 = 0;
var frame_duration_awake_ns: u64 = 0;

/// When clicked, terminate the application
var exit_button_extent: geometry.Extent2D(u16) = undefined;
var exit_button_background_quad: *graphics.QuadFace = undefined;
var exit_button_hovered: bool = false;

var record_button_color_normal = graphics.RGBA(f32){ .r = 0.2, .g = 0.2, .b = 0.4, .a = 1.0 };
var record_button_color_hover = graphics.RGBA(f32){ .r = 0.25, .g = 0.23, .b = 0.42, .a = 1.0 };

//
// Text Rendering
//

var texture_atlas: Atlas = undefined;
var font: Font = undefined;
var pen: Font.Pen = undefined;
const asset_path_font = "assets/Roboto-Light.ttf";
const atlas_codepoints = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890!.%:";

const ScreenPixelBaseType = u16;
const ScreenNormalizedBaseType = f32;

const TexturePixelBaseType = u16;
const TextureNormalizedBaseType = f32;

var record_button_opt: ?Button = null;
// var image_button_opt: ?ImageButton = null;
// var add_icon_opt: ?renderer.ImageHandle = null;

var image_button_background_color = graphics.RGBA(f32){ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1.0 };
// var audio_input_capture: audio.pulse.InputCapture = undefined;

var stdlib_gpa: if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{}) else void = .{};
var general_allocator: std.mem.Allocator = undefined;

var app_runtime_start: i128 = undefined;
var top_reserved_pixels: u16 = 0;

pub fn main() !void {
    app_runtime_start = std.time.nanoTimestamp();

    try init();
    try appLoop(general_allocator);
    deinit();
}

pub fn init() !void {
    general_allocator = if (builtin.mode == .Debug) stdlib_gpa.allocator() else std.heap.c_allocator;

    font = Font.initFromFile(general_allocator, asset_path_font) catch |err| {
        std.log.err("app: Failed to initialize fonts. Is Freetype library installed? Error code: {}", .{err});
        return err;
    };
    errdefer font.deinit(general_allocator);

    // try audio_input_capture.init();
    // errdefer audio_input_capture.deinit();

    texture_atlas = try Atlas.init(general_allocator, 512);
    errdefer texture_atlas.deinit(general_allocator);

    event_system.init() catch |err| {
        std.log.err("Failed to initialize the event system. Error: {}", .{err});
        return error.InitializeEventSystemFailed;
    };

    try wayland_client.init("reel");
    errdefer wayland_client.deinit();

    if (draw_window_decorations_requested) {
        top_reserved_pixels = window_decorations.height_pixels;
    }

    try renderer.init(
        general_allocator,
        @ptrCast(*renderer.Display, wayland_client.display),
        @ptrCast(*renderer.Surface, wayland_client.surface),
        &texture_atlas,
    );
    errdefer renderer.deinit(general_allocator);

    {
        const PixelType = graphics.RGBA(f32);
        const points_per_pixel = 100;
        const font_size = fontana.Size{ .point = 18.0 };
        var loaded_texture = try renderer.textureGet();
        std.debug.assert(loaded_texture.width == loaded_texture.height);
        pen = try font.createPen(
            PixelType,
            general_allocator,
            font_size,
            points_per_pixel,
            atlas_codepoints,
            loaded_texture.width,
            loaded_texture.pixels,
            &texture_atlas,
        );
        try renderer.textureCommit();
    }
    errdefer pen.deinit(general_allocator);

    face_writer = renderer.faceWriter();

    widget.init(
        &face_writer,
        face_writer.vertices,
        &wayland_client.mouse_coordinates,
        &wayland_client.screen_dimensions,
        &wayland_client.is_mouse_in_screen,
    );
}

fn deinit() void {
    pen.deinit(general_allocator);
    renderer.deinit(general_allocator);
    wayland_client.deinit();
    texture_atlas.deinit(general_allocator);
    // audio_input_capture.deinit();
    font.deinit(general_allocator);

    if (builtin.mode == .Debug) {
        _ = stdlib_gpa.deinit();
    }
}

fn onScreenCaptureSuccess(width: u32, height: u32) void {
    std.log.info("app: Screen capture stream opened. Dimensions {d}x{d}", .{
        width,
        height,
    });
    enable_preview = true;
    is_draw_required = true;
}

fn onScreenCaptureError() void {
    std.log.err("app: Failed to open screen capture stream", .{});
    enable_preview = false;
}

const preview_dimensions = geometry.Dimensions2D(u32){
    .width = @divExact(1920, 4),
    .height = @divExact(1080, 4),
};

var preview_quad: *QuadFace = undefined;
var preview_reserved_texture_extent: geometry.Extent2D(u32) = undefined;

var last_preview_update_frame_index: u64 = std.math.maxInt(u64);

fn appLoop(allocator: std.mem.Allocator) !void {
    preview_reserved_texture_extent = try renderer.texture_atlas.reserve(
        geometry.Extent2D(u32),
        allocator,
        preview_dimensions.width,
        preview_dimensions.height,
    );

    wayland_client.screen_dimensions.width = @intCast(u16, renderer.swapchain_extent.width);
    wayland_client.screen_dimensions.height = @intCast(u16, renderer.swapchain_extent.height);

    std.log.info("Initial screen dimensions: {d} {d}", .{
        wayland_client.screen_dimensions.width,
        wayland_client.screen_dimensions.height,
    });

    const app_loop_start = std.time.nanoTimestamp();
    const app_initialization_duration = @intCast(u64, app_loop_start - app_runtime_start);
    std.log.info("App initialized in {s}", .{std.fmt.fmtDuration(app_initialization_duration)});

    while (!wayland_client.is_shutdown_requested) {
        app_loop_iteration += 1;

        const screencast_state = screencast.state();

        if (enable_preview_checkbox) |checkbox| {
            const checkbox_state = checkbox.state();
            if (checkbox_state.left_click_release) {
                enable_preview = !enable_preview;
                if (enable_preview) {
                    //
                    // Open or Resume preview
                    //
                    std.debug.assert(screencast_state != .closed);
                    std.debug.assert(screencast_state != .open);
                    switch (screencast_state) {
                        .paused => screencast.unpause(),
                        .uninitialized => try screencast.open(
                            onScreenCaptureSuccess,
                            onScreenCaptureError,
                        ),
                        else => {},
                    }
                } else {
                    //
                    // Pause preview
                    //
                    std.debug.assert(screencast_state == .open);
                    screencast.pause();
                }
                is_draw_required = true;
                std.log.info("Enable preview: {}", .{enable_preview});
            }
        }

        if (wayland_client.awaiting_frame and screencast_state == .open) {
            if (frames_presented_count != last_preview_update_frame_index) {
                if (screencast.nextFrameImage()) |screen_capture| {
                    last_preview_update_frame_index = frames_presented_count;
                    var gpu_texture = try renderer.textureGet();

                    //
                    // TODO: Not sure if this can happen, but handle dimensions
                    //       changing mid-stream
                    //
                    std.debug.assert((preview_dimensions.width * 4) == screen_capture.width);
                    std.debug.assert((preview_dimensions.height * 4) == screen_capture.height);

                    var src_pixels = screen_capture.pixels;
                    var dst_pixels = gpu_texture.pixels;

                    const convert_image_start = std.time.nanoTimestamp();

                    const src_stride: usize = screen_capture.width * 4;
                    var y: usize = 0;
                    var y_base: usize = 0;
                    while (y < preview_dimensions.height) : (y += 1) {
                        var x: usize = 0;
                        while (x < preview_dimensions.width) : (x += 1) {
                            //
                            // Combine a block of 4 pixels into using an average sum
                            //
                            const index_hi = (x * 4) + y_base;
                            const index_lo = index_hi + screen_capture.width;

                            const c0: @Vector(4, u32) = @bitCast([4]u8, src_pixels[index_hi + 0]);
                            const c1: @Vector(4, u32) = @bitCast([4]u8, src_pixels[index_hi + 1]);
                            const c2: @Vector(4, u32) = @bitCast([4]u8, src_pixels[index_lo + 0]);
                            const c3: @Vector(4, u32) = @bitCast([4]u8, src_pixels[index_lo + 1]);

                            const out_i = c0 + c1 + c2 + c3;
                            var out_f = @Vector(4, f32){
                                @intToFloat(f32, out_i[0]),
                                @intToFloat(f32, out_i[1]),
                                @intToFloat(f32, out_i[2]),
                                @intToFloat(f32, out_i[3]),
                            };

                            //
                            // NOTE: Have noticed substancial performance loss here, switching to mult helps
                            //       @intToFloat(f32, rgb) / 255) / 4.0
                            //
                            const mult = comptime (1.0 / 4.0) * (1.0 / 255.0);
                            const mult_vec = @Vector(4, f32){ mult, mult, mult, 1.0 };

                            out_f *= mult_vec;

                            const pixel = graphics.RGBA(f32){
                                .r = out_f[0],
                                .g = out_f[1],
                                .b = out_f[2],
                                .a = 1.0,
                            };

                            const dst_x = x + preview_reserved_texture_extent.x;
                            const dst_y = y + preview_reserved_texture_extent.y;
                            dst_pixels[dst_x + (dst_y * gpu_texture.width)] = pixel;
                        }
                        y_base += src_stride;
                    }

                    const convert_image_end = std.time.nanoTimestamp();
                    const convert_image_duration = @intCast(u64, convert_image_end - convert_image_start);
                    _ = convert_image_duration;

                    // std.log.info("converted image in {s}", .{std.fmt.fmtDuration(convert_image_duration)});

                    try renderer.textureCommit();
                    is_render_requested = true;
                } else {
                    std.log.info("app: Screen capture frame not ready", .{});
                }
            }
        }

        if (record_button_opt) |record_button| {
            const state = record_button.state();
            if (state.hover_enter) {
                record_button.setColor(record_button_color_hover);
                is_render_requested = true;
            }
            if (state.hover_exit) {
                record_button.setColor(record_button_color_normal);
                is_render_requested = true;
            }
        }

        is_draw_required = (is_draw_required or wayland_client.is_draw_requested);
        if (is_draw_required and wayland_client.awaiting_frame) {
            is_draw_required = false;
            try draw(allocator);
            is_record_requested = true;
        }

        if (is_record_requested) {
            is_record_requested = false;
            renderer.recordRenderPass(face_writer.indices_used, wayland_client.screen_dimensions) catch |err| {
                std.log.err("app: Failed to record renderpass command buffers: Error: {}", .{err});
            };
            is_render_requested = true;
        }

        if (wayland_client.awaiting_frame and is_render_requested) {
            frames_presented_count += 1;
            wayland_client.awaiting_frame = false;
            is_render_requested = false;
            try renderer.renderFrame(wayland_client.screen_dimensions);
        }

        _ = wayland_client.pollEvents();

        if (wayland_client.framebuffer_resized) {
            wayland_client.framebuffer_resized = false;
            renderer.recreateSwapchain(wayland_client.screen_dimensions) catch |err| {
                std.log.err("Failed to recreate swapchain. Error: {}", .{err});
            };
            is_draw_required = true;
        }

        const mouse_position = wayland_client.mouseCoordinatesNDCR();
        const mouse_state = wayland_client.button_state;
        switch (wayland_client.button_clicked) {
            .left => event_system.handleMouseClick(&mouse_position, .left, mouse_state),
            .right => event_system.handleMouseClick(&mouse_position, .right, mouse_state),
            .middle => event_system.handleMouseClick(&mouse_position, .middle, mouse_state),
            else => {},
        }

        if (wayland_client.is_mouse_moved) {
            wayland_client.is_mouse_moved = false;
            event_system.handleMouseMovement(&mouse_position);
        }
    }

    const screencast_state = screencast.state();
    if (screencast_state != .uninitialized and screencast_state != .closed) {
        screencast.close();
    }

    const app_end = std.time.nanoTimestamp();
    const app_duration = @intCast(u64, app_end - app_loop_start);

    std.log.info("Run time: {d}", .{std.fmt.fmtDuration(app_duration)});
    const runtime_seconds: f64 = @intToFloat(f64, app_duration) / std.time.ns_per_s;
    std.log.info("Frame count: {d}", .{frames_presented_count});
    std.log.info("Input loop count: {d}", .{app_loop_iteration});
    std.log.info("Lazy FPS: {d}", .{@intToFloat(f64, frames_presented_count) / runtime_seconds});
    std.log.info("Fixed FPS: {d}", .{@intToFloat(f64, app_loop_iteration) / runtime_seconds});
}

fn drawDecorations() !void {
    const screen_dimensions = wayland_client.screen_dimensions;

    if (draw_window_decorations_requested) {
        var faces = try face_writer.allocate(QuadFace, 1);
        const window_decoration_height = @intToFloat(f32, window_decorations.height_pixels * 2) / @intToFloat(f32, screen_dimensions.height);
        {
            //
            // Draw window decoration topbar background
            //
            const extent = geometry.Extent2D(f32){
                .x = -1.0,
                .y = -1.0,
                .width = 2.0,
                .height = window_decoration_height,
            };
            faces[0] = graphics.quadColored(extent, window_decorations.color, .top_left);
        }
        {
            //
            // Draw exit button in window decoration topbar
            //
            // std.debug.assert(window_decorations.exit_button.size_pixels <= window_decorations.height_pixels);
            // const screen_icon_dimensions = geometry.Dimensions2D(f32){
            //     .width = @intToFloat(f32, window_decorations.exit_button.size_pixels * 2) / @intToFloat(f32, screen_dimensions.width),
            //     .height = @intToFloat(f32, window_decorations.exit_button.size_pixels * 2) / @intToFloat(f32, screen_dimensions.height),
            // };
            // const exit_button_outer_margin_pixels = @intToFloat(f32, window_decorations.height_pixels - window_decorations.exit_button.size_pixels) / 2.0;
            // const outer_margin_hor = exit_button_outer_margin_pixels * 2.0 / @intToFloat(f32, screen_dimensions.width);
            // const outer_margin_ver = exit_button_outer_margin_pixels * 2.0 / @intToFloat(f32, screen_dimensions.height);
            // const texture_coordinates = iconTextureLookup(.close);
            // const texture_extent = geometry.Extent2D(f32){
            //     .x = texture_coordinates.x,
            //     .y = texture_coordinates.y,
            //     .width = @intToFloat(f32, icon_dimensions.width) / @intToFloat(f32, texture_layer_dimensions.width),
            //     .height = @intToFloat(f32, icon_dimensions.height) / @intToFloat(f32, texture_layer_dimensions.height),
            // };
            // const extent = geometry.Extent2D(f32){
            //     .x = 1.0 - (outer_margin_hor + screen_icon_dimensions.width),
            //     .y = -1.0 + outer_margin_ver,
            //     .width = screen_icon_dimensions.width,
            //     .height = screen_icon_dimensions.height,
            // };
            // faces[1] = graphics.quadColored(extent, window_decorations.color, .top_left);
            // faces[2] = graphics.quadTextured(extent, texture_extent, .top_left);

            // // TODO: Update on screen size change
            // const exit_button_extent_outer_margin = @divExact(window_decorations.height_pixels - window_decorations.exit_button.size_pixels, 2);
            // exit_button_extent = geometry.Extent2D(u16){ // Top left anchor
            //     .x = screen_dimensions.width - (window_decorations.exit_button.size_pixels + exit_button_extent_outer_margin),
            //     .y = screen_dimensions.height - (window_decorations.exit_button.size_pixels + exit_button_extent_outer_margin),
            //     .width = window_decorations.exit_button.size_pixels,
            //     .height = window_decorations.exit_button.size_pixels,
            // };
            // exit_button_background_quad = &faces[1];
        }
    }
}

fn drawTexture() !void {
    const screen_extent = geometry.Extent2D(f32){
        .x = -0.8,
        .y = 0.8,
        .width = @floatCast(f32, 512 * wayland_client.screen_scale.horizontal),
        .height = @floatCast(f32, 512 * wayland_client.screen_scale.vertical),
    };
    const texture_extent = geometry.Extent2D(f32){
        .x = 0.0,
        .y = 0.0,
        .width = 1.0,
        .height = 1.0,
    };
    (try face_writer.create(QuadFace)).* = graphics.quadTextured(
        screen_extent,
        texture_extent,
        .bottom_left,
    );
}

fn drawScreenCaptureBackground() !void {
    //
    // Draw preview background
    //
    const y_offset = @intToFloat(f64, top_reserved_pixels) * wayland_client.screen_scale.vertical;
    const margin_top_pixels = style.screen_preview.margin_top_pixels;
    const margin_left_pixels = style.screen_preview.margin_left_pixels;
    const border_width_pixels = style.screen_preview.border_width_pixels;
    {
        const margin_top = margin_top_pixels * wayland_client.screen_scale.vertical;
        const margin_left = margin_left_pixels * wayland_client.screen_scale.horizontal;
        const background_width = @intToFloat(f64, preview_dimensions.width + (border_width_pixels * 2));
        const background_height = @intToFloat(f64, preview_dimensions.height + (border_width_pixels * 2));
        const extent = geometry.Extent2D(f32){
            .x = @floatCast(f32, -1.0 + margin_left),
            .y = @floatCast(f32, -1.0 + margin_top + y_offset),
            .width = @floatCast(f32, background_width * wayland_client.screen_scale.horizontal),
            .height = @floatCast(f32, background_height * wayland_client.screen_scale.vertical),
        };
        const color = graphics.RGB(f32).fromInt(120, 120, 120);
        (try face_writer.create(QuadFace)).* = graphics.quadColored(extent, color.toRGBA(), .top_left);
    }
}

fn drawScreenCapture() !void {
    //
    // Draw actual preview
    //
    const y_offset = @intToFloat(f64, top_reserved_pixels) * wayland_client.screen_scale.vertical;
    const margin_top_pixels = style.screen_preview.margin_top_pixels;
    const margin_left_pixels = style.screen_preview.margin_left_pixels;
    {
        const y_top: f64 = (margin_top_pixels + 1) * wayland_client.screen_scale.vertical;
        const x_left: f64 = (margin_left_pixels + 1) * wayland_client.screen_scale.horizontal;
        preview_quad = try face_writer.create(QuadFace);
        const screen_extent = geometry.Extent2D(f32){
            .x = @floatCast(f32, -1.0 + x_left),
            .y = @floatCast(f32, -1.0 + y_top + y_offset),
            .width = @floatCast(f32, @intToFloat(f64, preview_dimensions.width) * wayland_client.screen_scale.horizontal),
            .height = @floatCast(f32, @intToFloat(f64, preview_dimensions.height) * wayland_client.screen_scale.vertical),
        };
        const texture_extent = geometry.Extent2D(f32){
            .x = @intToFloat(f32, preview_reserved_texture_extent.x) / 512,
            .y = @intToFloat(f32, preview_reserved_texture_extent.y) / 512,
            .width = @intToFloat(f32, preview_reserved_texture_extent.width) / 512,
            .height = @intToFloat(f32, preview_reserved_texture_extent.height) / 512,
        };
        preview_quad.* = graphics.quadTextured(
            screen_extent,
            texture_extent,
            .top_left,
        );
    }
}

const white = graphics.RGB(f32).fromInt(255, 255, 255);

const Dropdown = widget.Dropdown;

const Checkbox = widget.Checkbox;
var enable_preview_checkbox: ?Checkbox = null;
var enable_preview: bool = false;

/// Our example draw function
/// This will run anytime the screen is resized
fn draw(allocator: std.mem.Allocator) !void {
    _ = allocator;

    face_writer.reset();

    try drawDecorations();

    {
        if (enable_preview_checkbox == null)
            enable_preview_checkbox = try Checkbox.create();

        const preview_margin_left: f64 = style.screen_preview.margin_left_pixels * wayland_client.screen_scale.horizontal;
        const checkbox_radius_pixels = 11;
        const checkbox_width = checkbox_radius_pixels * wayland_client.screen_scale.horizontal * 2;
        const center = geometry.Coordinates2D(f64){
            .x = -1.0 + (preview_margin_left + (checkbox_width / 2)),
            .y = -0.3,
        };
        try enable_preview_checkbox.?.draw(
            center,
            checkbox_radius_pixels,
            wayland_client.screen_scale,
            style.checkbox_checked_color.toRGBA(),
            enable_preview,
        );

        // TODO: Vertically aligning label will require knowing it's height
        const v_adjustment_hack = 0.85;

        const placement = geometry.Coordinates2D(f32){
            .x = @floatCast(f32, center.x + checkbox_width),
            .y = @floatCast(f32, center.y + (checkbox_radius_pixels * wayland_client.screen_scale.vertical * v_adjustment_hack)),
        };

        var text_writer_interface = TextWriterInterface{ .quad_writer = &face_writer };
        try pen.write(
            "Enable Preview",
            placement,
            wayland_client.screen_scale,
            &text_writer_interface,
        );
    }

    try drawScreenCaptureBackground();
    const screencast_state = screencast.state();
    if (screencast_state == .open) {
        try drawScreenCapture();
    }

    if (record_button_opt == null) {
        record_button_opt = try Button.create();
    }

    // if (image_button_opt == null) {
    //     image_button_opt = try ImageButton.create();

    //     var icon = try img.Image.fromFilePath(allocator, icon_path_list[0]);
    //     defer icon.deinit();

    //     add_icon_opt = try renderer.addTexture(
    //         allocator,
    //         @intCast(u32, icon.width),
    //         @intCast(u32, icon.height),
    //         @ptrCast([*]graphics.RGBA(u8), icon.pixels.rgba32.ptr),
    //     );
    // }

    // if (image_button_opt) |*image_button| {
    //     if (add_icon_opt) |add_icon| {
    //         const width_pixels = @intToFloat(f32, add_icon.width());
    //         const height_pixels = @intToFloat(f32, add_icon.height());
    //         const extent = geometry.Extent2D(f32){
    //             .x = 0.4,
    //             .y = 0.8,
    //             .width = @floatCast(f32, width_pixels * wayland_client.screen_scale.horizontal),
    //             .height = @floatCast(f32, height_pixels * wayland_client.screen_scale.vertical),
    //         };
    //         try image_button.draw(extent, image_button_background_color, add_icon.extent());
    //     }
    // }

    if (record_button_opt) |*record_button| {
        const width_pixels: f32 = 200;
        const height_pixels: f32 = 40;
        const extent = geometry.Extent2D(f32){
            .x = 0.0,
            .y = 0.8,
            .width = @floatCast(f32, width_pixels * wayland_client.screen_scale.horizontal),
            .height = @floatCast(f32, height_pixels * wayland_client.screen_scale.vertical),
        };
        try record_button.draw(
            extent,
            record_button_color_normal,
            "Record",
            &pen,
            wayland_client.screen_scale,
            .{ .rounding_radius = 5 },
        );
    }
}

fn lerp(from: f32, to: f32, value: f32) f32 {
    return from + (value * (to - from));
}

fn random(seed: u32) u32 {
    const value = (seed << 13) ^ 13;
    return ((value * (value * value * 15731 + 7892221) + 1376312589) & 0x7fffffff);
}
