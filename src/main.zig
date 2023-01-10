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

var record_button_color_normal = graphics.RGBA(f32){ .r = 0.2, .g = 0.2, .b = 0.4, .a = 1.0 };
var record_button_color_hover = graphics.RGBA(f32){ .r = 0.25, .g = 0.23, .b = 0.42, .a = 1.0 };

const WaylandAllocator = struct {
    pub const Buffer = struct {
        buffer: *wl.Buffer,
        size: u32,
        offset: u32,
        ready: u64,
    };

    mapped_memory: []align(8) u8,
    memory_pool: *wl.ShmPool,
    used: u32,

    pub fn init(initial_size: u64) !WaylandAllocator {
        const shm_name = "/wl_shm_2345";
        const fd = std.c.shm_open(
            shm_name,
            linux.O.RDWR | linux.O.CREAT,
            linux.O.EXCL,
        );

        if (fd < 0) {
            return error.OpenSharedMemoryFailed;
        }
        _ = std.c.shm_unlink(shm_name);

        const alignment_padding_bytes: usize = initial_size % std.mem.page_size;
        const allocation_size_bytes: usize = initial_size + (std.mem.page_size - alignment_padding_bytes);
        std.debug.assert(allocation_size_bytes % std.mem.page_size == 0);
        std.debug.assert(allocation_size_bytes <= std.math.maxInt(i32));

        std.log.info("Allocating {} for frames", .{std.fmt.fmtIntSizeDec(allocation_size_bytes)});

        try std.os.ftruncate(fd, allocation_size_bytes);

        const shared_memory_map = try std.os.mmap(null, allocation_size_bytes, linux.PROT.READ | linux.PROT.WRITE, linux.MAP.SHARED, fd, 0);
        const shared_memory_pool = try wl.Shm.createPool(wayland_client.shared_memory, fd, @intCast(i32, allocation_size_bytes));

        return WaylandAllocator{
            .mapped_memory = shared_memory_map[0..allocation_size_bytes],
            .memory_pool = shared_memory_pool,
            .used = 0,
        };
    }

    pub fn create(self: *@This(), width: u32, height: u32, stride: u32, format: wl.Shm.Format) !Buffer {
        std.debug.assert(width <= std.math.maxInt(i32));
        std.debug.assert(height <= std.math.maxInt(i32));
        std.debug.assert(stride <= std.math.maxInt(i32));
        const buffer = try self.memory_pool.createBuffer(
            @intCast(i32, self.used),
            @intCast(i32, width),
            @intCast(i32, height),
            @intCast(i32, stride),
            format,
        );
        const allocation_size: u32 = height * stride;
        const offset: u32 = self.used;
        self.used += allocation_size;
        return Buffer{
            .buffer = buffer,
            .size = allocation_size,
            .offset = offset,
            .ready = 0,
        };
    }

    pub fn mappedMemoryForBuffer(self: @This(), buffer: *Buffer) []u8 {
        const index_start = buffer.offset;
        const index_end = index_start + buffer.size;
        return self.mapped_memory[index_start..index_end];
    }
};

fn imageCrop(
    comptime Pixel: type,
    src_width: u32,
    crop_extent: geometry.Extent2D(u32),
    input_pixels: [*]const Pixel,
    output_pixels: [*]Pixel,
) !void {
    var y: usize = crop_extent.y;
    const y_end: usize = y + crop_extent.height;
    const row_size: usize = crop_extent.width * @sizeOf(Pixel);
    while (y < y_end) : (y += 1) {
        std.debug.assert(y < crop_extent.y + crop_extent.height);
        const src_index: usize = crop_extent.x + (y * src_width);
        const dst_index: usize = crop_extent.width * y;
        @memcpy(
            @ptrCast([*]u8, &output_pixels[dst_index]),
            @ptrCast([*]const u8, &input_pixels[src_index]),
            row_size,
        );
    }
}

