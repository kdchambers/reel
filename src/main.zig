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
const screencast = @import("screencast.zig");
const mini_heap = @import("mini_heap.zig");

const video_encoder = @import("video_record.zig");

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
    const height_pixels = 30;
    const color = graphics.RGBA(f32).fromInt(u8, 200, 200, 200, 255);
    const exit_button = struct {
        const size_pixels = 24;
        const color_hovered = graphics.RGBA(f32).fromInt(u8, 180, 180, 180, 255);
    };
};

const button_close = struct {
    const Index = mini_heap.Index;
    const HoverZoneState = event_system.HoverZoneState;

    const background_color_hovered = graphics.RGBA(f32){
        .r = 0.7,
        .g = 0.7,
        .b = 0.7,
        .a = 1.0,
    };
    const background_color = graphics.RGBA(f32){
        .r = 0.0,
        .g = 0.0,
        .b = 0.0,
        .a = 0.0,
    };
    const foreground_color = graphics.RGBA(f32){
        .r = 0.0,
        .g = 0.0,
        .b = 0.0,
        .a = 1.0,
    };

    const background_padding_pixels = 4;
    const size_pixels = 18;
    const width_pixels = 3;
    const vertex_count = 4;

    var state_index: Index(HoverZoneState) = undefined;
    var extent_index = Index(geometry.Extent2D(f32)).invalid;
    var vertex_index: u16 = 0;

    pub fn init() void {
        button_close.state_index = event_system.reserveState();
        button_close.state_index.getPtr().reset();
    }

    pub fn draw() !void {
        const margin = (window_decorations.height_pixels - size_pixels) / 2.0;
        const scale = wayland_client.screen_scale;
        const size_horizontal: f64 = size_pixels * scale.horizontal;
        const size_vertical: f64 = size_pixels * scale.vertical;
        const x_offset = (margin * scale.horizontal * 2.0) + size_horizontal;
        const y_offset = (margin * scale.vertical) + size_vertical;
        const extent = geometry.Extent2D(f32){
            .x = @floatCast(f32, 1.0 - x_offset),
            .y = @floatCast(f32, -1.0 + y_offset),
            .width = @floatCast(f32, size_horizontal),
            .height = @floatCast(f32, size_vertical),
        };

        vertex_index = face_writer.vertices_used;

        const padding_horizontal = background_padding_pixels * scale.horizontal;
        const padding_vertical = background_padding_pixels * scale.vertical;
        const background_extent = geometry.Extent2D(f32){
            .x = @floatCast(f32, extent.x - padding_horizontal),
            .y = @floatCast(f32, extent.y + padding_vertical),
            .width = @floatCast(f32, extent.width + (padding_horizontal * 2.0)),
            .height = @floatCast(f32, extent.height + (padding_vertical * 2.0)),
        };

        (try face_writer.create(QuadFace)).* = graphics.quadColored(
            background_extent,
            button_close.background_color,
            .bottom_left,
        );

        try widget.drawCross(
            extent,
            @floatCast(f32, width_pixels * scale.horizontal),
            @floatCast(f32, width_pixels * scale.vertical),
            button_close.foreground_color,
        );
        event_system.bindStateToMouseEvent(
            button_close.state_index,
            extent,
            &button_close.extent_index,
            .{
                .enable_hover = true,
                .start_active = false,
            },
        );
    }

    pub inline fn state() HoverZoneState {
        const state_copy = button_close.state_index.get();
        button_close.state_index.getPtr().clear();
        return state_copy;
    }

    pub fn setHovered(is_hovered: bool) void {
        if (is_hovered)
            button_close.setColor(button_close.background_color_hovered)
        else
            button_close.setColor(button_close.background_color);

        is_render_requested = true;
    }

    pub fn setColor(color: graphics.RGBA(f32)) void {
        var i = button_close.vertex_index;
        const end_index = button_close.vertex_index + button_close.vertex_count;
        while (i < end_index) : (i += 1) {
            face_writer.vertices[i].color = color;
        }
    }
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
var screencast_interface: ?screencast.Interface = null;

const Checkbox = widget.Checkbox;
var enable_preview_checkbox: ?Checkbox = null;

var gpu_texture_mutex: std.Thread.Mutex = undefined;

const StreamState = enum(u8) {
    idle,
    preview,
    record,
    record_preview,
};
var stream_state: StreamState = .idle;
var video_stream_frame_index: u32 = 0;

pub fn main() !void {
    app_runtime_start = std.time.nanoTimestamp();

    try init();
    try appLoop(general_allocator);

    deinit();
}

var close_icon_handle: renderer.ImageHandle = undefined;

pub fn init() !void {
    general_allocator = if (builtin.mode == .Debug) stdlib_gpa.allocator() else std.heap.c_allocator;

    font = Font.initFromFile(general_allocator, asset_path_font) catch |err| {
        std.log.err("app: Failed to initialize fonts. Is Freetype installed? Error code: {}", .{err});
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

    var close_icon = try img.Image.fromFilePath(general_allocator, icon_path_list[@enumToInt(IconType.close)]);
    defer close_icon.deinit();

    close_icon_handle = try renderer.addTexture(
        general_allocator,
        @intCast(u32, close_icon.width),
        @intCast(u32, close_icon.height),
        @ptrCast([*]const graphics.RGBA(u8), close_icon.pixels.rgba32.ptr),
    );

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

    screencast_interface = screencast.createBestInterface(
        writeScreencastPixelBufferCallback,
    );
    if (screencast_interface == null) {
        std.log.warn("No screencast backends detected", .{});
    }

    button_close.init();
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

//
// Callbacks
//

fn writeScreencastPixelBufferCallback(width: u32, height: u32, pixels: [*]const screencast.PixelType) void {
    if (screencast_interface.?.state() != .open)
        return;

    gpu_texture_mutex.lock();
    defer gpu_texture_mutex.unlock();

    const convert_image_start = std.time.nanoTimestamp();

    switch (stream_state) {
        .preview => {
            var video_frame = renderer.videoFrame();
            var y: usize = 0;
            var src_index: usize = 0;
            var dst_index: usize = 0;
            while (y < height) : (y += 1) {
                @memcpy(
                    @ptrCast([*]u8, &video_frame.pixels[dst_index]),
                    @ptrCast([*]const u8, &pixels[src_index]),
                    width * @sizeOf(screencast.PixelType),
                );
                src_index += width;
                dst_index += video_frame.width;
            }
        },
        .record_preview => {
            std.debug.assert(video_encoder.state == .encoding);
            video_encoder.write(pixels, video_stream_frame_index) catch |err| {
                std.log.err("app: Failed to write frame to video_encoder buffer. Error: {}", .{err});
            };
            video_stream_frame_index += 1;
            var video_frame = renderer.videoFrame();
            var y: usize = 0;
            var src_index: usize = 0;
            var dst_index: usize = 0;
            while (y < height) : (y += 1) {
                @memcpy(
                    @ptrCast([*]u8, &video_frame.pixels[dst_index]),
                    @ptrCast([*]const u8, &pixels[src_index]),
                    width * @sizeOf(screencast.PixelType),
                );
                src_index += width;
                dst_index += video_frame.width;
            }
        },
        .record => {
            std.debug.assert(video_encoder.state == .encoding);
            video_encoder.write(pixels, video_stream_frame_index) catch |err| {
                std.log.err("app: Failed to write frame to video_encoder buffer. Error: {}", .{err});
            };
            video_stream_frame_index += 1;
        },
        else => unreachable,
    }

    const convert_image_end = std.time.nanoTimestamp();
    const convert_image_duration = @intCast(u64, convert_image_end - convert_image_start);
    _ = convert_image_duration;
    is_render_requested = true;
}

fn onScreenCaptureSuccess(width: u32, height: u32) void {
    std.log.info("app: Screen capture stream opened. Dimensions {d}x{d}", .{
        width,
        height,
    });

    stream_state = switch (stream_state) {
        .idle => .preview,
        .record => .record_preview,
        else => unreachable,
    };

    is_draw_required = true;
    renderer.video_stream_enabled = true;
}

fn onScreenCaptureError() void {
    std.log.err("app: Failed to open screen capture stream", .{});
    stream_state = .idle;
}

fn appLoop(allocator: std.mem.Allocator) !void {
    wayland_client.screen_dimensions.width = @intCast(u16, renderer.swapchain_extent.width);
    wayland_client.screen_dimensions.height = @intCast(u16, renderer.swapchain_extent.height);

    std.log.info("Initial screen dimensions: {d} {d}", .{
        wayland_client.screen_dimensions.width,
        wayland_client.screen_dimensions.height,
    });

    const app_loop_start = std.time.nanoTimestamp();
    const app_initialization_duration = @intCast(u64, app_loop_start - app_runtime_start);
    std.log.info("App initialized in {s}", .{std.fmt.fmtDuration(app_initialization_duration)});

    const input_fps = 60;
    const input_latency_ns: u64 = std.time.ns_per_s / input_fps;

    while (!wayland_client.is_shutdown_requested) {
        const loop_begin = std.time.nanoTimestamp();

        app_loop_iteration += 1;

        if (screencast_interface) |interface| {
            const screencast_state = interface.state();
            if (enable_preview_checkbox) |checkbox| {
                const checkbox_state = checkbox.state();
                if (checkbox_state.left_click_release) {
                    switch (stream_state) {
                        //
                        // Open or Resume preview
                        //
                        .idle => {
                            std.debug.assert(screencast_state != .closed);
                            std.debug.assert(screencast_state != .open);
                            switch (screencast_state) {
                                .paused => {
                                    interface.unpause();
                                    stream_state = .preview;
                                },
                                .uninitialized => try interface.requestOpen(
                                    onScreenCaptureSuccess,
                                    onScreenCaptureError,
                                ),
                                else => {},
                            }
                        },
                        //
                        // Pause preview
                        //
                        .preview => {
                            std.debug.assert(screencast_state == .open);
                            interface.pause();
                            stream_state = .idle;
                            std.debug.assert(interface.state() == .paused);
                        },
                        //
                        // Pause but don't inturrupt recording
                        //
                        .record_preview => {
                            std.debug.assert(screencast_state == .open);
                            interface.pause();
                            stream_state = .record;
                            std.debug.assert(interface.state() == .paused);
                        },
                        //
                        // Enable preview while recording
                        //
                        .record => {
                            interface.unpause();
                            stream_state = .record_preview;
                            std.debug.assert(interface.state() == .open);
                        },
                    }
                    is_draw_required = true;
                }
            }
        }

        {
            const state = button_close.state();
            if (state.hover_enter)
                button_close.setHovered(true);
            if (state.hover_exit)
                button_close.setHovered(false);
            if (state.left_click_release)
                wayland_client.shutdown();
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

            if (state.left_click_release) {
                switch (video_encoder.state) {
                    //
                    // Start new recording
                    //
                    .uninitialized => {
                        //
                        // Start screencast stream if preview isn't already open
                        //
                        if (stream_state == .idle) blk: {
                            screencast_interface.?.requestOpen(
                                onScreenCaptureSuccess,
                                onScreenCaptureError,
                            ) catch |err| {
                                std.log.err("app: Failed to start video stream. Error: {}", .{err});
                                break :blk;
                            };
                        }
                        const options = video_encoder.RecordOptions{
                            .output_path = "reel_test.mp4",
                            .dimensions = .{
                                .width = 1920,
                                .height = 1080,
                            },
                            .fps = 60,
                            .base_index = wayland_client.frame_index,
                        };
                        video_encoder.open(options) catch |err| {
                            std.log.err("app: Failed to start video encoder. Error: {}", .{err});
                        };
                        video_stream_frame_index = 0;
                        stream_state = switch (stream_state) {
                            .idle => .record,
                            .preview => .record_preview,
                            else => unreachable,
                        };
                    },
                    //
                    // Stop current recording
                    //
                    .encoding => {
                        video_encoder.close();
                        switch (stream_state) {
                            .record => {
                                stream_state = .idle;
                                screencast_interface.?.pause();
                            },
                            .record_preview => stream_state = .preview,
                            else => unreachable,
                        }
                    },
                    else => unreachable,
                }
                is_draw_required = true;
            }
        }

        is_draw_required = (is_draw_required or wayland_client.is_draw_requested);
        if (is_draw_required) {
            is_draw_required = false;
            wayland_client.is_draw_requested = false;
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

        if (wayland_client.pending_swapchain_images_count > 0) {
            if (is_render_requested) {
                is_render_requested = false;

                wayland_client.pending_swapchain_images_count -= 1;
                gpu_texture_mutex.lock();
                defer gpu_texture_mutex.unlock();

                try renderer.renderFrame(wayland_client.screen_dimensions);
            }
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

        const loop_end = std.time.nanoTimestamp();
        const loop_duration = @intCast(u64, loop_end - loop_begin);
        if (loop_duration < input_latency_ns) {
            const sleep_period_ns = input_latency_ns - loop_duration;
            std.time.sleep(sleep_period_ns);
        }
    }

    std.log.info("Terminating application", .{});

    if (screencast_interface) |interface| {
        const screencast_state = interface.state();
        if (screencast_state != .uninitialized and screencast_state != .closed) {
            std.log.info("Closing screencast stream", .{});
            interface.close();
        }
    }

    if (video_encoder.state == .encoding) {
        std.log.info("Closing video stream", .{});
        video_encoder.close();
    }

    const app_end = std.time.nanoTimestamp();
    const app_duration = @intCast(u64, app_end - app_loop_start);

    const print = std.debug.print;
    const runtime_seconds: f64 = @intToFloat(f64, app_duration) / std.time.ns_per_s;
    const frames_per_s: f64 = @intToFloat(f64, wayland_client.frame_index) / @intToFloat(f64, app_duration / std.time.ns_per_s);
    print("\n== Runtime Statistics ==\n\n", .{});
    print("runtime:     {d:.2}s\n", .{runtime_seconds});
    print("display fps: {d:.2}\n", .{frames_per_s});
    print("input fps:   {d:.2}\n", .{@intToFloat(f64, app_loop_iteration) / runtime_seconds});
    print("\n", .{});
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

fn drawScreenCapture() !void {
    calculatePreviewExtent();

    const border_width_pixels = style.screen_preview.border_width_pixels;
    const screen_scale = wayland_client.screen_scale;

    const border_width_horizontal: f64 = border_width_pixels * screen_scale.horizontal;
    const border_width_vertical: f64 = border_width_pixels * screen_scale.vertical;
    const background_width: f64 = (renderer.video_stream_output_dimensions.width * screen_scale.horizontal) + (border_width_horizontal * 2.0);
    const background_height: f64 = (renderer.video_stream_output_dimensions.height * screen_scale.vertical) + (border_width_vertical * 2.0);
    {
        const extent = geometry.Extent2D(f32){
            .x = @floatCast(f32, renderer.video_stream_placement.x - border_width_horizontal),
            .y = @floatCast(f32, renderer.video_stream_placement.y - border_width_vertical),
            .width = @floatCast(f32, background_width),
            .height = @floatCast(f32, background_height),
        };
        const color = graphics.RGB(f32).fromInt(120, 120, 120);
        (try face_writer.create(QuadFace)).* = graphics.quadColored(extent, color.toRGBA(), .top_left);
    }
}

fn calculatePreviewExtent() void {
    const y_offset = @intToFloat(f64, top_reserved_pixels) * wayland_client.screen_scale.vertical;
    const margin_top_pixels = style.screen_preview.margin_top_pixels;
    const margin_left_pixels = style.screen_preview.margin_left_pixels;

    const width_min_pixels = 200;
    const width_max_pixels = 1920 / 2;

    const screen_dimensions = wayland_client.screen_dimensions;
    const wanted_width: f64 = @intToFloat(f64, screen_dimensions.width) * 0.8;
    const clamped_width: f64 = @min(@max(wanted_width, width_min_pixels), width_max_pixels);
    const screencast_dimensions = renderer.video_stream_dimensions;
    const scale_ratio: f64 = clamped_width / screencast_dimensions.width;
    std.debug.assert(scale_ratio <= 1.0);

    renderer.video_stream_output_dimensions.width = @floatCast(f32, clamped_width);
    renderer.video_stream_output_dimensions.height = @floatCast(f32, screencast_dimensions.height * scale_ratio);
    const y_top: f64 = (margin_top_pixels + 1) * wayland_client.screen_scale.vertical;
    const x_left: f64 = (margin_left_pixels + 1) * wayland_client.screen_scale.horizontal;
    renderer.video_stream_placement.x = @floatCast(f32, -1.0 + x_left);
    renderer.video_stream_placement.y = @floatCast(f32, -1.0 + y_top + y_offset);
}

/// Our example draw function
/// This will run anytime the screen is resized
fn draw(allocator: std.mem.Allocator) !void {
    _ = allocator;

    face_writer.reset();

    try drawDecorations();
    try button_close.draw();

    {
        if (enable_preview_checkbox == null)
            enable_preview_checkbox = try Checkbox.create();

        const preview_margin_left: f64 = style.screen_preview.margin_left_pixels * wayland_client.screen_scale.horizontal;
        const checkbox_radius_pixels = 11;
        const checkbox_width = checkbox_radius_pixels * wayland_client.screen_scale.horizontal * 2;
        const center = geometry.Coordinates2D(f64){
            .x = -1.0 + (preview_margin_left + (checkbox_width / 2)),
            .y = 0.0,
        };
        const is_set = (stream_state == .preview or stream_state == .record_preview);
        try enable_preview_checkbox.?.draw(
            center,
            checkbox_radius_pixels,
            wayland_client.screen_scale,
            style.checkbox_checked_color.toRGBA(),
            is_set,
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

    try drawScreenCapture();

    if (record_button_opt == null) {
        record_button_opt = try Button.create();
    }

    // if (image_button_opt == null) {
    //     image_button_opt = try ImageButton.create();
    // }

    // if (image_button_opt) |*image_button| {
    //     const width_pixels = @intToFloat(f32, close_icon_handle.width());
    //     const height_pixels = @intToFloat(f32, close_icon_handle.height());
    //     const extent = geometry.Extent2D(f32){
    //         .x = 0.4,
    //         .y = 0.8,
    //         .width = @floatCast(f32, width_pixels * wayland_client.screen_scale.horizontal),
    //         .height = @floatCast(f32, height_pixels * wayland_client.screen_scale.vertical),
    //     };
    //     try image_button.draw(extent, image_button_background_color, close_icon_handle.extent());
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
            if (video_encoder.state == .encoding) "Stop" else "Record",
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
