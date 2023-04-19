// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const Model = @import("../Model.zig");
const RequestBuffer = @import("../RequestBuffer.zig");
const UIState = @import("wayland/UIState.zig");
const audio_utils = @import("wayland/audio.zig");
const zmath = @import("zmath");

const wayland_core = @import("../wayland_core.zig");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;

var cursor_theme: *wl.CursorTheme = undefined;
var cursor: *wl.Cursor = undefined;
var cursor_surface: *wl.Surface = undefined;

// Called every time the compositor is ready to accept a new frame
var frame_callback: *wl.Callback = undefined;
var xdg_toplevel: *xdg.Toplevel = undefined;
var xdg_surface: *xdg.Surface = undefined;
var surface: *wl.Surface = undefined;

pub const FrameTickCallbackFn = fn (frame_index: u32) void;
pub var frame_listener_callbacks_count: usize = 0;
pub var frame_listener_callbacks: [10]*const FrameTickCallbackFn = undefined;

pub fn addOnFrameCallback(callback: *const FrameTickCallbackFn) void {
    frame_listener_callbacks[frame_listener_callbacks_count] = callback;
    frame_listener_callbacks_count += 1;
}

const layout_medium = @import("wayland/layouts/desktop_medium.zig");

const geometry = @import("../geometry.zig");
const Extent2D = geometry.Extent2D;
const Coordinates2D = geometry.Coordinates2D;
const ScaleFactor2D = geometry.ScaleFactor2D;

const fontana = @import("fontana");
const Atlas = fontana.Atlas;
const Font = fontana.Font(.{
    .backend = .freetype_harfbuzz,
    .type_overrides = .{
        .Extent2DPixel = Extent2D(u32),
        .Extent2DNative = Extent2D(f32),
        .Coordinates2DNative = Coordinates2D(f32),
        .Scale2D = ScaleFactor2D(f32),
    },
});

const event_system = @import("wayland/event_system.zig");
const audio = @import("../audio.zig");

const graphics = @import("../graphics.zig");
const RGBA = graphics.RGBA(f32);
const RGB = graphics.RGB(f32);
const QuadFace = graphics.QuadFace;
const FaceWriter = graphics.FaceWriter;

const renderer = @import("../vulkan_renderer.zig");

const widgets = @import("wayland/widgets.zig");
const Button = widgets.Button;
const CloseButton = widgets.CloseButton;
const Checkbox = widgets.Checkbox;
const Dropdown = widgets.Dropdown;
const Selector = widgets.Selector;
const TabbedSection = widgets.TabbedSection;

const app_core = @import("../app_core.zig");
const Request = app_core.Request;

const RequestEncoder = @import("../RequestEncoder.zig");

var ui_state: UIState = undefined;

var cached_webcam_enabled: bool = false;

var loaded_cursor: enum {
    normal,
    pointer,
} = .normal;

