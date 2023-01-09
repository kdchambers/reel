// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const vulkan_config = @import("vulkan_config.zig");
const linux = std.os.linux;
const img = @import("zigimg");

const geometry = @import("geometry.zig");

const fontana = @import("fontana");
const Atlas = fontana.Atlas;
const Font = fontana.Font(.freetype_harfbuzz, .{
    .Extent2DPixel = geometry.Extent2D(u32),
    .Extent2DNative = geometry.Extent2D(f32),
    .Coordinates2DNative = geometry.Coordinates2D(f32),
    .Scale2D = geometry.ScaleFactor2D(f64),
});

const event_system = @import("event_system.zig");

const graphics = @import("graphics.zig");
const QuadFace = graphics.QuadFace;
const FaceWriter = graphics.FaceWriter;

const widget = @import("widgets.zig");
const renderer = @import("renderer.zig");

const gui = @import("app_interface.zig");

const Button = widget.Button;
const ImageButton = widget.ImageButton;

const texture_layer_dimensions = renderer.texture_layer_dimensions;
const GraphicsContext = renderer.GraphicsContext;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;
const wlr = wayland.client.zwlr;

const clib = @cImport({
    @cInclude("dlfcn.h");
});

/// Change this to force the log level. Otherwise it is determined by release mode
pub const log_level: std.log.Level = .info;

/// Screen dimensions of the application, as reported by wayland
/// Initial values are arbirary and will be updated once the wayland
/// server reports a change
var screen_dimensions = geometry.Dimensions2D(ScreenPixelBaseType){
    .width = 1040,
    .height = 640,
};

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

/// How many times the main loop should check for updates per second
/// NOTE: This does not refer to how many times the screen is drawn to. That is driven by the
///       `frameListener` callback that the wayland compositor will trigger when it's ready for
///       another image. In present mode FIFO this should correspond to the monitors display rate
///       using v-sync.
///       However, `input_fps` can be used to limit / reduce the display refresh rate
const input_fps: u32 = 15;

const output_file_path = "screencast.mp4";

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

var face_writer: FaceWriter = undefined;

var is_draw_required: bool = true;
var is_render_requested: bool = true;
var is_shutdown_requested: bool = false;

/// Set when command buffers need to be (re)recorded. The following will cause that to happen
///   1. First command buffer recording
///   2. Screen resized
///   3. Push constants need to be updated
///   4. Number of vertices to be drawn has changed
var is_record_requested: bool = true;

var framebuffer_resized: bool = true;

var wayland_client: WaylandClient = undefined;

var mouse_coordinates = geometry.Coordinates2D(f64){ .x = 0.0, .y = 0.0 };
var is_mouse_in_screen = false;

var draw_window_decorations_requested: bool = true;

// Used to collecting some basic performance data
var frame_count: u64 = 0;
var slowest_frame_ns: u64 = 0;
var fastest_frame_ns: u64 = std.math.maxInt(u64);
var frame_duration_total_ns: u64 = 0;
var frame_duration_awake_ns: u64 = 0;

/// When clicked, terminate the application
var exit_button_extent: geometry.Extent2D(u16) = undefined;
var exit_button_background_quad: *graphics.QuadFace = undefined;
var exit_button_hovered: bool = false;

var screen_scale: geometry.ScaleFactor2D(f64) = undefined;

var test_button_color_normal = graphics.RGBA(f32){ .r = 0.2, .g = 0.2, .b = 0.4, .a = 1.0 };
var test_button_color_hover = graphics.RGBA(f32){ .r = 0.25, .g = 0.23, .b = 0.42, .a = 1.0 };

//
// Text Rendering
//

var texture_atlas: Atlas = undefined;
var font: Font = undefined;
var pen: Font.Pen = undefined;
const asset_path_font = "assets/Roboto-Light.ttf";
const atlas_codepoints = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890!.%:";

//
// Screen Recording
//

const screenshot_required_bytes: usize = 1920 * 1080 * 4;

var screen_capture_info: ScreenCaptureInfo = undefined;
var shared_memory_pool: *wl.ShmPool = undefined;
var shared_memory_map: []align(std.mem.page_size) u8 = undefined;
var write_screenshot_thread_opt: ?std.Thread = null;
var screenshot_count: u32 = 0;

