// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

const Model = @import("../Model.zig");
const UIState = @import("wayland/UIState.zig");
const audio_utils = @import("wayland/audio.zig");
const zmath = @import("zmath");

const wayland_core = @import("../wayland_core.zig");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

var cursor_theme: *wl.CursorTheme = undefined;
var cursor: *wl.Cursor = undefined;
var cursor_surface: *wl.Surface = undefined;
var xcursor: [:0]const u8 = undefined;

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

// TODO: eww
const texture_layer_dimensions = renderer.texture_layer_dimensions;

const widgets = @import("wayland/widgets.zig");
const Button = widgets.Button;
const Checkbox = widgets.Checkbox;

const application_name = "reel";
const background_color = RGBA.fromInt(90, 90, 90, 255);

const app_core = @import("../app_core.zig");
const RequestBuffer = app_core.RequestBuffer;
const Request = app_core.Request;

const RequestEncoder = @import("../RequestEncoder.zig");

var ui_state: UIState = undefined;

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

var gpu_texture_mutex: std.Thread.Mutex = undefined;

pub var previous_mouse_coordinates: geometry.Coordinates2D(f64) = undefined;
pub var mouse_coordinates: geometry.Coordinates2D(f64) = undefined;

pub var screen_dimensions: geometry.Dimensions2D(u16) = .{
    .width = 1040,
    .height = 640,
};
pub var screen_scale: geometry.ScaleFactor2D(f32) = undefined;

pub var pending_swapchain_images_count: u32 = 2;
pub var frame_index: u32 = 0;

pub var is_mouse_in_screen: bool = true;

var framebuffer_resized: bool = false;

pub var button_clicked: ButtonClicked = .none;
pub var button_state: wl.Pointer.ButtonState = undefined;
pub var is_mouse_moved: bool = false;
var is_fullscreen: bool = false;
var is_draw_requested: bool = true;

// TODO: Remove
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

pub fn init(allocator: std.mem.Allocator) !void {
    std.log.info("wayland init", .{});
    allocator_ref = allocator;

    initWaylandClient() catch return error.WaylandClientInitFail;

    font = blk: {
        const file_handle = std.fs.cwd().openFile(asset_path_font, .{ .mode = .read_only }) catch return error.FontInitFail;
        defer file_handle.close();
        const max_size_bytes = 10 * 1024 * 1024;
        const font_file_bytes = file_handle.readToEndAlloc(allocator, max_size_bytes) catch return error.FontInitFail;
        break :blk Font.construct(font_file_bytes) catch return error.FontInitFail;
    };
    errdefer font.deinit(allocator);

    texture_atlas = Atlas.init(allocator, 512) catch return error.TextureAtlasInitFail;
    errdefer texture_atlas.deinit(allocator);

    event_system.init() catch |err| {
        std.log.err("Failed to initialize the event system. Error: {}", .{err});
        return error.InitializeEventSystemFail;
    };

    renderer.init(
        allocator,
        @ptrCast(*renderer.Display, wayland_core.display),
        @ptrCast(*renderer.Surface, surface),
        &texture_atlas,
        screen_dimensions,
    ) catch return error.VulkanRendererInitFail;
    errdefer renderer.deinit(allocator);

    {
        const points_per_pixel = 100;
        const font_point_size: f64 = 12.0;
        var loaded_texture = renderer.textureGet() catch return error.VulkanRendererCommitTextureFail;
        std.debug.assert(loaded_texture.width == loaded_texture.height);
        pen = font.createPen(
            pen_options,
            allocator,
            font_point_size,
            points_per_pixel,
            atlas_codepoints,
            loaded_texture.width,
            loaded_texture.pixels,
            &texture_atlas,
        ) catch return error.FontPenInitFail;
        renderer.textureCommit() catch return error.VulkanRendererCommitTextureFail;
    }
    errdefer pen.deinit(allocator);

    face_writer = renderer.faceWriter();

    widgets.init(
        &face_writer,
        face_writer.vertices,
        &mouse_coordinates,
        &screen_dimensions,
        &is_mouse_in_screen,
    );

    ui_state.record_button = Button.create();
    ui_state.enable_preview_checkbox = try Checkbox.create();

    //
    // TODO: Don't hardcode bin count
    //
    ui_state.audio_input_mel_bins = allocator.alloc(f32, 64) catch return error.OutOfMemory;
    zmath.fftInitUnityTable(&audio_utils.unity_table);
}

var last_preview_frame: u64 = 0;