const XCursor = struct {
    const arrow = "arrow";
    const hidden = "hidden";
    const left_ptr = "left_ptr";
    const text = "text";
    const xterm = "xterm";
    const hand = "hand";
    const link = "link";
    const hand1 = "hand1";
    const hand2 = "hand2";
    const move = "move";
    const fleur = "fleur";
    const grabbing = "grabbing";
    const pointer = "pointer";
    const openhand = "openhand";
    const pointer_move = "pointer-move";
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
pub const MouseButton = enum(i32) {
    left = 0x110,
    right = 0x111,
    middle = 0x112,
    _,
};

pub const ButtonClicked = enum(u16) {
    none,
    right,
    middle,
    left,
};

const decoration_height_pixels = 30.0;

pub var face_writer: FaceWriter = undefined;

var is_draw_required: bool = true;
var is_render_requested: bool = true;

/// Set when command buffers need to be (re)recorded. The following will cause that to happen
///   1. First command buffer recording
///   2. Screen resized
///   3. Push constants need to be updated
///   4. Number of vertices to be drawn has changed
var is_record_requested: bool = true;

var record_button_color_normal = RGBA{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };
var record_button_color_hover = RGBA{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 };

var texture_atlas: Atlas = undefined;
var font: Font = undefined;

const pen_options = fontana.PenOptions{
    .pixel_format = .r32g32b32a32,
    .PixelType = RGBA,
};
pub var pen: Font.PenConfig(pen_options) = undefined;

const asset_path_font = "assets/Roboto-Regular.ttf";
const atlas_codepoints = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890!.%:-/()";
const window_title = "reel";

var gpu_texture_mutex: std.Thread.Mutex = undefined;

pub var mouse_coordinates: geometry.Coordinates2D(f64) = undefined;

const initial_screen_dimensions = struct {
    const width = 1280;
    const height = 840;
};

pub var screen_dimensions: geometry.Dimensions2D(u16) = .{
    .width = initial_screen_dimensions.width,
    .height = initial_screen_dimensions.height,
};

pub var screen_scale = geometry.ScaleFactor2D(f32){
    .horizontal = 2.0 / @as(f32, initial_screen_dimensions.width),
    .vertical = 2.0 / @as(f32, initial_screen_dimensions.height),
};

pub var pending_swapchain_images_count: u32 = 1;
pub var frame_index: u32 = 0;

pub var is_mouse_in_screen: bool = true;

var framebuffer_resized: bool = true;

pub var button_clicked: ButtonClicked = .none;
pub var button_state: wl.Pointer.ButtonState = undefined;
pub var is_mouse_moved: bool = false;

var is_shutdown_requested: bool = false;

var allocator_ref: std.mem.Allocator = undefined;
var request_encoder: RequestEncoder = .{};

pub const InitError = error{
    FontInitFail,
    InitializeEventSystemFail,
    WaylandClientInitFail,
    VulkanRendererInitFail,
    VulkanRendererCommitTextureFail,
    FontPenInitFail,
    AudioInputInitFail,
    TextureAtlasInitFail,
    OutOfMemory,
};

pub const UpdateError = error{ VulkanRendererRenderFrameFail, UserInterfaceDrawFail };

var last_recording_state: Model.RecordingContext.State = .idle;
var last_preview_frame: u64 = 0;

var font_texture: renderer.Texture = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    allocator_ref = allocator;

    ui_state.window_decoration_requested = true;

    initWaylandClient() catch return error.WaylandClientInitFail;

    font = blk: {
        const file_handle = std.fs.cwd().openFile(asset_path_font, .{ .mode = .read_only }) catch return error.FontInitFail;
        defer file_handle.close();
        const max_size_bytes = 10 * 1024 * 1024;
        const font_file_bytes = file_handle.readToEndAlloc(allocator, max_size_bytes) catch return error.FontInitFail;
        break :blk Font.construct(font_file_bytes) catch |err| {
            std.log.err("Failed to initialize font. Error: {}", .{err});
            return error.FontInitFail;
        };
    };
    errdefer font.deinit(allocator);

    texture_atlas = Atlas.init(allocator, 512) catch return error.TextureAtlasInitFail;
    errdefer texture_atlas.deinit(allocator);

    font_texture.width = 512;
    font_texture.height = 512;
    const pixels = try allocator.alloc(graphics.RGBA(f32), font_texture.width * font_texture.height);
    const clear_pixel = graphics.RGBA(f32){
        .r = 0.0,
        .g = 0.0,
        .b = 0.0,
        .a = 0.0,
    };
    std.mem.set(graphics.RGBA(f32), pixels, clear_pixel);
    pixels[(512 * 512) - 1] = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };

    font_texture.pixels = pixels.ptr;

    {
        const points_per_pixel = 100;
        const font_point_size: f64 = 12.0;
        pen = font.createPen(
            pen_options,
            allocator,
            font_point_size,
            points_per_pixel,
            atlas_codepoints,
            font_texture.width,
            font_texture.pixels,
            &texture_atlas,
        ) catch return error.FontPenInitFail;
    }
    errdefer pen.deinit(allocator);

    event_system.init() catch |err| {
        std.log.err("Failed to initialize the event system. Error: {}", .{err});
        return error.InitializeEventSystemFail;
    };

    renderer.init(
        allocator,
        @ptrCast(*renderer.Display, wayland_core.display),
        @ptrCast(*renderer.Surface, surface),
        font_texture,
        screen_dimensions,
    ) catch return error.VulkanRendererInitFail;
    errdefer renderer.deinit(allocator);

    face_writer = renderer.faceWriter();

    widgets.init(
        &face_writer,
        face_writer.vertices,
        &mouse_coordinates,
        &screen_dimensions,
        &is_mouse_in_screen,
    );

    ui_state.window_region.left = -1.0;
    ui_state.window_region.right = 1.0;
    ui_state.window_region.bottom = 1.0;
    ui_state.window_region.top = -1.0;

    ui_state.record_button = Button.create();
    ui_state.record_format = try Dropdown.create(3);
    ui_state.record_format.labels = &UIState.format_labels;
    ui_state.record_format.selected_index = 0;

    ui_state.screenshot_button = Button.create();
    ui_state.screenshot_format = try Dropdown.create(4);
    ui_state.screenshot_format.labels = &UIState.image_format_labels;
    ui_state.screenshot_format.selected_index = 0;

    ui_state.record_quality = try Dropdown.create(3);
    ui_state.record_quality.labels = &UIState.quality_labels;
    ui_state.record_quality.selected_index = 0;

    ui_state.enable_webcam_checkbox = try Checkbox.create();

    const display_label_list = wayland_core.display_list.items;
    ui_state.preview_display_selector = Selector.create(display_label_list);

    ui_state.action_tab = TabbedSection.create(
        &UIState.tab_headings,
        graphics.RGB(f32).fromInt(150, 35, 57),
    );

    if (ui_state.window_decoration_requested) {
        ui_state.close_button = CloseButton.create();
        ui_state.close_button.on_hover_color = graphics.RGBA(f32).fromInt(170, 170, 170, 255);
    }

    //
    // TODO: Don't hardcode bin count
    //
    ui_state.audio_input_mel_bins = allocator.alloc(f32, 64) catch return error.OutOfMemory;
    zmath.fftInitUnityTable(&audio_utils.unity_table);
}