var is_record_start_requested: bool = false;
var is_record_stop_requested: bool = false;
var is_recording: bool = false;
var recording_frame_index: u32 = 0;
var frame_index: u32 = 0;

var screen_record_buffers = [1]ScreenRecordBuffer{.{}} ** 10;

const ScreenPixelBaseType = u16;
const ScreenNormalizedBaseType = f32;

const TexturePixelBaseType = u16;
const TextureNormalizedBaseType = f32;

const ScreenRecordBuffer = struct {
    frame_index: u32 = std.math.maxInt(u32),
    buffer_index: u32 = std.math.maxInt(u32),
    captured_frame: *wlr.ScreencopyFrameV1 = undefined,
    buffer: *wl.Buffer = undefined,
};

const ScreenCaptureInfo = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: wl.Shm.Format,
};

var example_button_opt: ?Button = null;
var image_button_opt: ?ImageButton = null;
var add_icon_opt: ?renderer.ImageHandle = null;

var image_button_background_color = graphics.RGBA(f32){ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1.0 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = gpa.allocator();

    font = try Font.initFromFile(allocator, asset_path_font);
    defer font.deinit(allocator);

    texture_atlas = try Atlas.init(allocator, 512);
    defer texture_atlas.deinit(allocator);

    event_system.init() catch |err| {
        std.log.err("Failed to initialize the event system. Error: {}", .{err});
        return error.InitializeEventSystemFailed;
    };

    var graphics_context: GraphicsContext = undefined;

    try waylandSetup();

    try renderer.init(
        allocator,
        &graphics_context,
        screen_dimensions,
        @ptrCast(*renderer.Display, wayland_client.display),
        @ptrCast(*renderer.Surface, wayland_client.surface),
        &texture_atlas,
    );
    defer renderer.deinit(allocator, &graphics_context);

    {
        const PixelType = graphics.RGBA(f32);
        const points_per_pixel = 100;
        const font_size = fontana.Size{ .point = 18.0 };
        var loaded_texture = try renderer.textureGet(&graphics_context);
        std.debug.assert(loaded_texture.width == loaded_texture.height);
        pen = try font.createPen(
            PixelType,
            allocator,
            font_size,
            points_per_pixel,
            atlas_codepoints,
            loaded_texture.width,
            loaded_texture.pixels,
            &texture_atlas,
        );
        try renderer.textureCommit(&graphics_context);
    }
    defer pen.deinit(allocator);

    const shm_name = "/wl_shm_2345";
    const fd = std.c.shm_open(
        shm_name,
        linux.O.RDWR | linux.O.CREAT,
        linux.O.EXCL,
    );

    if (fd < 0) {
        std.log.err("Failed to open shm. Error code {d}", .{fd});
        return;
    }
    _ = std.c.shm_unlink(shm_name);

    const required_bytes: usize = screenshot_required_bytes * screen_record_buffers.len;
    const alignment_padding_bytes: usize = required_bytes % std.mem.page_size;
    const allocation_size_bytes: usize = required_bytes + (std.mem.page_size - alignment_padding_bytes);

    std.debug.assert(allocation_size_bytes % std.mem.page_size == 0);

    try std.os.ftruncate(fd, allocation_size_bytes);

    shared_memory_map = try std.os.mmap(null, allocation_size_bytes, linux.PROT.READ | linux.PROT.WRITE, linux.MAP.SHARED, fd, 0);
    shared_memory_pool = try wl.Shm.createPool(wayland_client.shared_memory, fd, allocation_size_bytes);

    var buffer_index: usize = 0;
    while (buffer_index < screen_record_buffers.len) : (buffer_index += 1) {
        screen_record_buffers[buffer_index].buffer = try shared_memory_pool.createBuffer(
            @intCast(i32, buffer_index * screenshot_required_bytes),
            1920,
            1080,
            1920 * 4,
            .xbgr8888,
        );
    }

    face_writer = FaceWriter.init(graphics_context.vertices_buffer, graphics_context.indices_buffer);

    widget.init(
        &face_writer,
        face_writer.vertices,
        &mouse_coordinates,
        &screen_dimensions,
        &is_mouse_in_screen,
    );

    try appLoop(allocator, &graphics_context);

    if (write_screenshot_thread_opt) |write_screenshot_thread| {
        std.log.info("Waiting for screenshot writer thread to complete", .{});
        write_screenshot_thread.join();
    }
}