fn imageCopyExact(
    comptime Pixel: type,
    src_position: geometry.Coordinates2D(u32),
    dst_position: geometry.Coordinates2D(u32),
    dimensions: geometry.Dimensions2D(u32),
    src_stride: u32,
    dst_stride: u32,
    input_pixels: [*]const Pixel,
    output_pixels: [*]Pixel,
) void {
    var y: usize = 0;
    const row_size: usize = dimensions.width * @sizeOf(Pixel);
    while (y < dimensions.height) : (y += 1) {
        const src_y = src_position.y + y;
        const dst_y = dst_position.y + y;
        const src_index = src_position.x + (src_y * src_stride);
        const dst_index = dst_position.x + (dst_y * dst_stride);
        @memcpy(
            @ptrCast([*]u8, &output_pixels[dst_index]),
            @ptrCast([*]const u8, &input_pixels[src_index]),
            row_size,
        );
    }
}

const Recorder = struct {
    const State = packed struct(u16) {
        is_recording: bool,
        init_done: bool,
        init_failed: bool,
        init_pending: bool,
        reserved: u12 = 0,
    };

    const ScreenRecordBuffer = struct {
        frame_index: u64 = std.math.maxInt(u64),
        captured_frame: *wlr.ScreencopyFrameV1,
        buffer: WaylandAllocator.Buffer,
    };

    const DisplayInfo = struct {
        width: u32,
        height: u32,
        stride: u32,
        format: wl.Shm.Format,
    };

    const FrameImage = struct {
        pixels: [*]graphics.RGBA(u8),
        width: u32,
        height: u32,
    };

    state: State,
    display_output: *wl.Output,
    screencopy_manager: *wlr.ScreencopyManagerV1,
    recording_buffers: [3]ScreenRecordBuffer,
    wayland_allocator: WaylandAllocator,
    display_info: DisplayInfo,
    start_frame_index: u64,

    pub fn isInitialized(self: *@This()) bool {
        return (self.state.is_recording or self.state.init_pending or self.state.init_done or self.state.init_failed);
    }

    pub fn init(
        recorder: *@This(),
        display_output: *wl.Output,
        screencopy_manager: *wlr.ScreencopyManagerV1,
    ) !void {
        recorder.state = .{
            .is_recording = false,
            .init_done = false,
            .init_failed = false,
            .init_pending = false,
        };
        recorder.display_output = display_output;
        recorder.screencopy_manager = screencopy_manager;

        //
        // We need to know about the display (monitor) to complete initialization. This is done in the following
        // callback and we set `init_pending` to true. Once `init_done` is set, the recorder will be ready
        // to capture and store frames. `frame` will be destroyed in the callback so we don't need to retain a handle
        //
        const frame = try screencopy_manager.captureOutput(1, display_output);
        frame.setListener(
            *Recorder,
            finishedInitializationCallback,
            recorder,
        );

        recorder.state.init_pending = true;
    }

    pub fn captureFrame(self: *@This(), frame_index: u64) !void {
        if (!self.state.is_recording)
            return error.NotInitialized;

        var buffer_ptr = blk: {
            var i: usize = 0;
            while (i < self.recording_buffers.len) : (i += 1) {
                if (self.recording_buffers[i].frame_index == std.math.maxInt(u64)) {
                    self.recording_buffers[i].frame_index = frame_index;
                    break :blk &self.recording_buffers[i];
                }
            }
            return error.NoOutputBuffers;
        };
        buffer_ptr.captured_frame = try self.screencopy_manager.captureOutput(1, self.display_output);
        buffer_ptr.captured_frame.setListener(
            *ScreenRecordBuffer,
            frameCaptureCallback,
            buffer_ptr,
        );
    }

    fn finishedInitializationCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, recorder: *Recorder) void {
        switch (event) {
            .buffer => |buffer| {
                recorder.state.init_failed = true;

                defer frame.destroy();

                recorder.display_info.width = buffer.width;
                recorder.display_info.height = buffer.height;
                recorder.display_info.stride = buffer.stride;
                recorder.display_info.format = buffer.format;

                const bytes_per_frame = buffer.stride * buffer.height;
                const pool_size_bytes = bytes_per_frame * recorder.recording_buffers.len;

                recorder.wayland_allocator = WaylandAllocator.init(pool_size_bytes) catch return;

                comptime var i: usize = 0;
                inline while (i < recorder.recording_buffers.len) : (i += 1) {
                    var buffer_ptr = &recorder.recording_buffers[i];
                    buffer_ptr.frame_index = std.math.maxInt(u64);
                    buffer_ptr.buffer = recorder.wayland_allocator.create(
                        buffer.width,
                        buffer.height,
                        buffer.stride,
                        buffer.format,
                    ) catch return;
                }

                recorder.start_frame_index = frame_count;

                recorder.state.init_failed = false;
                recorder.state.init_done = true;
            },
            else => {},
        }
    }

    fn frameCaptureCallback(frame: *wlr.ScreencopyFrameV1, event: wlr.ScreencopyFrameV1.Event, record_buffer: *ScreenRecordBuffer) void {
        switch (event) {
            .buffer_done => frame.copy(record_buffer.buffer.buffer),
            .ready => record_buffer.buffer.ready = 1,
            .failed => std.log.err("Frame capture failed", .{}),
            else => {},
        }
    }

    pub fn nextFrameImage(self: *@This(), ideal_frame_index: u64) ?FrameImage {
        var closest_frame_index: i64 = -std.math.maxInt(i64);
        var closest_buffer_index: usize = 0;
        comptime var i: usize = 0;
        inline while (i < self.recording_buffers.len) : (i += 1) {
            const buffer_ptr = &self.recording_buffers[i];
            const frame_index = buffer_ptr.frame_index;
            if (frame_index != std.math.maxInt(u64)) {
                if (frame_index <= ideal_frame_index and buffer_ptr.buffer.ready == 1) {
                    closest_frame_index = @max(@intCast(i64, frame_index), closest_frame_index);
                    closest_buffer_index = i;
                }
            }
        }

        if (closest_frame_index < 0) {
            return null;
        }

        i = 0;
        inline while (i < self.recording_buffers.len) : (i += 1) {
            const buffer_ptr = &self.recording_buffers[i];
            const frame_index = buffer_ptr.frame_index;
            if (frame_index < closest_frame_index) {
                buffer_ptr.frame_index = std.math.maxInt(u64);
                buffer_ptr.captured_frame.destroy();
            }
        }

        var buffer_ptr = &self.recording_buffers[closest_buffer_index];
        var frame_image: FrameImage = undefined;
        frame_image.width = self.display_info.width;
        frame_image.height = self.display_info.height;

        const buffer_memory = self.wayland_allocator.mappedMemoryForBuffer(&buffer_ptr.buffer);
        std.debug.assert(buffer_memory.len == 1920 * 1080 * 4);
        const alignment = @alignOf(graphics.RGBA(u8));
        frame_image.pixels = @ptrCast([*]graphics.RGBA(u8), @alignCast(alignment, buffer_memory.ptr));

        buffer_ptr.frame_index = std.math.maxInt(u64);

        return frame_image;
    }
};