pub fn update(model: *const Model) UpdateError!RequestBuffer {
    request_encoder.used = 0;

    if (model.recording_context.state != last_recording_state) {
        last_recording_state = model.recording_context.state;
        is_draw_required = true;
    }

    //
    // TODO: A hack until app_core has a proper way of communicating changes with
    //       frontend
    //
    if (cached_webcam_enabled != model.webcam_stream.enabled()) {
        cached_webcam_enabled = !cached_webcam_enabled;
        assert(cached_webcam_enabled == model.webcam_stream.enabled());
        is_draw_required = true;
    }

    if (ui_state.window_decoration_requested) {
        const widget_update = ui_state.close_button.update();
        if (widget_update.left_clicked)
            is_shutdown_requested = true;
        if (widget_update.color_changed)
            is_render_requested = true;
    }

    if (is_shutdown_requested) {
        request_encoder.write(.core_shutdown) catch unreachable;
        return request_encoder.toRequestBuffer();
    }

    if (framebuffer_resized) {
        framebuffer_resized = false;
        renderer.recreateSwapchain(screen_dimensions) catch |err| {
            std.log.err("Failed to recreate swapchain. Error: {}", .{err});
        };
        is_draw_required = true;
    }

    if (model.desktop_capture_frame) |captured_frame| {
        const pixel_buffer: [*]const graphics.RGBA(u8) = if (model.combined_frame) |*frame| frame.ptr else captured_frame.pixels;
        renderer.video_stream_enabled = true;
        if (last_preview_frame != captured_frame.index) {
            var video_frame = renderer.videoFrame();
            {
                const src_width = captured_frame.dimensions.width;
                const src_height = captured_frame.dimensions.height;
                var src_pixels = pixel_buffer;
                var y: usize = 0;
                var src_index: usize = 0;
                var dst_index: usize = 0;
                while (y < src_height) : (y += 1) {
                    @memcpy(
                        @ptrCast([*]u8, &video_frame.pixels[dst_index]),
                        @ptrCast([*]const u8, &src_pixels[src_index]),
                        src_width * @sizeOf(graphics.RGBA(u8)),
                    );
                    src_index += src_width;
                    dst_index += video_frame.width;
                }
            }

            if (last_preview_frame == 0) {
                is_draw_required = true;
            }
            last_preview_frame = captured_frame.index;
            is_render_requested = true;
        }
    }

    {
        const widget_update = ui_state.preview_display_selector.update();
        if (widget_update.color_changed or widget_update.index_changed) {
            is_render_requested = true;
        }
    }

    if (ui_state.action_tab.active_index == 0) {
        //
        // Recording format selection dropdown
        //
        if (!ui_state.record_format.is_open) {
            const state = ui_state.record_format.state();
            if (state.hover_enter) {
                ui_state.record_format.setColor(record_button_color_hover);
                is_render_requested = true;
            }
            if (state.hover_exit) {
                ui_state.record_format.setColor(record_button_color_normal);
                is_render_requested = true;
            }
            if (state.left_click_release) {
                ui_state.record_format.is_open = true;
                is_draw_required = true;
            }
        } else {
            const item_count = ui_state.record_format.item_count;
            for (ui_state.record_format.item_states[0..item_count], 0..) |item_state, i| {
                const state_copy = item_state.get();
                item_state.getPtr().clear();
                if (state_copy.hover_enter) {
                    ui_state.record_format.setItemColor(i, record_button_color_hover);
                    is_render_requested = true;
                }
                if (state_copy.hover_exit) {
                    ui_state.record_format.setItemColor(i, record_button_color_normal);
                    is_render_requested = true;
                }
                if (state_copy.left_click_release) {
                    if (i != ui_state.record_format.selected_index) {
                        request_encoder.write(.record_format_set) catch unreachable;
                        request_encoder.writeInt(u16, @intCast(u16, i)) catch unreachable;
                    }
                    ui_state.record_format.selected_index = @intCast(u16, i);
                    ui_state.record_format.is_open = false;
                    event_system.clearBlockingEvents();
                    is_draw_required = true;
                }
            }
        }

        //
        // Recording format selection dropdown
        //
        if (!ui_state.record_quality.is_open) {
            const state = ui_state.record_quality.state();
            if (state.hover_enter) {
                ui_state.record_quality.setColor(record_button_color_hover);
                is_render_requested = true;
            }
            if (state.hover_exit) {
                ui_state.record_quality.setColor(record_button_color_normal);
                is_render_requested = true;
            }
            if (state.left_click_release) {
                ui_state.record_quality.is_open = true;
                is_draw_required = true;
            }
        } else {
            const item_count = ui_state.record_quality.item_count;
            for (ui_state.record_quality.item_states[0..item_count], 0..) |item_state, i| {
                const state_copy = item_state.get();
                item_state.getPtr().clear();
                if (state_copy.hover_enter) {
                    ui_state.record_quality.setItemColor(i, record_button_color_hover);
                    is_render_requested = true;
                }
                if (state_copy.hover_exit) {
                    ui_state.record_quality.setItemColor(i, record_button_color_normal);
                    is_render_requested = true;
                }
                if (state_copy.left_click_release) {
                    if (i != ui_state.record_quality.selected_index) {
                        request_encoder.write(.record_quality_set) catch unreachable;
                        request_encoder.writeInt(u16, @intCast(u16, i)) catch unreachable;
                    }
                    ui_state.record_quality.selected_index = @intCast(u16, i);
                    ui_state.record_quality.is_open = false;
                    event_system.clearBlockingEvents();
                    is_draw_required = true;
                }
            }
        }

        {
            const state = ui_state.record_button.state();
            if (state.hover_enter) {
                ui_state.record_button.setColor(record_button_color_hover);
                is_render_requested = true;
            }
            if (state.hover_exit) {
                ui_state.record_button.setColor(record_button_color_normal);
                is_render_requested = true;
            }

            if (state.left_click_release) {
                switch (model.recording_context.state) {
                    .idle => request_encoder.write(.record_start) catch unreachable,
                    .recording => request_encoder.write(.record_stop) catch unreachable,
                    else => {},
                }
                is_draw_required = true;
            }
        }
    } else if (ui_state.action_tab.active_index == 1) {
        //
        // Recording format selection dropdown
        //
        if (!ui_state.screenshot_format.is_open) {
            const state = ui_state.screenshot_format.state();
            if (state.hover_enter) {
                ui_state.screenshot_format.setColor(record_button_color_hover);
                is_render_requested = true;
            }
            if (state.hover_exit) {
                ui_state.screenshot_format.setColor(record_button_color_normal);
                is_render_requested = true;
            }
            if (state.left_click_release) {
                ui_state.screenshot_format.is_open = true;
                is_draw_required = true;
            }
        } else {
            const item_count = ui_state.screenshot_format.item_count;
            for (ui_state.screenshot_format.item_states[0..item_count], 0..) |item_state, i| {
                const state_copy = item_state.get();
                item_state.getPtr().clear();
                if (state_copy.hover_enter) {
                    ui_state.screenshot_format.setItemColor(i, record_button_color_hover);
                    is_render_requested = true;
                }
                if (state_copy.hover_exit) {
                    ui_state.screenshot_format.setItemColor(i, record_button_color_normal);
                    is_render_requested = true;
                }
                if (state_copy.left_click_release) {
                    if (i != ui_state.screenshot_format.selected_index) {
                        std.log.info("Image format set! {d}", .{i});
                        request_encoder.write(.screenshot_format_set) catch unreachable;
                        request_encoder.writeInt(u16, @intCast(u16, i)) catch unreachable;
                    }
                    ui_state.screenshot_format.selected_index = @intCast(u16, i);
                    ui_state.screenshot_format.is_open = false;
                    event_system.clearBlockingEvents();
                    is_draw_required = true;
                }
            }
        }
    }

    if (ui_state.enable_webcam_checkbox.clicked()) {
        if (model.webcam_stream.enabled())
            request_encoder.write(.webcam_disable) catch unreachable
        else
            request_encoder.write(.webcam_enable) catch unreachable;
    }

    const action_tab_update = ui_state.action_tab.update();
    if (action_tab_update.tab_changed) {
        _ = ui_state.record_button.state();
        _ = ui_state.record_quality.state();
        _ = ui_state.record_format.state();
        is_draw_required = true;
    }

    if (ui_state.action_tab.active_index == 1) {
        const state = ui_state.screenshot_button.state();
        if (state.hover_enter) {
            ui_state.screenshot_button.setColor(record_button_color_hover);
            is_render_requested = true;
        }
        if (state.hover_exit) {
            ui_state.screenshot_button.setColor(record_button_color_normal);
            is_render_requested = true;
        }

        if (state.left_click_release) {
            request_encoder.write(.screenshot_do) catch unreachable;
        }
    } else {
        _ = ui_state.screenshot_button.state();
    }

    const mouse_position = mouseCoordinatesNDCR();
    //
    // TODO: This is silly. Why can't I just pass button_clicked directly?
    //
    switch (button_clicked) {
        .left => event_system.handleMouseClick(&mouse_position, .left, button_state),
        .right => event_system.handleMouseClick(&mouse_position, .right, button_state),
        .middle => event_system.handleMouseClick(&mouse_position, .middle, button_state),
        else => {},
    }
    button_clicked = .none;

    if (is_mouse_moved) {
        is_mouse_moved = false;
        const changes = event_system.handleMouseMovement(&mouse_position);
        update_cursor: {
            if (changes.hover_enter and loaded_cursor != .pointer) {
                cursor = cursor_theme.getCursor(XCursor.pointer) orelse blk: {
                    break :blk cursor_theme.getCursor(XCursor.hand1) orelse {
                        std.log.info("Failed to load a cursor image for pointing", .{});
                        break :update_cursor;
                    };
                };
                const image = cursor.images[0];
                const image_buffer = image.getBuffer() catch {
                    std.log.warn("Failed to get cursor image buffer", .{});
                    break :update_cursor;
                };
                cursor_surface.attach(image_buffer, 0, 0);
                cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
                cursor_surface.commit();
                loaded_cursor = .pointer;
            } else if (changes.hover_exit and loaded_cursor != .normal) {
                cursor = cursor_theme.getCursor(XCursor.left_ptr).?;
                const image = cursor.images[0];
                const image_buffer = image.getBuffer() catch {
                    std.log.warn("Failed to get cursor image buffer", .{});
                    break :update_cursor;
                };
                cursor_surface.attach(image_buffer, 0, 0);
                cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
                cursor_surface.commit();
                loaded_cursor = .normal;
            }
        }
    }

    if (is_draw_required) {
        is_draw_required = false;

        face_writer.reset();

        if (ui_state.window_decoration_requested) {
            //
            // We just reset the face_writer so a failure shouldn't really be possible
            // NOTE: This will modify ui_state.window_region to make sure we don't
            //       draw over the window decoration
            //
            drawWindowDecoration() catch unreachable;
        }

        //
        // Switch here based on screen dimensions
        //
        layout_medium.draw(
            model,
            &ui_state,
            screen_scale,
            &pen,
            &face_writer,
        ) catch return error.UserInterfaceDrawFail;

        is_record_requested = true;
    } else {
        layout_medium.update(
            model,
            &ui_state,
            screen_scale,
            &pen,
            &face_writer,
        ) catch return error.UserInterfaceDrawFail;

        //
        // Redraw not required, but update widgets
        //
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
            const audio_power_spectrum = audio_utils.samplesToPowerSpectrum(samples);
            const mel_scaled_bins = audio_utils.powerSpectrumToMelScale(audio_power_spectrum, 64);
            ui_state.audio_input_spectogram.update(mel_scaled_bins[3..], screen_scale) catch unreachable;

            const volume_dbs = audio_utils.powerSpectrumToVolumeDb(audio_power_spectrum);
            ui_state.audio_volume_level.setDecibelLevel(volume_dbs);
        }

        is_render_requested = true;
    }

    if (is_record_requested) {
        is_record_requested = false;
        assert(face_writer.indices_used > 0);
        renderer.recordRenderPass(face_writer.indices_used, screen_dimensions) catch |err| {
            std.log.err("app: Failed to record renderpass command buffers: Error: {}", .{err});
        };
        is_render_requested = true;
    }

    if (pending_swapchain_images_count > 0) {
        if (is_render_requested) {
            is_render_requested = false;
            pending_swapchain_images_count -= 1;

            gpu_texture_mutex.lock();
            defer gpu_texture_mutex.unlock();

            renderer.renderFrame(screen_dimensions) catch
                return error.VulkanRendererRenderFrameFail;
        }
    }

    return request_encoder.toRequestBuffer();
}