fn appLoop(allocator: std.mem.Allocator, app: *GraphicsContext) !void {
    const target_ms_per_frame: u32 = 1000 / input_fps;
    const target_ns_per_frame = target_ms_per_frame * std.time.ns_per_ms;

    std.log.info("Target milliseconds / frame: {d}", .{target_ms_per_frame});

    var wayland_fd = wayland_client.display.getFd();
    var wayland_duration_total_ns: u64 = 0;

    while (!is_shutdown_requested) {
        frame_count += 1;

        const frame_start_ns = std.time.nanoTimestamp();

        // NOTE: Running this at a high `input_fps` (E.g 60) seems to put a lot of strain on
        //       the wayland compositor. On my system with sway and river I've seen the
        //       CPU usage of the compositor run 3 times that of this application in response
        //       to this call alone.
        // TODO: Find a more efficient way to interact with the compositor if possible

        while (!wayland_client.display.prepareRead()) {
            //
            // Client event queue should be empty before calling `prepareRead`
            // As a result this shouldn't happen but is just a safegaurd
            //
            _ = wayland_client.display.dispatchPending();
        }
        //
        // Flush Display write buffer -> Compositor
        //
        _ = wayland_client.display.flush();

        const timeout_milliseconds = 5;
        const ret = linux.poll(@ptrCast([*]linux.pollfd, &wayland_fd), 1, timeout_milliseconds);

        if (ret != linux.POLL.IN) {
            std.log.warn("wayland: read cancelled. Unexpected poll code: {}", .{ret});
            wayland_client.display.cancelRead();
        } else {
            const errno = wayland_client.display.readEvents();
            if (errno != .SUCCESS)
                std.log.warn("wayland: failed reading events. Errno: {}", .{errno});
        }

        _ = wayland_client.display.dispatchPending();

        const wayland_poll_end = std.time.nanoTimestamp();
        wayland_duration_total_ns += @intCast(u64, wayland_poll_end - frame_start_ns);

        if (framebuffer_resized) {
            app.swapchain_extent.width = screen_dimensions.width;
            app.swapchain_extent.height = screen_dimensions.height;
            is_draw_required = true;
            framebuffer_resized = false;
            try renderer.recreateSwapchain(allocator, app, screen_dimensions);
        }

        if (example_button_opt) |example_button| {
            var state = example_button.state();
            if (state.hover_enter) {
                example_button.setColor(test_button_color_hover);
                std.log.info("Hover enter", .{});
            }
            if (state.hover_exit)
                example_button.setColor(test_button_color_normal);

            state.clear();
        }

        if (is_draw_required) {
            is_draw_required = false;
            try draw(allocator, app);
            is_render_requested = true;
            is_record_requested = true;
        }

        if (is_render_requested) {
            is_render_requested = false;

            // Even though we're running at a constant loop, we don't always need to re-record command buffers
            if (is_record_requested) {
                is_record_requested = false;
                try renderer.recordRenderPass(app.*, face_writer.indices_used, screen_dimensions);
            }

            try renderer.renderFrame(allocator, app, screen_dimensions);
        }

        if (is_recording) {
            var buffer_index: usize = 0;
            while (buffer_index < screen_record_buffers.len) : (buffer_index += 1) {
                if (screen_record_buffers[buffer_index].frame_index == std.math.maxInt(u32))
                    break;
            }
            if (buffer_index == screen_record_buffers.len) {
                std.log.warn("No available buffers to record screen frame. Skipping", .{});
            } else {
                const output = wayland_client.output_opt.?;
                const screen_frame_opt: ?*wlr.ScreencopyFrameV1 = wayland_client.screencopy_manager.captureOutput(1, output) catch |err| blk: {
                    std.log.warn("Failed to capture wayland output. Error: {}", .{err});
                    break :blk null;
                };
                if (screen_frame_opt) |screen_frame| {
                    screen_record_buffers[buffer_index].buffer_index = @intCast(u32, buffer_index);
                    screen_record_buffers[buffer_index].frame_index = recording_frame_index;
                    screen_record_buffers[buffer_index].captured_frame = screen_frame;
                    screen_record_buffers[buffer_index].captured_frame.setListener(
                        *ScreenRecordBuffer,
                        screencopyFrameListener,
                        &screen_record_buffers[buffer_index],
                    );
                }
            }
        }

        const frame_end_ns = std.time.nanoTimestamp();
        std.debug.assert(frame_end_ns >= frame_start_ns);

        const frame_duration_ns = @intCast(u64, frame_end_ns - frame_start_ns);

        if (frame_duration_ns > slowest_frame_ns) {
            slowest_frame_ns = frame_duration_ns;
        }

        if (frame_duration_ns < fastest_frame_ns) {
            fastest_frame_ns = frame_duration_ns;
        }

        std.debug.assert(target_ns_per_frame > frame_duration_ns);
        const remaining_ns: u64 = target_ns_per_frame - @intCast(u64, frame_duration_ns);
        std.debug.assert(remaining_ns <= target_ns_per_frame);

        const frame_work_completed_ns = std.time.nanoTimestamp();
        frame_duration_awake_ns += @intCast(u64, frame_work_completed_ns - frame_start_ns);

        std.time.sleep(remaining_ns);

        const frame_completion_ns = std.time.nanoTimestamp();
        frame_duration_total_ns += @intCast(u64, frame_completion_ns - frame_start_ns);

        frame_index += 1;

        if (is_recording) {
            recording_frame_index += 1;
        }

        //
        // Recording functionality disabled
        //

        // const frame_start = input_fps * 5;
        // const frame_end = frame_start + (input_fps * 5);
        // if(frame_index == frame_start) {
        //     is_recording = true;
        //     recording_frame_index = 0;
        //     std.log.info("Recording started", .{});
        // }

        // if(is_recording and frame_index >= frame_end) {
        //     is_record_stop_requested = true;
        // }

        // if(is_record_stop_requested) {
        //     std.log.info("Recording stopped", .{});
        //     is_record_stop_requested = false;
        //     is_recording = false;
        // }
    }

    std.log.info("Run time: {d}", .{std.fmt.fmtDuration(frame_duration_total_ns)});
    std.log.info("Frame count: {d}", .{frame_count});
    std.log.info("Slowest: {}", .{std.fmt.fmtDuration(slowest_frame_ns)});
    std.log.info("Fastest: {}", .{std.fmt.fmtDuration(fastest_frame_ns)});
    std.log.info("Average: {}", .{std.fmt.fmtDuration((frame_duration_awake_ns / frame_count))});
    const wayland_duration_average_ns = wayland_duration_total_ns / frame_count;
    std.log.info("Wayland poll average: {}", .{std.fmt.fmtDuration(wayland_duration_average_ns)});
    const runtime_seconds = @intToFloat(f64, frame_duration_total_ns) / std.time.ns_per_s;
    const screenshots_per_sec = @intToFloat(f64, screenshot_count) / runtime_seconds;
    std.log.info("Screenshot count: {d} ({d:.2} / sec)", .{ screenshot_count, screenshots_per_sec });

    try app.device_dispatch.deviceWaitIdle(app.logical_device);
}