pub fn update(model: *const Model) UpdateError!RequestBuffer {
    request_encoder.used = 0;

    if (is_shutdown_requested) {
        request_encoder.write(.core_shutdown) catch unreachable;
        return request_encoder.toRequestBuffer();
    }

    if (framebuffer_resized) {
        std.log.info("Recreate swapchain", .{});
        framebuffer_resized = false;
        renderer.recreateSwapchain(screen_dimensions) catch |err| {
            std.log.err("Failed to recreate swapchain. Error: {}", .{err});
        };
        is_draw_required = true;
    }

    if (model.desktop_capture_frame) |captured_frame| {
        renderer.video_stream_enabled = true;
        if (last_preview_frame != captured_frame.index) {
            const src_width = captured_frame.dimensions.width;
            const src_height = captured_frame.dimensions.height;
            var src_pixels = captured_frame.pixels;
            var video_frame = renderer.videoFrame();
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

            if (last_preview_frame == 0) {
                std.log.info("Forcing redraw", .{});
                is_draw_required = true;
            }
            last_preview_frame = captured_frame.index;
            is_render_requested = true;
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
            request_encoder.write(.record_start) catch unreachable;
            is_draw_required = true;
        }
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

    if (is_mouse_moved) {
        is_mouse_moved = false;
        event_system.handleMouseMovement(&mouse_position);
    }

    if (is_draw_required) {
        is_draw_required = false;

        face_writer.reset();
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
        //
        // Redraw not required, but update widgets
        //
        if (model.audio_input_samples) |audio_input_samples| {
            const audio_power_spectrum = audio_utils.samplesToPowerSpectrum(audio_input_samples);
            const mel_scaled_bins = audio_utils.powerSpectrumToMelScale(audio_power_spectrum, 64);
            ui_state.audio_input_spectogram.update(mel_scaled_bins, screen_scale) catch unreachable;

            const volume_dbs = audio_utils.powerSpectrumToVolumeDb(audio_power_spectrum);
            ui_state.audio_volume_level.setDecibelLevel(volume_dbs);

            is_render_requested = true;
        }
    }

    if (is_record_requested) {
        is_record_requested = false;
        std.log.info("Record render pass", .{});
        std.debug.assert(face_writer.indices_used > 0);
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
            renderer.renderFrame(screen_dimensions) catch return error.VulkanRendererRenderFrameFail;
        }
    }

    return request_encoder.toRequestBuffer();
}

pub fn deinit() void {
    std.log.info("wayland deinit", .{});
}

fn initWaylandClient() !void {
    surface = try wayland_core.compositor.createSurface();

    xdg_surface = try wayland_core.xdg_wm_base.getXdgSurface(surface);
    xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, surface);

    xdg_toplevel = try xdg_surface.getToplevel();
    xdg_toplevel.setListener(*bool, xdgToplevelListener, &is_shutdown_requested);

    frame_callback = try surface.frame();
    frame_callback.setListener(*const void, frameListener, &{});

    wayland_core.pointer.setListener(*const void, pointerListener, &{});

    // TODO: Don't hardcode
    xdg_toplevel.setTitle("reel");
    surface.commit();

    if (wayland_core.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    //
    // Load cursor theme
    //

    cursor_surface = try wayland_core.compositor.createSurface();

    const cursor_size = 24;
    cursor_theme = try wl.CursorTheme.load(null, cursor_size, wayland_core.shared_memory);
    cursor = cursor_theme.getCursor(XCursor.left_ptr).?;
    xcursor = XCursor.left_ptr;
}

fn drawPreviewEnableCheckbox() !void {
    const preview_margin_left: f64 = 20.0 * screen_scale.horizontal;
    const checkbox_radius_pixels = 11;
    const checkbox_width = checkbox_radius_pixels * screen_scale.horizontal * 2;
    const y_offset = 20 * screen_scale.vertical;
    const center = geometry.Coordinates2D(f64){
        .x = -1.0 + (preview_margin_left + (checkbox_width / 2)),
        .y = 0.5 + y_offset,
    };
    const is_set = true; // (stream_state == .preview or stream_state == .record_preview);
    try ui_state.enable_preview_checkbox.draw(
        center,
        checkbox_radius_pixels,
        screen_scale,
        RGB.fromInt(55, 55, 55).toRGBA(),
        is_set,
    );

    // TODO: Vertically aligning label will require knowing it's height
    //       NOTE: Use writeCentered for this
    const v_adjustment_hack = 0.85;

    const placement = geometry.Coordinates2D(f32){
        .x = @floatCast(f32, center.x + checkbox_width),
        .y = @floatCast(f32, center.y + (checkbox_radius_pixels * screen_scale.vertical * v_adjustment_hack)),
    };

    var text_writer_interface = TextWriterInterface{ .quad_writer = &face_writer };
    try pen.write(
        "Enable Preview",
        placement,
        .{
            .horizontal = screen_scale.horizontal,
            .vertical = screen_scale.vertical,
        },
        // screen_scale,
        &text_writer_interface,
    );
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
            std.log.info("wayland_client: xdg_toplevel configure", .{});
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

            const state_list = configure.states.slice(xdg.Toplevel.State);
            is_fullscreen = false;
            for (state_list) |state| {
                if (state == .fullscreen) {
                    is_draw_requested = true;
                    //
                    // TODO: This is kind of a hack but we need to force a redraw
                    //       when the screen is made fullscreen
                    //
                    is_fullscreen = true;
                    std.log.info("Fullscreen activated", .{});
                }
            }
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
                std.debug.assert(false);
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

                if (mouse_x < 3 and mouse_y < 3) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .bottom_left);
                }

                const edge_threshold = 3;
                const max_width = screen_dimensions.width - edge_threshold;
                const max_height = screen_dimensions.height - edge_threshold;

                if (mouse_x < edge_threshold and mouse_y > max_height) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .top_left);
                    return;
                }

                if (mouse_x > max_width and mouse_y < edge_threshold) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .bottom_right);
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

                if (mouse_y == max_height) {
                    xdg_toplevel.resize(wayland_core.seat, button.serial, .bottom);
                    return;
                }
            }

            if (@floatToInt(u16, mouse_coordinates.y) > screen_dimensions.height)
                return;

            if (@floatToInt(u16, mouse_coordinates.x) > screen_dimensions.width)
                return;
        },
        .axis => |axis| std.log.info("Mouse: axis {} {}", .{ axis.axis, axis.value.toDouble() }),
        .frame => |frame| _ = frame,
        .axis_source => |axis_source| std.log.info("Mouse: axis_source {}", .{axis_source.axis_source}),
        .axis_stop => |axis_stop| _ = axis_stop,
        .axis_discrete => |_| std.log.info("Mouse: axis_discrete", .{}),
    }
}