pub fn deinit() void {
    std.log.info("wayland deinit", .{});
}

fn drawWindowDecoration() !void {
    const height: f32 = decoration_height_pixels * screen_scale.vertical;
    {
        const background_color = RGB.fromInt(200, 200, 200);
        const extent = geometry.Extent2D(f32){
            .x = -1.0,
            .y = -1.0,
            .width = 2.0,
            .height = height,
        };
        (try face_writer.create(QuadFace)).* = graphics.quadColored(
            extent,
            background_color.toRGBA(),
            .top_left,
        );
    }

    {
        const size_pixels: f32 = 28.0;
        const offset_pixels: f32 = (decoration_height_pixels - size_pixels) / 2.0;
        const h_offset: f32 = offset_pixels * screen_scale.horizontal;
        const v_offset: f32 = offset_pixels * screen_scale.vertical;
        const cross_width = (size_pixels * screen_scale.horizontal) - (h_offset * 2.0);
        const cross_height = (size_pixels * screen_scale.vertical) - (v_offset * 2.0);
        const extent = geometry.Extent2D(f32){
            .x = 1.0 - (cross_width + (h_offset * 2.0)),
            .y = -1.0 + (cross_height + v_offset),
            .width = cross_width - h_offset,
            .height = cross_height - v_offset,
        };
        try ui_state.close_button.draw(extent, screen_scale);
    }

    ui_state.window_region.top = -1.0 + height;
}