// TODO:
fn drawDecorations() void {
    if (draw_window_decorations_requested) {
        var faces = try face_writer.allocate(3, QuadFace);
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
            std.debug.assert(window_decorations.exit_button.size_pixels <= window_decorations.height_pixels);
            const screen_icon_dimensions = geometry.Dimensions2D(f32){
                .width = @intToFloat(f32, window_decorations.exit_button.size_pixels * 2) / @intToFloat(f32, screen_dimensions.width),
                .height = @intToFloat(f32, window_decorations.exit_button.size_pixels * 2) / @intToFloat(f32, screen_dimensions.height),
            };
            const exit_button_outer_margin_pixels = @intToFloat(f32, window_decorations.height_pixels - window_decorations.exit_button.size_pixels) / 2.0;
            const outer_margin_hor = exit_button_outer_margin_pixels * 2.0 / @intToFloat(f32, screen_dimensions.width);
            const outer_margin_ver = exit_button_outer_margin_pixels * 2.0 / @intToFloat(f32, screen_dimensions.height);
            const texture_coordinates = iconTextureLookup(.close);
            const texture_extent = geometry.Extent2D(f32){
                .x = texture_coordinates.x,
                .y = texture_coordinates.y,
                .width = @intToFloat(f32, icon_dimensions.width) / @intToFloat(f32, texture_layer_dimensions.width),
                .height = @intToFloat(f32, icon_dimensions.height) / @intToFloat(f32, texture_layer_dimensions.height),
            };
            const extent = geometry.Extent2D(f32){
                .x = 1.0 - (outer_margin_hor + screen_icon_dimensions.width),
                .y = -1.0 + outer_margin_ver,
                .width = screen_icon_dimensions.width,
                .height = screen_icon_dimensions.height,
            };
            faces[1] = graphics.quadColored(extent, window_decorations.color, .top_left);
            faces[2] = graphics.quadTextured(extent, texture_extent, .top_left);

            // TODO: Update on screen size change
            const exit_button_extent_outer_margin = @divExact(window_decorations.height_pixels - window_decorations.exit_button.size_pixels, 2);
            exit_button_extent = geometry.Extent2D(u16){ // Top left anchor
                .x = screen_dimensions.width - (window_decorations.exit_button.size_pixels + exit_button_extent_outer_margin),
                .y = screen_dimensions.height - (window_decorations.exit_button.size_pixels + exit_button_extent_outer_margin),
                .width = window_decorations.exit_button.size_pixels,
                .height = window_decorations.exit_button.size_pixels,
            };
            exit_button_background_quad = &faces[1];
        }
    }
}

