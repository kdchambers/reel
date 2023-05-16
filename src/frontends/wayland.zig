// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const Model = @import("../Model.zig");
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

const layout_1920x1080 = @import("wayland/layouts/1920x1080.zig");

const geometry = @import("../geometry.zig");
const Extent2D = geometry.Extent2D;
const Extent3D = geometry.Extent3D;
const Coordinates2D = geometry.Coordinates2D;
const ScaleFactor2D = geometry.ScaleFactor2D;

const event_system = @import("wayland/event_system.zig");
const audio = @import("../audio_source.zig");

const graphics = @import("../graphics.zig");
const RGBA = graphics.RGBA(u8);
const RGB = graphics.RGB(u8);

const renderer = @import("../renderer.zig");

const widgets = @import("wayland/widgets.zig");
const Button = widgets.Button;
const IconButton = widgets.IconButton;
const CloseButton = widgets.CloseButton;
const Checkbox = widgets.Checkbox;
const Dropdown = widgets.Dropdown;
const Selector = widgets.Selector;
const TabbedSection = widgets.TabbedSection;

const app_core = @import("../app_core.zig");
const CoreUpdateDecoder = app_core.UpdateDecoder;
const CoreRequestEncoder = app_core.CoreRequestEncoder;
const CoreRequestDecoder = app_core.CoreRequestDecoder;

var ui_state: UIState = undefined;

var cached_webcam_enabled: bool = false;

const CursorState = enum {
    normal,
    pointer,
};

var loaded_cursor: CursorState = .normal;

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

var is_draw_required: bool = true;
var is_render_requested: bool = true;

/// Set when command buffers need to be (re)recorded. The following will cause that to happen
///   1. First command buffer recording
///   2. Screen resized
///   3. Push constants need to be updated
///   4. Number of vertices to be drawn has changed
var is_record_requested: bool = true;

var record_button_color_normal = RGBA{ .r = 15, .g = 15, .b = 15 };
var record_button_color_hover = RGBA{ .r = 25, .g = 25, .b = 25 };

const window_title = "reel";

var gpu_texture_mutex: std.Thread.Mutex = undefined;

pub var mouse_coordinates: geometry.Coordinates2D(f64) = undefined;

const initial_screen_dimensions = struct {
    const width = 1280;
    const height = 840;
};

pub var screen_dimensions: geometry.Dimensions2D(u32) = .{
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

var framebuffer_resized: bool = false;

pub var button_clicked: ButtonClicked = .none;
pub var button_state: wl.Pointer.ButtonState = undefined;
pub var is_mouse_moved: bool = false;

var is_shutdown_requested: bool = false;

var allocator_ref: std.mem.Allocator = undefined;
var request_encoder: CoreRequestEncoder = .{};

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
    LoadAssetFail,
};

pub const UpdateError = error{ VulkanRendererRenderFrameFail, UserInterfaceDrawFail };

var last_recording_state: Model.RecordingContext.State = .idle;
var last_preview_frame: u64 = 0;