fn initWaylandClient() !void {
    surface = try wayland_core.compositor.createSurface();

    xdg_surface = try wayland_core.xdg_wm_base.getXdgSurface(surface);
    xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, surface);

    xdg_toplevel = try xdg_surface.getToplevel();
    xdg_toplevel.setListener(*bool, xdgToplevelListener, &is_shutdown_requested);

    xdg_toplevel.setTitle("Reel");

    var toplevel_decoration: *zxdg.ToplevelDecorationV1 = undefined;
    if (wayland_core.window_decorations_opt) |window_decorations| {
        toplevel_decoration = try window_decorations.getToplevelDecoration(xdg_toplevel);
        toplevel_decoration.setListener(*const void, toplevelDecorationListener, &{});
    }

    frame_callback = try surface.frame();
    frame_callback.setListener(*const void, frameListener, &{});

    wayland_core.pointer.setListener(*const void, pointerListener, &{});

    xdg_toplevel.setTitle(window_title);
    surface.commit();

    if (wayland_core.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    //
    // Load cursor theme
    //

    cursor_surface = try wayland_core.compositor.createSurface();

    const cursor_size = 24;
    cursor_theme = wl.CursorTheme.load("Adwaita", cursor_size, wayland_core.shared_memory) catch blk: {
        break :blk wl.CursorTheme.load(null, cursor_size, wayland_core.shared_memory) catch {
            return error.LoadCursorFail;
        };
    };
    cursor = cursor_theme.getCursor(XCursor.left_ptr).?;
}