var screen_recorder: Recorder = undefined;

//
// Text Rendering
//

var texture_atlas: Atlas = undefined;
var font: Font = undefined;
var pen: Font.Pen = undefined;
const asset_path_font = "assets/Roboto-Light.ttf";
const atlas_codepoints = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890!.%:";

var recording_frame_index: u32 = 0;

const ScreenPixelBaseType = u16;
const ScreenNormalizedBaseType = f32;

const TexturePixelBaseType = u16;
const TextureNormalizedBaseType = f32;

var record_button_opt: ?Button = null;
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

    face_writer = FaceWriter.init(graphics_context.vertices_buffer, graphics_context.indices_buffer);

    widget.init(
        &face_writer,
        face_writer.vertices,
        &mouse_coordinates,
        &screen_dimensions,
        &is_mouse_in_screen,
    );

    try appLoop(allocator, &graphics_context);
}

var screen_preview_buffer: []graphics.RGBA(u8) = undefined;
const preview_dimensions = geometry.Dimensions2D(u32){
    .width = @divExact(1920, 4),
    .height = @divExact(1080, 4),
};

var preview_quad: *QuadFace = undefined;
var preview_reserved_texture_extent: geometry.Extent2D(u32) = undefined;

fn appLoop(allocator: std.mem.Allocator, app: *GraphicsContext) !void {
    const target_ms_per_frame: u32 = 1000 / input_fps;
    const target_ns_per_frame = target_ms_per_frame * std.time.ns_per_ms;

    std.log.info("Target milliseconds / frame: {d}", .{target_ms_per_frame});

    var wayland_fd = wayland_client.display.getFd();
    var wayland_duration_total_ns: u64 = 0;

    screen_recorder.state.is_recording = false;
    screen_recorder.state.init_done = false;
    screen_recorder.state.init_pending = false;
    screen_recorder.state.init_failed = false;

    preview_reserved_texture_extent = try renderer.texture_atlas.reserve(
        geometry.Extent2D(u32),
        allocator,
        preview_dimensions.width,
        preview_dimensions.height,
    );

    screen_preview_buffer = try allocator.alloc(
        graphics.RGBA(u8),
        preview_dimensions.width * preview_dimensions.height,
    );
    defer allocator.free(screen_preview_buffer);

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
        var pollfd = linux.pollfd{
            .fd = wayland_fd,
            .events = linux.POLL.IN,
            .revents = 0,
        };
        const poll_code = linux.poll(@ptrCast([*]linux.pollfd, &pollfd), 1, timeout_milliseconds);

        if (poll_code == 0 and builtin.mode == .Debug)
            std.log.warn("wayland: Input poll timed out", .{});

        const input_available = (pollfd.revents & linux.POLL.IN) != 0;
        if (poll_code > 0 and input_available) {
            const errno = wayland_client.display.readEvents();
            if (errno != .SUCCESS)
                std.log.warn("wayland: failed reading events. Errno: {}", .{errno});
        } else {
            wayland_client.display.cancelRead();
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

        if (screen_recorder.state.is_recording) {
            if (screen_recorder.nextFrameImage(frame_count - 1)) |frame_image| {
                try screen_recorder.captureFrame(frame_count);
                var gpu_texture = try renderer.textureGet(app);
                //
                // Resize and covert from RGBA(u8) -> RGBA(f32)
                //
                {
                    var y: usize = 0;
                    while (y < preview_dimensions.height) : (y += 1) {
                        var x: usize = 0;
                        while (x < preview_dimensions.width) : (x += 1) {
                            const dst_x = x + preview_reserved_texture_extent.x;
                            const dst_y = y + preview_reserved_texture_extent.y;
                            const dst_stride = 512;
                            const dst_index = dst_x + (dst_y * dst_stride);

                            const src_index = (x * 4) + (y * 4 * frame_image.width);
                            var r_total: u16 = 0;
                            r_total += frame_image.pixels[src_index].r;
                            r_total += frame_image.pixels[src_index + 1].r;
                            r_total += frame_image.pixels[src_index + frame_image.width].r;
                            r_total += frame_image.pixels[src_index + frame_image.width + 1].r;
                            var g_total: u16 = 0;
                            g_total += frame_image.pixels[src_index].g;
                            g_total += frame_image.pixels[src_index + 1].g;
                            g_total += frame_image.pixels[src_index + frame_image.width].g;
                            g_total += frame_image.pixels[src_index + frame_image.width + 1].g;
                            var b_total: u16 = 0;
                            b_total += frame_image.pixels[src_index].b;
                            b_total += frame_image.pixels[src_index + 1].b;
                            b_total += frame_image.pixels[src_index + frame_image.width].b;
                            b_total += frame_image.pixels[src_index + frame_image.width + 1].b;

                            gpu_texture.pixels[dst_index].r = @intToFloat(f32, r_total) / (255 * 4);
                            gpu_texture.pixels[dst_index].g = @intToFloat(f32, g_total) / (255 * 4);
                            gpu_texture.pixels[dst_index].b = @intToFloat(f32, b_total) / (255 * 4);
                            gpu_texture.pixels[dst_index].a = 1.0;
                        }
                    }
                }

                try renderer.textureCommit(app);

                is_draw_required = true;
            }
        }

        if (screen_recorder.state.init_done) {
            screen_recorder.state.is_recording = true;
            screen_recorder.state.init_done = false;
            try screen_recorder.captureFrame(frame_count);
        }

        if (record_button_opt) |record_button| {
            const state = record_button.state();
            if (state.hover_enter) {
                record_button.setColor(record_button_color_hover);
            }
            if (state.hover_exit)
                record_button.setColor(record_button_color_normal);

            if (state.left_click_release) {
                if (!screen_recorder.isInitialized()) {
                    std.log.info("Recording started", .{});
                    try screen_recorder.init(
                        wayland_client.output_opt.?,
                        wayland_client.screencopy_manager,
                    );
                }
            }
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
    }

    std.log.info("Run time: {d}", .{std.fmt.fmtDuration(frame_duration_total_ns)});
    std.log.info("Frame count: {d}", .{frame_count});
    std.log.info("Slowest: {}", .{std.fmt.fmtDuration(slowest_frame_ns)});
    std.log.info("Fastest: {}", .{std.fmt.fmtDuration(fastest_frame_ns)});
    std.log.info("Average: {}", .{std.fmt.fmtDuration((frame_duration_awake_ns / frame_count))});
    const wayland_duration_average_ns = wayland_duration_total_ns / frame_count;
    std.log.info("Wayland poll average: {}", .{std.fmt.fmtDuration(wayland_duration_average_ns)});

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

fn drawScreenCapture(app: *GraphicsContext) !void {
    _ = app;

    const width: u32 = 1920;
    const height: u32 = 1080;

    if (screen_dimensions.width < @divExact(width, 4))
        return;

    const available_width = @intCast(i32, screen_dimensions.width) - 100;

    var dividor: u32 = 2;
    while (@divExact(width, dividor) > available_width)
        dividor *= 2;

    if (dividor > 4)
        return;

    const divided_width = @intToFloat(f64, @divExact(width, dividor));
    const divided_height = @intToFloat(f64, @divExact(height, dividor));

    const margin_top = 20 * screen_scale.vertical * 2.0;
    const margin_left = 20 * screen_scale.horizontal * 2.0;

    const extent = geometry.Extent2D(f32){
        .x = @floatCast(f32, -1.0 + margin_left),
        .y = @floatCast(f32, -1.0 + margin_top),
        .width = @floatCast(f32, divided_width * screen_scale.horizontal),
        .height = @floatCast(f32, divided_height * screen_scale.vertical),
    };
    const color = graphics.RGB(f32).fromInt(120, 120, 120);
    (try face_writer.create(QuadFace)).* = graphics.quadColored(extent, color.toRGBA(), .top_left);
}

fn drawTexture() !void {
    const screen_extent = geometry.Extent2D(f32){
        .x = -0.8,
        .y = 0.8,
        .width = @floatCast(f32, 512 * screen_scale.horizontal),
        .height = @floatCast(f32, 512 * screen_scale.vertical),
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

/// Our example draw function
/// This will run anytime the screen is resized
fn draw(allocator: std.mem.Allocator, app: *GraphicsContext) !void {
    face_writer.reset();

    if (screen_recorder.state.is_recording) {
        preview_quad = try face_writer.create(QuadFace);
        const preview_extent = geometry.Extent2D(f32){
            .x = -0.4,
            .y = 0.0,
            .width = @floatCast(f32, @intToFloat(f64, preview_dimensions.width) * screen_scale.horizontal),
            .height = @floatCast(f32, @intToFloat(f64, preview_dimensions.height) * screen_scale.vertical),
        };
        const preview_texture_extent = geometry.Extent2D(f32){
            .x = @intToFloat(f32, preview_reserved_texture_extent.x) / 512,
            .y = @intToFloat(f32, preview_reserved_texture_extent.y) / 512,
            .width = @intToFloat(f32, preview_reserved_texture_extent.width) / 512,
            .height = @intToFloat(f32, preview_reserved_texture_extent.height) / 512,
        };
        preview_quad.* = graphics.quadTextured(
            preview_extent,
            preview_texture_extent,
            .bottom_left,
        );
    }

    if (record_button_opt == null) {
        record_button_opt = try Button.create();
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
            const width_pixels = @intToFloat(f32, add_icon.width());
            const height_pixels = @intToFloat(f32, add_icon.height());
            const extent = geometry.Extent2D(f32){
                .x = 0.4,
                .y = 0.8,
                .width = @floatCast(f32, width_pixels * screen_scale.horizontal),
                .height = @floatCast(f32, height_pixels * screen_scale.vertical),
            };
            try image_button.draw(extent, image_button_background_color, add_icon.extent());
        }
    }

    if (record_button_opt) |*record_button| {
        const width_pixels: f32 = 200;
        const height_pixels: f32 = 40;
        const extent = geometry.Extent2D(f32){
            .x = 0.0,
            .y = 0.8,
            .width = @floatCast(f32, width_pixels * screen_scale.horizontal),
            .height = @floatCast(f32, height_pixels * screen_scale.vertical),
        };
        try record_button.draw(
            extent,
            record_button_color_normal,
            "Record",
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
            if (!is_mouse_in_screen)
                return;

            const motion_mouse_x = motion.surface_x.toDouble();
            const motion_mouse_y = motion.surface_y.toDouble();

            if (motion_mouse_x > std.math.maxInt(u16) or motion_mouse_y > std.math.maxInt(u16))
                return;

            const pixel_x = @floatToInt(i32, @floor(motion_mouse_x));
            const pixel_y = @floatToInt(i32, @floor(motion_mouse_y));

            if (pixel_x > screen_dimensions.width or motion_mouse_x < 0)
                return;

            if (pixel_y > screen_dimensions.height or motion_mouse_y < 0)
                return;

            mouse_coordinates.x = motion_mouse_x;
            mouse_coordinates.y = motion_mouse_y;

            event_system.handleMouseMovement(&.{
                .x = -1.0 + (mouse_coordinates.x * screen_scale.horizontal),
                .y = -1.0 + (mouse_coordinates.y * screen_scale.vertical),
            });

            if (!draw_window_decorations_requested)
                return;

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

            const mouse_button = @intToEnum(event_system.MouseButton, button.button);
            {
                const mouse_x = @floatToInt(u16, mouse_coordinates.x);
                const mouse_y = @floatToInt(u16, mouse_coordinates.y);
                std.log.info("Mouse coords: {d}, {d}. Screen {d}, {d}", .{ mouse_x, mouse_y, screen_dimensions.width, screen_dimensions.height });
                if (mouse_x < 3 and mouse_y < 3) {
                    client.xdg_toplevel.resize(client.seat, button.serial, .bottom_left);
                }

                event_system.handleMouseClick(
                    &.{
                        .x = -1.0 + (mouse_coordinates.x * screen_scale.horizontal),
                        .y = -1.0 + (mouse_coordinates.y * screen_scale.vertical),
                    },
                    mouse_button,
                    button.state,
                );

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

fn lerp(from: f32, to: f32, value: f32) f32 {
    return from + (value * (to - from));
}