/// Our example draw function
/// This will run anytime the screen is resized
fn draw(allocator: std.mem.Allocator, app: *GraphicsContext) !void {
    face_writer.reset();

    {
        const extent = geometry.Extent2D(f32){
            .x = -0.5,
            .y = -0.2,
            .width = @floatCast(f32, 200 * screen_scale.horizontal),
            .height = @floatCast(f32, 60 * screen_scale.vertical),
        };
        try widget.drawRoundRect(extent, image_button_background_color, screen_scale, 10);
    }

    try gui.drawBottomBar(&face_writer, screen_scale, &pen);

    if (example_button_opt == null) {
        example_button_opt = try Button.create();
    }

    if (image_button_opt == null) {
        image_button_opt = try ImageButton.create();

        var icon = try img.Image.fromFilePath(allocator, icon_path_list[0]);
        defer icon.deinit();

        add_icon_opt = try renderer.addTexture(
            app,
            allocator,
            @intCast(u32, icon.width),
            @intCast(u32, icon.height),
            @ptrCast([*]graphics.RGBA(u8), icon.pixels.rgba32.ptr),
        );
    }

    if (image_button_opt) |*image_button| {
        if (add_icon_opt) |add_icon| {
            std.log.info("Drawing image button", .{});
            const width_pixels = @intToFloat(f32, add_icon.width());
            const height_pixels = @intToFloat(f32, add_icon.height());
            const extent = geometry.Extent2D(f32){
                .x = 0.4,
                .y = 0.0,
                .width = @floatCast(f32, width_pixels * screen_scale.horizontal),
                .height = @floatCast(f32, height_pixels * screen_scale.vertical),
            };
            try image_button.draw(extent, image_button_background_color, add_icon.extent());
        }
    }

    if (example_button_opt) |*example_button| {
        const width_pixels: f32 = 200;
        const height_pixels: f32 = 40;
        const extent = geometry.Extent2D(f32){
            .x = 0.0,
            .y = 0.0,
            .width = @floatCast(f32, width_pixels * screen_scale.horizontal),
            .height = @floatCast(f32, height_pixels * screen_scale.vertical),
        };
        try example_button.draw(
            extent,
            test_button_color_normal,
            "start",
            &pen,
            screen_scale,
            .{ .rounding_radius = 5 },
        );
    }
}

//
// Wayland Types + Functions
//

const WaylandClient = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: *wl.Compositor,
    xdg_wm_base: *xdg.WmBase,
    surface: *wl.Surface,
    seat: *wl.Seat,
    pointer: *wl.Pointer,
    frame_callback: *wl.Callback,
    xdg_toplevel: *xdg.Toplevel,
    xdg_surface: *xdg.Surface,
    screencopy_manager: *wlr.ScreencopyManagerV1,
    output_opt: ?*wl.Output,

    cursor_theme: *wl.CursorTheme,
    cursor: *wl.Cursor,
    cursor_surface: *wl.Surface,
    xcursor: [:0]const u8,
    shared_memory: *wl.Shm,
};