fn toplevelDecorationListener(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, _: *const void) void {
    switch (event) {
        .configure => |configure| {
            switch (configure.mode) {
                .server_side => ui_state.window_decoration_requested = false,
                else => ui_state.window_decoration_requested = true,
            }
        },
    }
}

fn xdgSurfaceListener(xdg_surface_ref: *xdg.Surface, event: xdg.Surface.Event, surface_ref: *wl.Surface) void {
    switch (event) {
        .configure => |configure| {
            std.log.info("wayland_client: xdg_surface configure", .{});
            xdg_surface_ref.ackConfigure(configure.serial);
            surface_ref.commit();
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, close_requested: *bool) void {
    switch (event) {
        .configure => |configure| {
            if (configure.width > 0 and configure.width != screen_dimensions.width) {
                framebuffer_resized = true;
                screen_dimensions.width = @intCast(u16, configure.width);
                screen_scale.horizontal = 2.0 / @intToFloat(f32, screen_dimensions.width);
            }
            if (configure.height > 0 and configure.height != screen_dimensions.height) {
                framebuffer_resized = true;
                screen_dimensions.height = @intCast(u16, configure.height);
                screen_scale.vertical = 2.0 / @intToFloat(f32, screen_dimensions.height);
            }
            std.log.info("xdg_toplevel configure. Dimensions {d} x {d}", .{
                screen_dimensions.width,
                screen_dimensions.height,
            });
            frame_callback.destroy();
            frame_callback = surface.frame() catch |err| {
                std.log.err("Failed to create new wayland frame -> {}", .{err});
                return;
            };
            frame_callback.setListener(*const void, frameListener, &{});
        },
        .close => close_requested.* = true,
    }
}

fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, _: *const void) void {
    switch (event) {
        .done => {
            callback.destroy();
            frame_callback = surface.frame() catch |err| {
                std.log.err("Failed to create new wayland frame -> {}", .{err});
                assert(false);
                return;
            };
            frame_callback.setListener(*const void, frameListener, &{});

            for (frame_listener_callbacks[0..frame_listener_callbacks_count]) |user_callback| {
                user_callback(frame_index);
            }

            frame_index += 1;
            pending_swapchain_images_count += 1;
        },
    }
}

fn mouseCoordinatesNDCR() geometry.Coordinates2D(f64) {
    return .{
        .x = -1.0 + (mouse_coordinates.x * screen_scale.horizontal),
        .y = -1.0 + (mouse_coordinates.y * screen_scale.vertical),
    };
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, _: *const void) void {
    switch (event) {
        .enter => |enter| {
            is_mouse_in_screen = true;
            mouse_coordinates.x = enter.surface_x.toDouble();
            mouse_coordinates.y = enter.surface_y.toDouble();

            //
            // When mouse enters application surface, update the cursor image
            //
            const image = cursor.images[0];
            const image_buffer = image.getBuffer() catch return;
            cursor_surface.attach(image_buffer, 0, 0);
            wayland_core.pointer.setCursor(enter.serial, cursor_surface, @intCast(i32, image.hotspot_x), @intCast(i32, image.hotspot_y));
            cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            cursor_surface.commit();
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

            mouse_coordinates.x = motion_mouse_x;
            mouse_coordinates.y = motion_mouse_y;

            is_mouse_moved = true;
        },
        .button => |button| {
            if (!is_mouse_in_screen) {
                return;
            }

            if (mouse_coordinates.x < 0 or mouse_coordinates.y < 0)
                return;

            const mouse_button = @intToEnum(MouseButton, button.button);
            button_clicked = .none;

            if (mouse_button == .left)
                button_clicked = .left;

            if (mouse_button == .right)
                button_clicked = .right;

            if (mouse_button == .middle)
                button_clicked = .middle;

            button_state = button.state;

            std.log.info("Button mouse coordinates: {d}, {d}", .{
                mouse_coordinates.x,
                mouse_coordinates.y,
            });

            {
                const mouse_x = @floatToInt(u16, mouse_coordinates.x);
                const mouse_y = @floatToInt(u16, mouse_coordinates.y);

                std.log.info("Mouse coords: {d}, {d}. Screen {d}, {d}", .{
                    mouse_x,
                    mouse_y,
                    screen_dimensions.width,
                    screen_dimensions.height,
                });

                if (mouse_x > screen_dimensions.width or mouse_y > screen_dimensions.height)
                    return;

                const edge_threshold = 6;
                const max_width = screen_dimensions.width - edge_threshold;
                const max_height = screen_dimensions.height - edge_threshold;

                if (mouse_x < edge_threshold and mouse_y < edge_threshold) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .top_left);
                }

                if (mouse_x < edge_threshold and mouse_y > max_height) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .bottom_left);
                    return;
                }

                if (mouse_x > max_width and mouse_y < edge_threshold) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .top_right);
                    return;
                }

                if (mouse_x > max_width and mouse_y > max_height) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .bottom_right);
                    return;
                }

                if (mouse_x < edge_threshold) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .left);
                    return;
                }

                if (mouse_x > max_width) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .right);
                    return;
                }

                if (mouse_y <= edge_threshold) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .top);
                    return;
                }

                if (mouse_y >= max_height) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .bottom);
                    return;
                }
            }

            if (@floatToInt(u16, mouse_coordinates.y) > screen_dimensions.height)
                return;

            if (@floatToInt(u16, mouse_coordinates.x) > screen_dimensions.width)
                return;

            if (ui_state.window_decoration_requested and mouse_button == .left) {
                // Start interactive window move if mouse coordinates are in window decorations bounds
                if (@floatToInt(u32, mouse_coordinates.y) <= decoration_height_pixels) {
                    xdg_toplevel.move(wayland_core.seat, button.serial);
                }
            }
        },
        .axis => |axis| std.log.info("Mouse: axis {} {}", .{ axis.axis, axis.value.toDouble() }),
        .frame => |frame| _ = frame,
        .axis_source => |axis_source| std.log.info("Mouse: axis_source {}", .{axis_source.axis_source}),
        .axis_stop => |axis_stop| _ = axis_stop,
        .axis_discrete => |_| std.log.info("Mouse: axis_discrete", .{}),
    }
}