pub fn init(allocator: std.mem.Allocator) !void {
    allocator_ref = allocator;

    ui_state.window_decoration_requested = true;

    initWaylandClient() catch return error.WaylandClientInitFail;

    event_system.init() catch |err| {
        std.log.err("Failed to initialize the event system. Error: {}", .{err});
        return error.InitializeEventSystemFail;
    };

    renderer.init(
        allocator,
        @ptrCast(*renderer.Display, wayland_core.display),
        @ptrCast(*renderer.Surface, surface),
        screen_dimensions,
    ) catch return error.VulkanRendererInitFail;
    errdefer renderer.deinit();

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

    ui_state.open_settings_button = IconButton.create();
    ui_state.open_settings_button.on_hover_background_color = RGBA{ .r = 255, .g = 255, .b = 255, .a = 20 };
    ui_state.open_settings_button.on_hover_icon_color = RGBA.white;
    ui_state.open_settings_button.background_color = RGBA.transparent;
    ui_state.open_settings_button.icon_color = RGBA{ .r = 202, .g = 202, .b = 202, .a = 255 };
    ui_state.open_settings_button.icon = .settings_32px;

    ui_state.open_add_button = IconButton.create();
    ui_state.open_add_button.on_hover_background_color = RGBA{ .r = 255, .g = 255, .b = 255, .a = 20 };
    ui_state.open_add_button.on_hover_icon_color = RGBA.white;
    ui_state.open_add_button.background_color = RGBA.transparent;
    ui_state.open_add_button.icon_color = RGBA{ .r = 202, .g = 202, .b = 202, .a = 255 };
    ui_state.open_add_button.icon = .add_32px;

    ui_state.add_source_button = IconButton.create();
    ui_state.add_source_button.on_hover_background_color = RGBA{ .r = 255, .g = 255, .b = 255, .a = 20 };
    ui_state.add_source_button.on_hover_icon_color = RGBA.white;
    ui_state.add_source_button.background_color = RGBA.transparent;
    ui_state.add_source_button.icon_color = RGBA{ .r = 202, .g = 202, .b = 202, .a = 255 };
    ui_state.add_source_button.icon = .add_circle_24px;

    ui_state.select_source_provider_popup = widgets.ListSelectPopup.allocate();
    ui_state.select_source_provider_popup.title = "Select Source Provider";
    ui_state.select_source_provider_popup.background_color = RGBA.fromInt(24, 24, 46, 255);
    ui_state.select_source_provider_popup.item_background_color = RGBA.fromInt(24, 24, 46, 255);
    ui_state.select_source_provider_popup.item_background_color_hovered = RGBA.fromInt(44, 44, 66, 255);
    ui_state.select_source_provider_popup.addLabel("wlroots");

    ui_state.select_video_source_popup = widgets.ListSelectPopup.allocate();
    ui_state.select_video_source_popup.background_color = RGBA.fromInt(24, 24, 46, 255);
    ui_state.select_video_source_popup.item_background_color = RGBA.fromInt(24, 24, 46, 255);
    ui_state.select_video_source_popup.item_background_color_hovered = RGBA.fromInt(44, 44, 66, 255);

    ui_state.add_source_state = .closed;

    ui_state.action_tab = TabbedSection.create(
        &UIState.tab_headings,
        RGB{ .r = 150, .g = 35, .b = 57 },
    );

    //
    // TODO: Don't hardcode bin count
    //
    ui_state.audio_source_mel_bins = allocator.alloc(f32, 64) catch return error.OutOfMemory;
    zmath.fftInitUnityTable(&audio_utils.unity_table);
}