const XCursor = struct {
    const hidden = "hidden";
    const left_ptr = "left_ptr";
    const text = "text";
    const xterm = "xterm";
    const hand2 = "hand2";
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
const MouseButton = enum(c_int) { left = 0x110, right = 0x111, middle = 0x112, _ };

fn xdgWmBaseListener(xdg_wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *WaylandClient) void {
    switch (event) {
        .ping => |ping| {
            xdg_wm_base.pong(ping.serial);
        },
    }
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, surface: *wl.Surface) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            surface.commit();
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, close_requested: *bool) void {
    switch (event) {
        .configure => |configure| {
            if (configure.width > 0 and configure.width != screen_dimensions.width) {
                framebuffer_resized = true;
                screen_dimensions.width = @intCast(u16, configure.width);
                screen_scale.horizontal = 2.0 / @intToFloat(f64, screen_dimensions.width);
            }
            if (configure.height > 0 and configure.height != screen_dimensions.height) {
                framebuffer_resized = true;
                screen_dimensions.height = @intCast(u16, configure.height);
                screen_scale.vertical = 2.0 / @intToFloat(f64, screen_dimensions.height);
            }
        },
        .close => close_requested.* = true,
    }
}

fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, client: *WaylandClient) void {
    switch (event) {
        .done => {
            is_render_requested = true;
            callback.destroy();
            client.frame_callback = client.surface.frame() catch |err| {
                std.log.err("Failed to create new wayland frame -> {}", .{err});
                return;
            };
            client.frame_callback.setListener(*WaylandClient, frameListener, client);
        },
    }
}

