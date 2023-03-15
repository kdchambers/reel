// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const linux = std.os.linux;
const img = @import("zigimg");
const audio = @import("audio.zig");
const wayland_client = @import("wayland_client.zig");
const style = @import("app_styling.zig");
const geometry = @import("geometry.zig");
const event_system = @import("event_system.zig");
const screencast = @import("screencast.zig");
const mini_heap = @import("mini_heap.zig");
const zmath = @import("zmath");

const video_encoder = @import("video_record.zig");

const fontana = @import("fontana");
const Atlas = fontana.Atlas;
const Font = fontana.Font(.{
    .backend = .freetype_harfbuzz,
    .type_overrides = .{
        .Extent2DPixel = geometry.Extent2D(u32),
        .Extent2DNative = geometry.Extent2D(f32),
        .Coordinates2DNative = geometry.Coordinates2D(f32),
        .Scale2D = geometry.ScaleFactor2D(f64),
    },
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

var recording_timer_text_quads: ?[]QuadFace = null;
var recording_timer_placement: geometry.Coordinates2D(f32) = undefined;

const window_decorations = struct {
    const height_pixels = 30;
    const color = graphics.RGBA(f32).fromInt(u8, 200, 200, 200, 255);
    const exit_button = struct {
        const size_pixels = 24;
        const color_hovered = graphics.RGBA(f32).fromInt(u8, 180, 180, 180, 255);
    };

    var requested: bool = true;

    pub fn draw() !void {
        const screen_dimensions = wayland_client.screen_dimensions;
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
        try button_close.draw();
    }
};

const information_bar = struct {
    const height_pixels = 30;
    const background_color = graphics.RGBA(f32){
        .r = 0.175,
        .g = 0.175,
        .b = 0.175,
        .a = 1.0,
    };

    pub fn draw() !void {
        const extent = geometry.Extent2D(f32){
            .x = -1.0,
            .y = 1.0,
            .width = 2.0,
            .height = @floatCast(f32, information_bar.height_pixels * wayland_client.screen_scale.vertical),
        };
        (try face_writer.create(QuadFace)).* = graphics.quadColored(
            extent,
            information_bar.background_color,
            .bottom_left,
        );
    }
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
    const size_pixels = 16;
    const width_pixels = 2.5;
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

const TextMutaterInterface = struct {
    quads: []QuadFace,
    used: u32 = 0,

    pub fn write(
        self: *@This(),
        screen_extent: geometry.Extent2D(f32),
        texture_extent: geometry.Extent2D(f32),
    ) !void {
        if (self.used == self.quads.len)
            return error.OutOfSpace;
        self.quads[self.used] = graphics.quadTextured(
            screen_extent,
            texture_extent,
            .bottom_left,
        );
        self.used += 1;
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

var record_button_color_normal = graphics.RGBA(f32){ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };
var record_button_color_hover = graphics.RGBA(f32){ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 };

var record_start_timestamp: i128 = 0;
var record_duration: u64 = 0;

var screen_capture_bottom: f32 = 0;

//
// Text Rendering
//

var texture_atlas: Atlas = undefined;
var font: Font = undefined;

const pen_options = fontana.PenOptions{
    .pixel_format = .r32g32b32a32,
    .PixelType = graphics.RGBA(f32),
};
var pen: Font.PenConfig(pen_options) = undefined;
var pen_small: Font.PenConfig(pen_options) = undefined;

const asset_path_font = "assets/Roboto-Regular.ttf";
const atlas_codepoints = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890!.%:-/()";

const ScreenPixelBaseType = u16;
const ScreenNormalizedBaseType = f32;

const TexturePixelBaseType = u16;
const TextureNormalizedBaseType = f32;

var record_button_opt: ?Button = null;
// var image_button_opt: ?ImageButton = null;
// var add_icon_opt: ?renderer.ImageHandle = null;

var image_button_background_color = graphics.RGBA(f32){ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1.0 };

var stdlib_gpa: if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{}) else void = .{};
var general_allocator: std.mem.Allocator = undefined;

var app_runtime_start: i128 = undefined;
var top_reserved_pixels: u16 = 0;
var screencast_interface: ?screencast.Interface = null;

const Checkbox = widget.Checkbox;
var enable_preview_checkbox: ?Checkbox = null;

var gpu_texture_mutex: std.Thread.Mutex = undefined;

var audio_input_devices_opt: ?[]audio.InputDeviceInfo = null;

const StreamState = enum(u8) {
    idle,
    preview,
    record,
    record_preview,
};

var stream_state: StreamState = .idle;
var video_stream_frame_index: u32 = 0;
var close_icon_handle: renderer.ImageHandle = undefined;
var audio_input_interface: audio.Interface = undefined;
var audio_volume_level_widget: widget.AudioVolumeLevelHorizontal = undefined;

var audio_callback_count: usize = 0;
var audio_start: ?i128 = null;

const bin_count = 256;

var audio_power_table_mutex: std.Thread.Mutex = .{};
var audio_power_table = [1]zmath.F32x4{zmath.f32x4(0.0, 0.0, 0.0, 0.0)} ** (bin_count / 8);

const decibel_range_lower = -7.0;

const hamming_table: [bin_count]f32 = audio.calculateHammingWindowTable(bin_count);
var audio_spectogram_bins = [1]f32{0.00000000001} ** audio_visual_bin_count;
var audio_input_quads: ?[]graphics.QuadFace = null;
const audio_visual_bin_count = 64;
const reference_max_audio: f32 = 128.0 * 4.0;

var unity_table: [bin_count]zmath.F32x4 = undefined;
const sample_rate = 44100;
const freq_resolution: f32 = sample_rate / bin_count;

const mel_table: [audio_visual_bin_count]f32 = audio.generateMelTable(audio_visual_bin_count, freq_resolution);
const mel_upper: f32 = audio.melScale(freq_resolution * (bin_count / 2.0));

const freq_to_mel_table: [bin_count / 2]f32 = audio.calculateFreqToMelTable(bin_count / 2, freq_resolution);
const filter_spread: f32 = 4.0;

var audio_sample_ring_buffer: audio.SampleRingBuffer(f32, 2048, 20) = .{};

const preview_background_color = graphics.RGB(f32).fromInt(120, 120, 120);
const preview_background_color_recording = graphics.RGB(f32).fromInt(120, 20, 20);

var audio_input_device_list_opt: ?[]audio.InputDeviceInfo = null;

//
// TODO: This is kind of hacky
//
var audio_frame_buffer: [3]*[2048]f32 = undefined;

pub fn main() !void {
    app_runtime_start = std.time.nanoTimestamp();

    try init();
    try appLoop(general_allocator);

    deinit();
}

/// NOTE: This will be called on a separate thread
pub fn onAudioInputRead(pcm_buffer: []i16) void {
    if (audio_start == null)
        audio_start = std.time.nanoTimestamp();

    audio_power_table_mutex.lock();
    defer audio_power_table_mutex.unlock();

    const fft_overlap_samples = @divExact(bin_count, 2);
    const fft_iteration_count = ((pcm_buffer.len / 2) / (fft_overlap_samples - 1)) - 1;

    audio_power_table = [1]zmath.F32x4{zmath.f32x4(0.0, 0.0, 0.0, 0.0)} ** (bin_count / 8);

    if (stream_state == .record or stream_state == .record_preview)
        audio_sample_ring_buffer.push(pcm_buffer) catch unreachable;

    var i: usize = 0;
    while (i < fft_iteration_count) : (i += 1) {
        const vector_len: usize = @divExact(bin_count, 4);
        var complex = [1]zmath.F32x4{zmath.f32x4s(0.0)} ** vector_len;

        var fft_window = blk: {
            // TODO: Don't hardcode channel count
            const channel_count = 2;
            var result = [1]zmath.F32x4{zmath.f32x4(0.0, 0.0, 0.0, 0.0)} ** (@divExact(bin_count, 4));
            const sample_increment = fft_overlap_samples * channel_count;
            const start = sample_increment * i;
            const end = start + (bin_count * channel_count);
            const pcm_window = pcm_buffer[start..end];
            std.debug.assert(pcm_window.len == (hamming_table.len * channel_count));
            std.debug.assert(pcm_window.len % 4 == 0);
            var k: usize = 0;
            var j: usize = 0;
            for (&result) |*sample| {
                const max = std.math.maxInt(i16);
                // TODO: The indexing here is dependent on the channel count
                sample.* = .{
                    ((@intToFloat(f32, pcm_window[j + 0])) / max) * hamming_table[k + 0],
                    ((@intToFloat(f32, pcm_window[j + 2])) / max) * hamming_table[k + 1],
                    ((@intToFloat(f32, pcm_window[j + 4])) / max) * hamming_table[k + 2],
                    ((@intToFloat(f32, pcm_window[j + 6])) / max) * hamming_table[k + 3],
                };
                j += 8;
                k += 4;
            }
            break :blk result;
        };

        zmath.fft(&fft_window, &complex, &unity_table);

        for (&audio_power_table, 0..) |*value, v| {
            const complex2 = complex[v] * complex[v];
            // const real2 = fft_window[v] * fft_window[v];
            // const magnitude = zmath.sqrt(complex2 + real2);
            const magnitude = zmath.sqrt(complex2);
            value.* += magnitude;
        }
    }
    for (&audio_power_table) |*value| {
        std.debug.assert(value.*[0] >= 0.0);
        std.debug.assert(value.*[1] >= 0.0);
        std.debug.assert(value.*[2] >= 0.0);
        std.debug.assert(value.*[3] >= 0.0);
        value.* /= zmath.f32x4s(@intToFloat(f32, fft_iteration_count));
        std.debug.assert(value.*[0] >= 0.0);
        std.debug.assert(value.*[1] >= 0.0);
        std.debug.assert(value.*[2] >= 0.0);
        std.debug.assert(value.*[3] >= 0.0);
    }

    //
    // Convert to mel scale & combine bins
    //

    const usable_bin_count = (bin_count / 2);
    var mel_bins = [1]f32{0.00000000001} ** usable_bin_count;

    i = 1;
    while (i < usable_bin_count) : (i += 1) {
        const array_i = @divTrunc(i, 4);
        std.debug.assert(array_i <= 31);
        const sub_i = i % 4;
        std.debug.assert(audio_power_table[array_i][sub_i] >= 0.0);
        const power_value = audio_power_table[array_i][sub_i];
        const freq_to_mel = freq_to_mel_table[i];
        var filter_map_buffer: [5]FilterMap = undefined;
        for (triangleFilter(freq_to_mel, &filter_map_buffer)) |filter_map| {
            mel_bins[filter_map.index] += filter_map.weight * power_value;
        }
    }

    const audio_bin_compress_count = @divExact(@divExact(bin_count, 2), audio_visual_bin_count);
    var decibel_accumulator: f32 = 0;
    var mel_bin_index: usize = 0;
    i = 0;
    while (i < audio_visual_bin_count) : (i += 1) {
        comptime var x: usize = 0;
        audio_spectogram_bins[i] = 0;
        inline while (x < audio_bin_compress_count) : (x += 1) {
            audio_spectogram_bins[i] += mel_bins[mel_bin_index + x];
        }
        audio_spectogram_bins[i] /= @intToFloat(f32, audio_bin_compress_count);
        audio_spectogram_bins[i] = std.math.log10(audio_spectogram_bins[i] / reference_max_audio);
        decibel_accumulator += audio_spectogram_bins[i];
        mel_bin_index += audio_bin_compress_count;
    }

    decibel_accumulator /= @intToFloat(f32, audio_visual_bin_count);

    audio_volume_level_widget.setDecibelLevel(decibel_accumulator);
    audio_callback_count += 1;
    is_record_requested = true;
}

fn handleAudioInputInitSuccess() void {
    std.log.info("audio input system initialized", .{});
    audio_input_interface.inputList(general_allocator, handleAudioDeviceInputsList);
}

fn handleAudioInputInitFail(err: audio.InitError) void {
    std.log.err("Failed to initialize audio input system. Error: {}", .{err});
}

fn handleAudioInputOpenSuccess() void {
    zmath.fftInitUnityTable(&unity_table);
}

fn handleAudioInputOpenFail(err: audio.OpenError) void {
    std.log.err("Failed to open audio input device. Error: {}", .{err});
}

pub fn init() !void {
    general_allocator = if (builtin.mode == .Debug) stdlib_gpa.allocator() else std.heap.c_allocator;

    font = blk: {
        const file_handle = try std.fs.cwd().openFile(asset_path_font, .{ .mode = .read_only });
        defer file_handle.close();
        const max_size_bytes = 10 * 1024 * 1024;
        const font_file_bytes = try file_handle.readToEndAlloc(general_allocator, max_size_bytes);
        break :blk Font.construct(font_file_bytes);
    } catch |err| {
        std.log.err("Failed to load font file ({s}). Error: {}", .{ asset_path_font, err });
        return err;
    };
    errdefer font.deinit(general_allocator);

    texture_atlas = try Atlas.init(general_allocator, 512);
    errdefer texture_atlas.deinit(general_allocator);

    event_system.init() catch |err| {
        std.log.err("Failed to initialize the event system. Error: {}", .{err});
        return error.InitializeEventSystemFailed;
    };

    try wayland_client.init("reel");
    errdefer wayland_client.deinit();

    if (window_decorations.requested) {
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
        const points_per_pixel = 100;
        const font_point_size: f64 = 12.0;
        var loaded_texture = try renderer.textureGet();
        std.debug.assert(loaded_texture.width == loaded_texture.height);
        pen = try font.createPen(
            pen_options,
            general_allocator,
            font_point_size,
            points_per_pixel,
            atlas_codepoints,
            loaded_texture.width,
            loaded_texture.pixels,
            &texture_atlas,
        );
        pen_small = try font.createPen(
            pen_options,
            general_allocator,
            10,
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

    audio_input_interface = audio.createBestInterface(&onAudioInputRead);

    try audio_input_interface.init(
        &handleAudioInputInitSuccess,
        &handleAudioInputInitFail,
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
    audio_input_interface.close();

    pen.deinit(general_allocator);
    renderer.deinit(general_allocator);
    wayland_client.deinit();
    texture_atlas.deinit(general_allocator);
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

            //
            // TODO: No hardcode
            //
            var audio_frame_count: usize = 0;
            for (0..3) |i| {
                audio_frame_buffer[i] = audio_sample_ring_buffer.pop() orelse break;
                audio_frame_count += 1;
            }
            const buffer_slice = audio_frame_buffer[0..audio_frame_count];
            video_encoder.write(pixels, buffer_slice, video_stream_frame_index) catch |err| {
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

            var audio_frame_count: usize = 0;
            for (0..3) |i| {
                audio_frame_buffer[i] = audio_sample_ring_buffer.pop() orelse break;
                for (audio_frame_buffer[i]) |sample| {
                    std.debug.assert(sample <= 1.0);
                    std.debug.assert(sample >= -1.0);
                }
                audio_frame_count += 1;
            }
            const buffer_slice: []*[2048]f32 = audio_frame_buffer[0..audio_frame_count];
            video_encoder.write(pixels, buffer_slice, video_stream_frame_index) catch |err| {
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
                    .uninitialized, .closed => {
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
                        audio_sample_ring_buffer.reset();
                        const options = video_encoder.RecordOptions{
                            .output_path = "reel_test.mp4",
                            .dimensions = .{
                                .width = 1920,
                                .height = 1080,
                            },
                            .fps = 30,
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
                        record_start_timestamp = std.time.nanoTimestamp();
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
                        const record_end_timestamp = std.time.nanoTimestamp();
                        record_duration = @intCast(u64, record_end_timestamp - record_start_timestamp);
                        std.log.info("Recording lasted {}", .{std.fmt.fmtDuration(record_duration)});
                    },
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

        updateAudioInput();

        if (stream_state == .record or stream_state == .record_preview) {
            if (recording_timer_text_quads) |quads| {
                var interface = TextMutaterInterface{ .quads = quads };
                const current_timestamp = std.time.nanoTimestamp();
                const duration = @intCast(u64, current_timestamp - record_start_timestamp);
                const seconds = @divFloor(duration, std.time.ns_per_s);
                var time_label_buffer: [5]u8 = undefined;
                const time_label = std.fmt.bufPrint(&time_label_buffer, "00:{d:0>2}", .{seconds}) catch "00:00";
                try pen_small.write(
                    time_label,
                    recording_timer_placement,
                    wayland_client.screen_scale,
                    &interface,
                );
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
            // _ = sleep_period_ns;
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
    const audio_duration: f64 = @intToFloat(f64, app_end - audio_start.?) / std.time.ns_per_s;
    const audio_fps: f64 = @intToFloat(f64, audio_callback_count) / audio_duration;
    print("\n== Runtime Statistics ==\n\n", .{});
    print("audio fps:   {d}\n", .{audio_fps});
    print("runtime:     {d:.2}s\n", .{runtime_seconds});
    print("display fps: {d:.2}\n", .{frames_per_s});
    print("input fps:   {d:.2}\n", .{@intToFloat(f64, app_loop_iteration) / runtime_seconds});
    print("\n", .{});
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
    const extent = geometry.Extent2D(f32){
        .x = @floatCast(f32, renderer.video_stream_placement.x - border_width_horizontal),
        .y = @floatCast(f32, renderer.video_stream_placement.y - border_width_vertical),
        .width = @floatCast(f32, background_width),
        .height = @floatCast(f32, background_height),
    };
    const color = if (video_encoder.state == .encoding and screencast_interface.?.state() == .open)
        preview_background_color_recording
    else
        preview_background_color;

    (try face_writer.create(QuadFace)).* = graphics.quadColored(extent, color.toRGBA(), .top_left);
    screen_capture_bottom = extent.y + extent.height;
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

fn handleAudioDeviceInputsList(devices: []audio.InputDeviceInfo) void {
    const print = std.debug.print;
    print("Audio input devices:\n", .{});
    for (devices, 0..) |device, device_i| {
        print("  {d:.2} {s} {s}\n", .{ device_i, device.name, device.description });
    }

    audio_input_interface.open(
        // devices[0].name,
        null,
        &handleAudioInputOpenSuccess,
        &handleAudioInputOpenFail,
    ) catch |err| {
        std.log.err("audio_input: Failed to connect to device. Error: {}", .{err});
    };
    audio_input_device_list_opt = devices;
}

const FilterMap = struct {
    index: usize,
    weight: f32,
};

// Takes a point and distributes it linearly-ish across 5 bins
fn triangleFilter(point: f32, filter_map_buffer: *[5]FilterMap) []FilterMap {
    const point_whole = @floatToInt(u32, @floor(point));
    const offset = (@rem(point, 1.0) - 0.5) / 10;
    std.debug.assert(offset >= -0.10);
    std.debug.assert(offset <= 0.10);
    const index_first = @intCast(u32, @max(0, @intCast(i64, point_whole) - 2));
    const index_last: u32 = @min((bin_count / 2) - 1, point_whole + 2);
    const range: u32 = index_last - index_first;
    if (range < 4) {
        filter_map_buffer[0] = .{
            .index = @intCast(usize, point_whole),
            .weight = 1.0,
        };
        return filter_map_buffer[0..1];
    }
    filter_map_buffer.* = [5]FilterMap{
        .{ .index = point_whole - 2, .weight = 0.05 - offset },
        .{ .index = point_whole - 1, .weight = 0.20 - offset },
        .{ .index = point_whole, .weight = 0.50 },
        .{ .index = point_whole + 1, .weight = 0.20 + offset },
        .{ .index = point_whole + 2, .weight = 0.05 + offset },
    };
    return filter_map_buffer[0..5];
}

fn updateAudioInput() void {
    if (audio_input_quads) |quads| {
        const screen_scale = wayland_client.screen_scale;

        const margin_left_pixels: f32 = 15;
        const margin_bottom_pixels: f32 = 60 + information_bar.height_pixels;
        const x_offset: f32 = @floatCast(f32, margin_left_pixels * screen_scale.horizontal);
        const y_offset: f32 = @floatCast(f32, margin_bottom_pixels * screen_scale.vertical);

        const x_increment = @floatCast(f32, 6 * screen_scale.horizontal);
        const bar_width = @floatCast(f32, 4 * screen_scale.horizontal);
        const bar_color = graphics.RGBA(f32).fromInt(u8, 50, 100, 65, 255);
        const height_max = @floatCast(f32, 200 * screen_scale.vertical);

        audio_power_table_mutex.lock();
        defer audio_power_table_mutex.unlock();

        var i: usize = 0;
        while (i < audio_visual_bin_count) : (i += 1) {
            const decibels_clamped = @min(reference_max_audio, @max(decibel_range_lower, audio_spectogram_bins[i]));
            const height: f32 = height_max - ((decibels_clamped / decibel_range_lower) * height_max);
            const extent = geometry.Extent2D(f32){
                .x = -1.0 + x_offset + (@intToFloat(f32, i) * x_increment),
                .y = 1.0 - y_offset,
                .width = bar_width,
                .height = height,
            };
            quads[i] = graphics.quadColored(extent, bar_color, .bottom_left);
            quads[i][0].color = graphics.RGBA(f32).fromInt(u8, 150, 50, 70, 255);
            quads[i][1].color = graphics.RGBA(f32).fromInt(u8, 150, 50, 70, 255);
        }

        is_render_requested = true;
    }
}

fn drawAudioInput() !void {
    var quads = try face_writer.allocate(QuadFace, audio_visual_bin_count);
    audio_input_quads = quads;
}

fn drawAudioSource() !void {
    const screen_scale = wayland_client.screen_scale;
    const margin_left_pixels: f32 = 15;
    const margin_bottom_pixels: f32 = 15 + information_bar.height_pixels;
    const x_offset: f32 = @floatCast(f32, margin_left_pixels * screen_scale.horizontal);
    const y_offset: f32 = @floatCast(f32, margin_bottom_pixels * screen_scale.vertical);
    const width_pixels: f32 = 400;
    const height_pixels: f32 = 200;
    const extent = geometry.Extent2D(f32){
        .x = -1.0 + x_offset,
        .y = 1.0 - y_offset,
        .width = @floatCast(f32, width_pixels * screen_scale.horizontal),
        .height = @floatCast(f32, height_pixels * screen_scale.vertical),
    };
    const border_color = graphics.RGBA(f32).fromInt(u8, 155, 155, 155, 255);
    const border_width = @floatCast(f32, 1 * screen_scale.horizontal);
    try widget.Section.draw(
        extent,
        "Audio Source",
        wayland_client.screen_scale,
        &pen,
        border_color,
        border_width,
    );
    try drawAudioInput();
}

/// Our example draw function
/// This will run anytime the screen is resized
fn draw(allocator: std.mem.Allocator) !void {
    _ = allocator;
    face_writer.reset();

    if (window_decorations.requested)
        try window_decorations.draw();

    try information_bar.draw();

    try drawAudioSource();

    if (stream_state == .record or stream_state == .record_preview) {
        const screen_scale = wayland_client.screen_scale;
        {
            const margin_vertical_pixels = 10;
            const margin_vertical = @floatCast(f32, margin_vertical_pixels * screen_scale.vertical);
            const radius_pixels = (@intToFloat(f32, information_bar.height_pixels) - (margin_vertical_pixels * 2)) / 2;
            const x_offset: f32 = @floatCast(f32, 20 * screen_scale.horizontal);
            const y_offset: f32 = margin_vertical + @floatCast(f32, radius_pixels * screen_scale.vertical);
            const center = geometry.Coordinates2D(f64){
                .x = -1.0 + x_offset,
                .y = 1.0 - y_offset,
            };
            try widget.drawCircle(
                center,
                radius_pixels,
                screen_scale,
                graphics.RGBA(f32).fromInt(u8, 220, 10, 10, 255),
            );
        }
        var text_writer_interface = TextWriterInterface{ .quad_writer = &face_writer };
        const x_offset = @floatCast(f32, 40 * screen_scale.horizontal);
        const y_offset = @floatCast(f32, 10 * screen_scale.vertical);
        recording_timer_placement = geometry.Coordinates2D(f32){
            .x = -1.0 + x_offset,
            .y = 1.0 - y_offset,
        };
        recording_timer_text_quads = @ptrCast([*]QuadFace, &face_writer.vertices[face_writer.vertices_used])[0..5];
        try pen_small.write(
            "00:00",
            recording_timer_placement,
            wayland_client.screen_scale,
            &text_writer_interface,
        );
    }

    if (audio_input_interface.state() == .open) {
        const screen_scale = wayland_client.screen_scale;
        const margin_left_pixels: f32 = 30;
        const margin_bottom_pixels: f32 = 30 + information_bar.height_pixels;
        const x_offset: f32 = @floatCast(f32, margin_left_pixels * screen_scale.horizontal);
        const y_offset: f32 = @floatCast(f32, margin_bottom_pixels * screen_scale.vertical);
        const extent = geometry.Extent2D(f32){
            .x = -1.0 + x_offset,
            .y = 1.0 - y_offset,
            .width = @floatCast(f32, 370 * screen_scale.horizontal),
            .height = @floatCast(f32, 5 * screen_scale.vertical),
        };
        audio_volume_level_widget.init(extent) catch |err| {
            std.log.err("Failed to init audio_volume_level widget. Error: {}", .{err});
        };
    }

    if (audio_input_devices_opt) |input_devices| {
        var placement = geometry.Coordinates2D(f32){
            .x = 0.0,
            .y = 0.0,
        };
        var text_writer_interface = TextWriterInterface{ .quad_writer = &face_writer };
        const y_increment = @floatCast(f32, 25 * wayland_client.screen_scale.vertical);
        for (input_devices) |device| {
            std.log.info("Label: {s}", .{device.description});
            const device_label = std.mem.span(device.description);
            std.log.info("Label len: {d}", .{device_label.len});
            std.log.info("Device label: {s}", .{device_label});
            std.debug.assert(device_label[device_label.len - 1] != 0);
            try pen_small.write(
                device_label,
                placement,
                wayland_client.screen_scale,
                &text_writer_interface,
            );
            placement.y += y_increment;
        }
    }

    try drawScreenCapture();

    {
        if (enable_preview_checkbox == null)
            enable_preview_checkbox = try Checkbox.create();

        const preview_margin_left: f64 = style.screen_preview.margin_left_pixels * wayland_client.screen_scale.horizontal;
        const checkbox_radius_pixels = 11;
        const checkbox_width = checkbox_radius_pixels * wayland_client.screen_scale.horizontal * 2;
        const y_offset = 20 * wayland_client.screen_scale.vertical;
        const center = geometry.Coordinates2D(f64){
            .x = -1.0 + (preview_margin_left + (checkbox_width / 2)),
            .y = screen_capture_bottom + y_offset,
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
        //       NOTE: Use writeCentered for this
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

    if (record_button_opt == null) {
        record_button_opt = try Button.create();
    }

    {
        const screen_scale = wayland_client.screen_scale;
        {
            //
            // Controls Section
            //
            const width_pixels: f32 = 500;
            const height_pixels: f32 = 200;
            const margin_right_pixels: f32 = 15;
            const margin_bottom_pixels: f32 = information_bar.height_pixels + 15;
            const border_color = graphics.RGBA(f32).fromInt(u8, 155, 155, 155, 255);
            const border_width = @floatCast(f32, 1 * screen_scale.horizontal);
            const extent = geometry.Extent2D(f32){
                .x = 1.0 - @floatCast(f32, (width_pixels + margin_right_pixels) * screen_scale.horizontal),
                .y = 1.0 - @floatCast(f32, margin_bottom_pixels * screen_scale.vertical),
                .width = @floatCast(f32, width_pixels * screen_scale.horizontal),
                .height = @floatCast(f32, height_pixels * screen_scale.vertical),
            };
            try widget.Section.draw(
                extent,
                "Controls",
                screen_scale,
                &pen,
                border_color,
                border_width,
            );
        }

        if (record_button_opt) |*record_button| {
            const right_margin_pixels: f32 = 25;
            const bottom_margin_pixels: f32 = 25 + information_bar.height_pixels;
            const width_pixels: f32 = 120;
            //
            // Even height values are causing text distortion
            // https://github.com/kdchambers/reel/issues/11
            //
            const height_pixels: f32 = 31;
            const extent = geometry.Extent2D(f32){
                .x = 1.0 - @floatCast(f32, (right_margin_pixels + width_pixels) * screen_scale.horizontal),
                .y = 1.0 - @floatCast(f32, bottom_margin_pixels * screen_scale.vertical),
                .width = @floatCast(f32, width_pixels * screen_scale.horizontal),
                .height = @floatCast(f32, height_pixels * screen_scale.vertical),
            };
            try record_button.draw(
                extent,
                record_button_color_normal,
                if (video_encoder.state == .encoding) "Stop" else "Record",
                &pen,
                wayland_client.screen_scale,
                .{ .rounding_radius = null },
            );
        }
    }
}

fn lerp(from: f32, to: f32, value: f32) f32 {
    return from + (value * (to - from));
}

fn random(seed: u32) u32 {
    const value = (seed << 13) ^ 13;
    return ((value * (value * value * 15731 + 7892221) + 1376312589) & 0x7fffffff);
}

inline fn gpuClamp(value: f32) f32 {
    const precision = 1.0 / 256.0;
    const rem = value % precision;
    if (rem == 0) return value;
    return if (rem >= (precision / 2.0)) value + rem else value - rem;
}