pub fn update(model: *const Model, core_updates: *CoreUpdateDecoder) UpdateError!CoreRequestDecoder {
    request_encoder.used = 0;

    while (core_updates.next()) |core_update| {
        switch (core_update) {
            .video_source_added => is_draw_required = true,
        }
    }

    if (model.video_streams.len != 0)
        is_render_requested = true;

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

    if (is_shutdown_requested) {
        request_encoder.write(.core_shutdown) catch unreachable;
        return request_encoder.decoder();
    }

    if (framebuffer_resized) {
        framebuffer_resized = false;
        renderer.resizeSwapchain(screen_dimensions) catch |err| {
            std.log.err("Failed to recreate swapchain. Error: {}", .{err});
        };
        is_draw_required = true;
    }

    {
        const result = ui_state.open_settings_button.update();
        if (result.clicked)
            std.log.info("Settings button clicked", .{});
        if (result.modified)
            is_render_requested = true;
    }

    switch (ui_state.add_source_state) {
        .closed => {},
        .select_source_provider => {
            const response = ui_state.select_source_provider_popup.update();
            if (response.visual_change)
                is_render_requested = true;
            if (response.item_clicked) |item_index| {
                assert(item_index < model.video_source_providers.len);
                const selected_source_provider_ptr = &model.video_source_providers[item_index];
                if (selected_source_provider_ptr.sources) |sources| {
                    ui_state.select_video_source_popup.clearLabels();
                    ui_state.select_video_source_popup.title = "Select Display";
                    for (sources) |source| {
                        ui_state.select_video_source_popup.addLabel(source.name);
                    }
                    ui_state.add_source_state = .select_source;
                } else {
                    //
                    // If sources for provider is null, that means that interspection and selecting
                    // a specific source from reel isn't supported. Instead we request a source
                    // from the provider
                    //
                    request_encoder.write(.screencapture_request_source) catch unreachable;
                    ui_state.add_source_state = .closed;
                }
                is_draw_required = true;
            }
        },
        .select_source => {
            const response = ui_state.select_video_source_popup.update();
            if (response.visual_change)
                is_render_requested = true;
            if (response.item_clicked) |item_index| {
                assert(item_index < model.video_source_providers[0].sources.?.len);
                request_encoder.write(.screencapture_add_source) catch unreachable;
                request_encoder.writeInt(u16, item_index) catch unreachable;
                ui_state.add_source_state = .closed;
                is_draw_required = true;
            }
        },
    }

    {
        const result = ui_state.open_add_button.update();
        if (result.clicked) {
            ui_state.sidebar_state = switch (ui_state.sidebar_state) {
                .add_menu_open => .closed,
                else => .add_menu_open,
            };
            is_draw_required = true;
        }
        if (result.modified)
            is_render_requested = true;
    }

    {
        const result = ui_state.add_source_button.update();
        if (result.clicked) {
            ui_state.add_source_state = switch (ui_state.add_source_state) {
                .closed => .select_source_provider,
                else => .closed,
            };
            is_draw_required = true;
        }
        if (result.modified)
            is_render_requested = true;
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
                    is_draw_required = true;
                }
            }
        }
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
        if (changes.hover_enter and loaded_cursor != .pointer)
            setCursorState(.pointer);
        if (changes.hover_exit and loaded_cursor != .normal)
            setCursorState(.normal);
    }

    if (is_draw_required) {
        is_draw_required = false;
        renderer.resetVertexBuffers();

        if (ui_state.window_decoration_requested) {
            //
            // We just reset the face_writer so a failure shouldn't really be possible
            // NOTE: This will modify ui_state.window_region to make sure we don't
            //       draw over the window decoration
            //
            drawWindowDecoration() catch unreachable;
        }

        //
        // Redrawing invalidates all of the hover zones. Disable them here and
        // they can be overwritten in the following draw fn
        //
        event_system.disableHoverZones();

        //
        // Reset cursor back to normal. Hoverzones have been invalidated
        //
        setCursorState(.normal);

        //
        // Switch here based on screen dimensions
        //
        layout_1920x1080.draw(
            model,
            &ui_state,
            screen_scale,
        ) catch |err| {
            std.log.info("Failed to draw ui. Error: {}", .{err});
            return error.UserInterfaceDrawFail;
        };

        is_record_requested = true;
    } else {
        layout_1920x1080.update(
            model,
            &ui_state,
            screen_scale,
        ) catch return error.UserInterfaceDrawFail;
    }

    if (is_record_requested) {
        is_record_requested = false;
        renderer.recordDrawCommands() catch return error.UserInterfaceDrawFail;
        is_render_requested = true;
    }

    if (pending_swapchain_images_count > 0) {
        if (is_render_requested) {
            is_render_requested = false;
            pending_swapchain_images_count -= 1;

            gpu_texture_mutex.lock();
            defer gpu_texture_mutex.unlock();

            renderer.renderFrame() catch
                return error.VulkanRendererRenderFrameFail;
        }
    }

    event_system.mouse_click_coordinates = null;

    return request_encoder.decoder();
}

pub fn deinit() void {
    std.log.info("wayland deinit", .{});
}

inline fn setCursorState(cursor_state: CursorState) void {
    switch (cursor_state) {
        .pointer => {
            if (loaded_cursor == .pointer)
                return;

            cursor = cursor_theme.getCursor(XCursor.pointer) orelse blk: {
                break :blk cursor_theme.getCursor(XCursor.hand1) orelse {
                    std.log.info("Failed to load a cursor image for pointing", .{});
                    return;
                };
            };
            const image = cursor.images[0];
            const image_buffer = image.getBuffer() catch {
                std.log.warn("Failed to get cursor image buffer", .{});
                return;
            };
            cursor_surface.attach(image_buffer, 0, 0);
            cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            cursor_surface.commit();
            loaded_cursor = .pointer;
        },
        .normal => {
            if (loaded_cursor == .normal)
                return;
            cursor = cursor_theme.getCursor(XCursor.left_ptr).?;
            const image = cursor.images[0];
            const image_buffer = image.getBuffer() catch {
                std.log.warn("Failed to get cursor image buffer", .{});
                return;
            };
            cursor_surface.attach(image_buffer, 0, 0);
            cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            cursor_surface.commit();
            loaded_cursor = .normal;
        },
    }
}

fn drawWindowDecoration() !void {
    const height: f32 = decoration_height_pixels * screen_scale.vertical;
    {
        const background_color = RGB.fromInt(200, 200, 200);
        const extent = geometry.Extent3D(f32){
            .x = -1.0,
            .y = -1.0,
            .width = 2.0,
            .height = height,
        };
        _ = renderer.drawQuad(extent, background_color.toRGBA(), .top_left);
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

            event_system.mouse_click_coordinates = .{
                .x = mouse_coordinates.x,
                .y = mouse_coordinates.y,
            };

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