fn shmListener(shm: *wl.Shm, event: wl.Shm.Event, client: *WaylandClient) void {
    _ = client;
    _ = shm;
    switch (event) {
        .format => |format| {
            std.log.info("Shm foramt: {}", .{format});
        },
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, client: *WaylandClient) void {
    switch (event) {
        .enter => |enter| {
            is_mouse_in_screen = true;
            mouse_coordinates.x = enter.surface_x.toDouble();
            mouse_coordinates.y = enter.surface_y.toDouble();

            //
            // When mouse enters application surface, update the cursor image
            //
            const image = client.cursor.images[0];
            const image_buffer = image.getBuffer() catch return;
            client.cursor_surface.attach(image_buffer, 0, 0);
            client.pointer.setCursor(enter.serial, client.cursor_surface, @intCast(i32, image.hotspot_x), @intCast(i32, image.hotspot_y));
            client.cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            client.cursor_surface.commit();
        },
        .leave => |leave| {
            _ = leave;
            is_mouse_in_screen = false;
        },
        .motion => |motion| {
            mouse_coordinates.x = motion.surface_x.toDouble();
            mouse_coordinates.y = motion.surface_y.toDouble();

            event_system.handleMouseMovement(&.{
                .x = -1.0 + (mouse_coordinates.x * screen_scale.horizontal),
                .y = -1.0 + (mouse_coordinates.y * screen_scale.vertical),
            });

            if (!draw_window_decorations_requested)
                return;

            std.debug.assert(false);

            if (@floatToInt(u16, mouse_coordinates.y) > screen_dimensions.height or @floatToInt(u16, mouse_coordinates.x) > screen_dimensions.width) {
                return;
            }

            const end_x = exit_button_extent.x + exit_button_extent.width;
            const end_y = exit_button_extent.y + exit_button_extent.height;
            const mouse_x = @floatToInt(u16, mouse_coordinates.x);
            const mouse_y = screen_dimensions.height - @floatToInt(u16, mouse_coordinates.y);
            const is_within_bounds = (mouse_x >= exit_button_extent.x and mouse_y >= exit_button_extent.y and mouse_x <= end_x and mouse_y <= end_y);

            if (is_within_bounds and !exit_button_hovered) {
                exit_button_background_quad[0].color = window_decorations.exit_button.color_hovered;
                exit_button_background_quad[1].color = window_decorations.exit_button.color_hovered;
                exit_button_background_quad[2].color = window_decorations.exit_button.color_hovered;
                exit_button_background_quad[3].color = window_decorations.exit_button.color_hovered;
                is_render_requested = true;
                exit_button_hovered = true;
            }

            if (!is_within_bounds and exit_button_hovered) {
                exit_button_background_quad[0].color = window_decorations.color;
                exit_button_background_quad[1].color = window_decorations.color;
                exit_button_background_quad[2].color = window_decorations.color;
                exit_button_background_quad[3].color = window_decorations.color;
                is_render_requested = true;
                exit_button_hovered = false;
            }
        },
        .button => |button| {
            if (!is_mouse_in_screen) {
                return;
            }

            const mouse_button = @intToEnum(MouseButton, button.button);
            {
                const mouse_x = @floatToInt(u16, mouse_coordinates.x);
                const mouse_y = @floatToInt(u16, mouse_coordinates.y);
                std.log.info("Mouse coords: {d}, {d}. Screen {d}, {d}", .{ mouse_x, mouse_y, screen_dimensions.width, screen_dimensions.height });
                if (mouse_x < 3 and mouse_y < 3) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .bottom_left);
                }

                const edge_threshold = 3;
                const max_width = screen_dimensions.width - edge_threshold;
                const max_height = screen_dimensions.height - edge_threshold;

                if (mouse_x < edge_threshold and mouse_y > max_height) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .top_left);
                    return;
                }

                if (mouse_x > max_width and mouse_y < edge_threshold) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .bottom_right);
                    return;
                }

                if (mouse_x > max_width and mouse_y > max_height) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .bottom_right);
                    return;
                }

                if (mouse_x < edge_threshold) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .left);
                    return;
                }

                if (mouse_x > max_width) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .right);
                    return;
                }

                if (mouse_y <= edge_threshold) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .top);
                    return;
                }

                if (mouse_y == max_height) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .bottom);
                    return;
                }
            }

            if (@floatToInt(u16, mouse_coordinates.y) > screen_dimensions.height or @floatToInt(u16, mouse_coordinates.x) > screen_dimensions.width) {
                return;
            }

            if (draw_window_decorations_requested and mouse_button == .left) {
                // Start interactive window move if mouse coordinates are in window decorations bounds
                if (@floatToInt(u32, mouse_coordinates.y) <= window_decorations.height_pixels) {
                    client.xdg_toplevel.move(client.seat, button.serial);
                }
                const end_x = exit_button_extent.x + exit_button_extent.width;
                const end_y = exit_button_extent.y + exit_button_extent.height;
                const mouse_x = @floatToInt(u16, mouse_coordinates.x);
                const mouse_y = screen_dimensions.height - @floatToInt(u16, mouse_coordinates.y);
                const is_within_bounds = (mouse_x >= exit_button_extent.x and mouse_y >= exit_button_extent.y and mouse_x <= end_x and mouse_y <= end_y);
                if (is_within_bounds) {
                    std.log.info("Close button clicked. Shutdown requested.", .{});
                    is_shutdown_requested = true;
                }
            }
        },
        .axis => |axis| {
            std.log.info("Mouse: axis {} {}", .{ axis.axis, axis.value.toDouble() });
        },
        .frame => |frame| {
            _ = frame;
        },
        .axis_source => |axis_source| {
            std.log.info("Mouse: axis_source {}", .{axis_source.axis_source});
        },
        .axis_stop => |axis_stop| {
            _ = axis_stop;
            std.log.info("Mouse: axis_stop", .{});
        },
        .axis_discrete => |axis_discrete| {
            _ = axis_discrete;
            std.log.info("Mouse: axis_discrete", .{});
        },
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, client: *WaylandClient) void {
    switch (event) {
        .global => |global| {
            std.log.info("Wayland: {s}", .{global.interface});
            if (std.cstr.cmp(global.interface, wl.Compositor.getInterface().name) == 0) {
                client.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (std.cstr.cmp(global.interface, xdg.WmBase.getInterface().name) == 0) {
                client.xdg_wm_base = registry.bind(global.name, xdg.WmBase, 3) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Seat.getInterface().name) == 0) {
                client.seat = registry.bind(global.name, wl.Seat, 5) catch return;
                client.pointer = client.seat.getPointer() catch return;
                client.pointer.setListener(*WaylandClient, pointerListener, &wayland_client);
            } else if (std.cstr.cmp(global.interface, wl.Shm.getInterface().name) == 0) {
                client.shared_memory = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.cstr.cmp(global.interface, wlr.ScreencopyManagerV1.getInterface().name) == 0) {
                client.screencopy_manager = registry.bind(global.name, wlr.ScreencopyManagerV1, 3) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                client.output_opt = registry.bind(global.name, wl.Output, 3) catch return;
            } else if (std.cstr.cmp(global.interface, zxdg.DecorationManagerV1.getInterface().name) == 0) {
                //
                // TODO: Negociate with compositor how the window decorations will be drawn
                //
                draw_window_decorations_requested = false;
            }
        },
        .global_remove => {},
    }
}

fn waylandSetup() !void {
    wayland_client.display = try wl.Display.connect(null);
    wayland_client.registry = try wayland_client.display.getRegistry();

    wayland_client.registry.setListener(*WaylandClient, registryListener, &wayland_client);

    if (wayland_client.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    wayland_client.xdg_wm_base.setListener(*WaylandClient, xdgWmBaseListener, &wayland_client);

    wayland_client.surface = try wayland_client.compositor.createSurface();

    wayland_client.xdg_surface = try wayland_client.xdg_wm_base.getXdgSurface(wayland_client.surface);
    wayland_client.xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, wayland_client.surface);

    wayland_client.xdg_toplevel = try wayland_client.xdg_surface.getToplevel();
    wayland_client.xdg_toplevel.setListener(*bool, xdgToplevelListener, &is_shutdown_requested);

    wayland_client.frame_callback = try wayland_client.surface.frame();
    wayland_client.frame_callback.setListener(*WaylandClient, frameListener, &wayland_client);

    wayland_client.shared_memory.setListener(*WaylandClient, shmListener, &wayland_client);

    wayland_client.xdg_toplevel.setTitle(application_name);
    wayland_client.surface.commit();

    if (wayland_client.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    //
    // Load cursor theme
    //

    wayland_client.cursor_surface = try wayland_client.compositor.createSurface();

    const cursor_size = 24;
    wayland_client.cursor_theme = try wl.CursorTheme.load(null, cursor_size, wayland_client.shared_memory);
    wayland_client.cursor = wayland_client.cursor_theme.getCursor(XCursor.left_ptr).?;
    wayland_client.xcursor = XCursor.left_ptr;
}

//
// Screen Recording Functions
//

fn writeScreenshot() void {
    const write_screenshot_start = std.time.nanoTimestamp();
    const allocator = std.heap.c_allocator;
    const pixel_count = screen_capture_info.width * screen_capture_info.height;
    const source_image = @ptrCast([*]img.color.Rgba32, shared_memory_map.ptr)[0..pixel_count];
    var output_image = img.Image.create(allocator, screen_capture_info.width, screen_capture_info.height, .rgba32) catch |err| {
        std.log.err("Failed to create output image. Error {}", .{err});
        return;
    };
    defer output_image.deinit();
    std.mem.copy(img.color.Rgba32, output_image.pixels.rgba32, source_image);
    const screenshot_path = "./screenshot.png";
    output_image.writeToFilePath(screenshot_path, .{ .png = .{} }) catch |err| {
        std.log.err("Failed to write image to file. Error: {}", .{err});
        return;
    };
    const write_screenshot_end = std.time.nanoTimestamp();
    const write_screenshot_duration = @intCast(u64, write_screenshot_end - write_screenshot_start);
    std.log.info("Image written to file in {s}", .{std.fmt.fmtDuration(write_screenshot_duration)});
}

fn screencopyFrameListener(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, record_buffer: *ScreenRecordBuffer) void {
    switch (event) {
        .buffer => |buffer| {
            screen_capture_info.width = buffer.width;
            screen_capture_info.height = buffer.height;
            screen_capture_info.stride = buffer.stride;
            screen_capture_info.format = buffer.format;
        },
        .flags => |flags| {
            _ = flags;
        },
        .ready => |ready| {
            _ = ready;
            // writeVideoFrame(record_buffer.frame_index) catch |err| {
            //     std.log.err("Failed to write video frame. Error {}", .{err});
            // };
            record_buffer.captured_frame.destroy();
            record_buffer.frame_index = std.math.maxInt(u32);
        },
        .damage => |damage| {
            _ = damage;
        },
        .linux_dmabuf => |linux_dmabuf| {
            _ = linux_dmabuf;
        },
        .buffer_done => |buffer_done| {
            _ = buffer_done;
            frame.copy(record_buffer.buffer);
        },
        .failed => {
            std.log.err("Failed in Screencopy Frame", .{});
        },
    }
}

fn lerp(from: f32, to: f32, value: f32) f32 {
    return from + (value * (to - from));
}
