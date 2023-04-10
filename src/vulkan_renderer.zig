// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");

const VulkanAllocator = @import("VulkanBumpAllocator.zig");

const vulkan_core = @import("renderer/vulkan_core.zig");
const texture_pipeline = @import("renderer/texture_pipeline.zig");
const generic_pipeline = @import("renderer/generic_pipeline.zig");
const render_pass = @import("renderer/render_pass.zig");

const defines = @import("renderer/defines.zig");
const max_frames_in_flight = defines.max_frames_in_flight;
const texture_layer_dimensions = defines.texture_layer_dimensions;
const print_vulkan_objects = defines.print_vulkan_objects;
const transparancy_enabled = defines.transparancy_enabled;
const memory_size = defines.memory.host_local.size_bytes + 256;

const ScreenNormalizedBaseType = defines.ScreenNormalizedBaseType;
const TextureNormalizedBaseType = defines.TextureNormalizedBaseType;

// TODO: Fontana shouldn't be referenced here
const Atlas = @import("fontana").Atlas;

/// Defines the entire surface area of a screen in vulkans coordinate system
/// I.e normalized device coordinates right (ndc right)
const full_screen_extent = geometry.Extent2D(ScreenNormalizedBaseType){
    .x = -1.0,
    .y = -1.0,
    .width = 2.0,
    .height = 2.0,
};

/// Defines the entire surface area of a texture
const full_texture_extent = geometry.Extent2D(TextureNormalizedBaseType){
    .x = 0.0,
    .y = 0.0,
    .width = 1.0,
    .height = 1.0,
};

var mapped_device_memory: [*]u8 = undefined;
var quad_buffer: []graphics.QuadFace = undefined;
var current_frame: u32 = 0;
var previous_frame: u32 = 0;
pub var texture_atlas: *Atlas = undefined;

var alpha_mode: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true };
var jobs_command_buffer: vk.CommandBuffer = undefined;

//
// Graphics context
//

var selected_memory_index: u32 = undefined;

var command_buffers: []vk.CommandBuffer = undefined;

var images_available: []vk.Semaphore = undefined;
var renders_finished: []vk.Semaphore = undefined;
var inflight_fences: []vk.Fence = undefined;
var swapchain: vk.SwapchainKHR = undefined;

var framebuffers: []vk.Framebuffer = undefined;
var swapchain_min_image_count: u32 = undefined;
pub var swapchain_extent: vk.Extent2D = undefined;
var swapchain_images: []vk.Image = undefined;
var swapchain_image_views: []vk.ImageView = undefined;
var swapchain_surface_format: vk.SurfaceFormatKHR = undefined;

// Has a precision of 2^12 = 4096
pub const ImageHandle = packed struct(u64) {
    texture_array_index: u8,
    x: u12,
    y: u12,
    _width: u12,
    _height: u12,
    reserved: u8,

    pub inline fn width(self: @This()) u16 {
        return @intCast(u16, self._width);
    }

    pub inline fn height(self: @This()) u16 {
        return @intCast(u16, self._height);
    }

    pub inline fn extent(self: @This()) geometry.Extent2D(f32) {
        return .{
            .x = @intToFloat(f32, self.x) / 512,
            .y = @intToFloat(f32, self.y) / 512,
            .width = @intToFloat(f32, self._width) / 512,
            .height = @intToFloat(f32, self._height) / 512,
        };
    }
};

pub const Surface = opaque {};
pub const Display = opaque {};

const VideoCanvasHandle = packed struct(u64) {
    const texture_size = 2048;

    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub inline fn extent(self: @This()) geometry.Extent2D(f32) {
        return .{
            .x = @intToFloat(f32, self.x) / texture_size,
            .y = @intToFloat(f32, self.y) / texture_size,
            .width = @intToFloat(f32, self._width) / texture_size,
            .height = @intToFloat(f32, self._height) / texture_size,
        };
    }
};

var video_stream: ?VideoCanvasHandle = null;

pub const VideoFrameBuffer = struct {
    pixels: [*]graphics.RGBA(u8),
    width: u32,
    height: u32,
};

pub var video_stream_dimensions: geometry.Dimensions2D(f32) = .{ .width = 1920.0, .height = 1080 };
pub var video_stream_scaled_dimensions: geometry.Dimensions2D(f32) = .{ .width = 1920.0, .height = 1080 };
pub var video_stream_placement: geometry.Coordinates2D(f32) = .{ .x = -0.8, .y = -0.8 };
pub var video_stream_output_dimensions: geometry.Dimensions2D(f32) = .{ .width = 0.2, .height = 0.2 };
pub var video_stream_enabled: bool = false;

pub fn videoFrame() VideoFrameBuffer {
    return .{
        .pixels = texture_pipeline.memory_map.ptr,
        .width = defines.memory.pipeline_video.framebuffer_dimensions.width,
        .height = defines.memory.pipeline_video.framebuffer_dimensions.height,
    };
}

pub fn placeVideoStream(coordinates: geometry.Coordinates2D(f32)) void {
    video_stream_placement = coordinates;
}

pub fn init(
    allocator: std.mem.Allocator,
    wayland_display: *Display,
    wayland_surface: *Surface,
    atlas: *Atlas,
    swapchain_dimensions: geometry.Dimensions2D(u16),
) !void {
    texture_atlas = atlas;

    try vulkan_core.init(
        @ptrCast(*vk.wl_display, wayland_display),
        @ptrCast(*vk.wl_surface, wayland_surface),
    );

    //
    // Alias for readability
    //
    const v_instance = vulkan_core.instance_dispatch;
    const v_device = vulkan_core.device_dispatch;

    // Query and select appropriate surface format for swapchain

    const surface_format_opt = try selectSurfaceFormat(allocator, .srgb_nonlinear_khr, .b8g8r8a8_unorm);
    if (surface_format_opt) |format| {
        swapchain_surface_format = format;
    } else {
        return error.RequiredSurfaceFormatUnavailable;
    }

    const mesh_memory_index: u32 = blk: {
        // Find the best memory type for storing mesh + texture data
        // Requirements:
        //   - Sufficient space (20mib)
        //   - Host visible (Host refers to CPU. Allows for direct access without needing DMA)
        // Preferable
        //  - Device local (Memory on the GPU / APU)

        const memory_properties = v_instance.getPhysicalDeviceMemoryProperties(vulkan_core.physical_device);
        if (print_vulkan_objects.memory_type_all) {
            std.debug.print("\n** Memory heaps found on system **\n\n", .{});
            printVulkanMemoryHeaps(memory_properties, 0);
            std.debug.print("\n", .{});
        }

        const kib: u32 = 1024;
        const mib: u32 = kib * 1024;
        const minimum_space_required: u32 = mib * 20;

        var memory_type_index: u32 = 0;
        var memory_type_count = memory_properties.memory_type_count;

        var suitable_memory_type_index_opt: ?u32 = null;

        while (memory_type_index < memory_type_count) : (memory_type_index += 1) {
            const memory_entry = memory_properties.memory_types[memory_type_index];
            const heap_index = memory_entry.heap_index;

            if (heap_index == memory_properties.memory_heap_count) {
                std.log.warn("Invalid heap index {d} for memory type at index {d}. Skipping", .{ heap_index, memory_type_index });
                continue;
            }

            const heap_size = memory_properties.memory_heaps[heap_index].size;

            if (heap_size < minimum_space_required) {
                continue;
            }

            const memory_flags = memory_entry.property_flags;
            if (memory_flags.host_visible_bit) {
                suitable_memory_type_index_opt = memory_type_index;
                if (memory_flags.device_local_bit) {
                    std.log.info("Selected memory for mesh buffer: Heap index ({d}) Memory index ({d})", .{ heap_index, memory_type_index });
                    break :blk memory_type_index;
                }
            }
        }

        if (suitable_memory_type_index_opt) |suitable_memory_type_index| {
            break :blk suitable_memory_type_index;
        }

        return error.NoValidVulkanMemoryTypes;
    };

    // TODO:
    selected_memory_index = mesh_memory_index;

    const surface_capabilities = try v_instance.getPhysicalDeviceSurfaceCapabilitiesKHR(vulkan_core.physical_device, vulkan_core.surface);

    if (print_vulkan_objects.surface_abilties) {
        std.debug.print("** Selected surface capabilites **\n\n", .{});
        printSurfaceCapabilities(surface_capabilities, 1);
        std.debug.print("\n", .{});
    }

    if (transparancy_enabled) {
        // Check to see if the compositor supports transparent windows and what
        // transparency mode needs to be set when creating the swapchain
        const supported = surface_capabilities.supported_composite_alpha;
        if (supported.pre_multiplied_bit_khr) {
            alpha_mode = .{ .pre_multiplied_bit_khr = true };
        } else if (supported.post_multiplied_bit_khr) {
            alpha_mode = .{ .post_multiplied_bit_khr = true };
        } else if (supported.inherit_bit_khr) {
            alpha_mode = .{ .inherit_bit_khr = true };
        } else {
            std.log.info("Alpha windows not supported", .{});
        }
    }

    if (surface_capabilities.current_extent.width == 0xFFFFFFFF or surface_capabilities.current_extent.height == 0xFFFFFFFF) {
        swapchain_extent.width = swapchain_dimensions.width;
        swapchain_extent.height = swapchain_dimensions.height;
    }

    std.debug.assert(swapchain_extent.width >= surface_capabilities.min_image_extent.width);
    std.debug.assert(swapchain_extent.height >= surface_capabilities.min_image_extent.height);

    std.debug.assert(swapchain_extent.width <= surface_capabilities.max_image_extent.width);
    std.debug.assert(swapchain_extent.height <= surface_capabilities.max_image_extent.height);

    swapchain_min_image_count = surface_capabilities.min_image_count + 1;

    // TODO: Perhaps more flexibily should be allowed here. I'm unsure if an application is
    //       supposed to match the rotation of the system / monitor, but I would assume not..
    //       It is also possible that the inherit_bit_khr bit would be set in place of identity_bit_khr
    if (surface_capabilities.current_transform.identity_bit_khr == false) {
        std.log.err("Selected surface does not have the option to leave framebuffer image untransformed." ++
            "This is likely a vulkan bug.", .{});
        return error.VulkanSurfaceTransformInvalid;
    }

    swapchain = try v_device.createSwapchainKHR(vulkan_core.logical_device, &vk.SwapchainCreateInfoKHR{
        .surface = vulkan_core.surface,
        .min_image_count = swapchain_min_image_count,
        .image_format = swapchain_surface_format.format,
        .image_color_space = swapchain_surface_format.color_space,
        .image_extent = swapchain_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_src_bit = true },
        .image_sharing_mode = .exclusive,
        // NOTE: Only valid when `image_sharing_mode` is CONCURRENT
        // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/VkSwapchainCreateInfoKHR.html
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .pre_transform = .{ .identity_bit_khr = true },
        .composite_alpha = alpha_mode,
        // NOTE: FIFO_KHR is required to be available for all vulkan capable devices
        //       For that reason we don't need to query for it on our selected device
        // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/VkPresentModeKHR.html
        .present_mode = .fifo_khr,
        .clipped = vk.TRUE,
        .flags = .{},
        .old_swapchain = .null_handle,
    }, null);

    swapchain_images = blk: {
        var image_count: u32 = undefined;
        if (.success != (try v_device.getSwapchainImagesKHR(vulkan_core.logical_device, swapchain, &image_count, null))) {
            return error.FailedToGetSwapchainImagesCount;
        }

        var images = try allocator.alloc(vk.Image, image_count);
        if (.success != (try v_device.getSwapchainImagesKHR(vulkan_core.logical_device, swapchain, &image_count, images.ptr))) {
            return error.FailedToGetSwapchainImages;
        }

        break :blk images;
    };

    swapchain_image_views = try allocator.alloc(vk.ImageView, swapchain_images.len);
    try createSwapchainImageViews();

    try render_pass.init(swapchain_extent, swapchain_surface_format.format, selected_memory_index);

    {
        const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = vulkan_core.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        try v_device.allocateCommandBuffers(
            vulkan_core.logical_device,
            &command_buffer_allocate_info,
            @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
        );
    }

    {
        command_buffers = try allocator.alloc(vk.CommandBuffer, swapchain_images.len);
        const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = vulkan_core.command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(u32, command_buffers.len),
        };
        try v_device.allocateCommandBuffers(
            vulkan_core.logical_device,
            &command_buffer_allocate_info,
            command_buffers.ptr,
        );
    }

    // Overallocate to take memory lost to alignment padding into account
    const memory_padding = 256;
    var host_local_allocator = try VulkanAllocator.init(
        mesh_memory_index,
        defines.memory.host_local.size_bytes + memory_padding,
    );

    // TODO:
    images_available = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    renders_finished = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    inflight_fences = try allocator.alloc(vk.Fence, max_frames_in_flight);

    const semaphore_create_info = vk.SemaphoreCreateInfo{
        .flags = .{},
    };

    // TODO: Audit
    const fence_create_info = vk.FenceCreateInfo{
        .flags = .{ .signaled_bit = true },
    };

    var i: u32 = 0;
    while (i < max_frames_in_flight) {
        images_available[i] = try v_device.createSemaphore(vulkan_core.logical_device, &semaphore_create_info, null);
        renders_finished[i] = try v_device.createSemaphore(vulkan_core.logical_device, &semaphore_create_info, null);
        inflight_fences[i] = try v_device.createFence(vulkan_core.logical_device, &fence_create_info, null);
        i += 1;
    }

    std.debug.assert(swapchain_images.len > 0);

    try createFramebuffers(allocator, swapchain_dimensions);

    try texture_pipeline.init(
        .{ .width = 2048, .height = 2048 },
        @intCast(u32, swapchain_images.len),
        swapchain_dimensions,
        &host_local_allocator,
    );

    try generic_pipeline.init(
        allocator,
        jobs_command_buffer,
        vulkan_core.graphics_present_queue,
        @intCast(u32, swapchain_images.len),
        &host_local_allocator,
    );
}

pub fn createVideoCanvas(width: u32, height: u32) !VideoCanvasHandle {
    std.debug.assert(width <= std.math.maxInt(u16));
    std.debug.assert(height <= std.math.maxInt(u16));
    const result = VideoCanvasHandle{
        .x = 0,
        .y = 0,
        .width = @intCast(u16, width),
        .height = @intCast(u16, height),
    };
    video_stream = result;
    return result;
}

pub fn faceWriter() graphics.FaceWriter {
    return graphics.FaceWriter.init(
        generic_pipeline.vertices_buffer,
        generic_pipeline.indices_buffer,
    );
}

pub fn recreateSwapchain(screen_dimensions: geometry.Dimensions2D(u16)) !void {
    if (swapchain_extent.width == screen_dimensions.width and swapchain_extent.height == screen_dimensions.height)
        return;

    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    const recreate_swapchain_start = std.time.nanoTimestamp();

    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[previous_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    try render_pass.resizeSwapchain(screen_dimensions);

    for (swapchain_image_views) |image_view| {
        device_dispatch.destroyImageView(logical_device, image_view, null);
    }

    swapchain_extent.width = screen_dimensions.width;
    swapchain_extent.height = screen_dimensions.height;

    const old_swapchain = swapchain;
    swapchain = try device_dispatch.createSwapchainKHR(logical_device, &vk.SwapchainCreateInfoKHR{
        .surface = vulkan_core.surface,
        .min_image_count = swapchain_min_image_count,
        .image_format = swapchain_surface_format.format,
        .image_color_space = swapchain_surface_format.color_space,
        .image_extent = swapchain_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .pre_transform = .{ .identity_bit_khr = true },
        .composite_alpha = alpha_mode,
        .present_mode = .fifo_khr,
        .clipped = vk.TRUE,
        .flags = .{},
        .old_swapchain = old_swapchain,
    }, null);

    device_dispatch.destroySwapchainKHR(logical_device, old_swapchain, null);

    var image_count: u32 = undefined;
    {
        if (.success != (try device_dispatch.getSwapchainImagesKHR(logical_device, swapchain, &image_count, null))) {
            return error.FailedToGetSwapchainImagesCount;
        }
        //
        // TODO: handle this
        //
        std.debug.assert(image_count == swapchain_images.len);
    }

    if (.success != (try device_dispatch.getSwapchainImagesKHR(logical_device, swapchain, &image_count, swapchain_images.ptr))) {
        return error.FailedToGetSwapchainImages;
    }
    try createSwapchainImageViews();

    for (framebuffers) |framebuffer| {
        device_dispatch.destroyFramebuffer(logical_device, framebuffer, null);
    }

    {
        var framebuffer_create_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass.pass,
            .attachment_count = 2,
            // We assign to `p_attachments` below in the loop
            .p_attachments = undefined,
            .width = screen_dimensions.width,
            .height = screen_dimensions.height,
            .layers = 1,
            .flags = .{},
        };
        var attachment_buffer = [2]vk.ImageView{ render_pass.multisampled_image_view, undefined };
        var i: u32 = 0;
        while (i < swapchain_image_views.len) : (i += 1) {
            // We reuse framebuffer_create_info for each framebuffer we create,
            // only updating the swapchain_image_view that is attached
            attachment_buffer[1] = swapchain_image_views[i];
            framebuffer_create_info.p_attachments = &attachment_buffer;
            framebuffers[i] = try device_dispatch.createFramebuffer(logical_device, &framebuffer_create_info, null);
        }
    }

    const recreate_swapchain_end = std.time.nanoTimestamp();
    std.debug.assert(recreate_swapchain_end >= recreate_swapchain_start);
    const recreate_swapchain_duration = @intCast(u64, recreate_swapchain_end - recreate_swapchain_start);

    std.log.info("Swapchain resized to {}x{} in {}", .{
        screen_dimensions.width,
        screen_dimensions.height,
        std.fmt.fmtDuration(recreate_swapchain_duration),
    });
}

pub fn recordRenderPass(
    indices_count: u32,
    screen_dimensions: geometry.Dimensions2D(u16),
) !void {
    std.debug.assert(command_buffers.len > 0);
    std.debug.assert(swapchain_images.len == command_buffers.len);

    if (screen_dimensions.width != swapchain_extent.width or screen_dimensions.height != swapchain_extent.height) {
        try recreateSwapchain(screen_dimensions);
        return;
    }

    std.debug.assert(screen_dimensions.width == swapchain_extent.width);
    std.debug.assert(screen_dimensions.height == swapchain_extent.height);

    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const command_pool = vulkan_core.command_pool;

    // TODO: Audit
    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[previous_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    try device_dispatch.resetCommandPool(logical_device, command_pool, .{});

    const clear_color = graphics.RGBA(f32){ .r = 0.12, .g = 0.12, .b = 0.12, .a = 1.0 };
    const clear_colors = [2]vk.ClearValue{
        .{
            .color = vk.ClearColorValue{
                .float_32 = @bitCast([4]f32, clear_color),
            },
        },
        .{
            .color = vk.ClearColorValue{
                .float_32 = @bitCast([4]f32, clear_color),
            },
        },
    };

    {
        //
        // Screen coordinates
        //
        const vertex_x: f32 = video_stream_placement.x;
        const vertex_y: f32 = video_stream_placement.y;
        const vertex_width: f32 = video_stream_output_dimensions.width;
        const vertex_height: f32 = video_stream_output_dimensions.height;
        var vertex_top_left = &texture_pipeline.vertices_buffer[0];
        var vertex_top_right = &texture_pipeline.vertices_buffer[1];
        var vertex_bottom_right = &texture_pipeline.vertices_buffer[2];
        var vertex_bottom_left = &texture_pipeline.vertices_buffer[3];
        vertex_top_left.x = vertex_x;
        vertex_top_left.y = vertex_y - vertex_height;
        vertex_top_right.x = vertex_x + vertex_width;
        vertex_top_right.y = vertex_y - vertex_height;
        vertex_bottom_right.x = vertex_x + vertex_width;
        vertex_bottom_right.y = vertex_y;
        vertex_bottom_left.x = vertex_x;
        vertex_bottom_left.y = vertex_y;
        //
        // UV coordinates
        //
        const texture_x: f32 = 0;
        const texture_y: f32 = 0;
        const texture_width: f32 = video_stream_scaled_dimensions.width / @as(f32, defines.memory.pipeline_video.framebuffer_dimensions.width);
        const texture_height: f32 = video_stream_scaled_dimensions.height / @as(f32, defines.memory.pipeline_video.framebuffer_dimensions.height);
        std.debug.assert(texture_width <= 1.0);
        std.debug.assert(texture_width >= 0.0);
        vertex_top_left.u = texture_x;
        vertex_top_left.v = texture_y;
        vertex_top_right.u = texture_x + texture_width;
        vertex_top_right.v = texture_y;
        vertex_bottom_right.u = texture_x + texture_width;
        vertex_bottom_right.v = texture_y + texture_height;
        vertex_bottom_left.u = texture_x;
        vertex_bottom_left.v = texture_y + texture_height;
        //
        // Indices
        //
        texture_pipeline.indices_buffer[0] = 0;
        texture_pipeline.indices_buffer[1] = 1;
        texture_pipeline.indices_buffer[2] = 2;
        texture_pipeline.indices_buffer[3] = 0;
        texture_pipeline.indices_buffer[4] = 2;
        texture_pipeline.indices_buffer[5] = 3;
    }

    for (command_buffers, 0..) |command_buffer, i| {
        try device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        });

        if (video_stream_enabled) {
            //
            // Rescale image from unscaled to texture
            //
            const subresource_layers = vk.ImageSubresourceLayers{
                .aspect_mask = .{ .color_bit = true },
                .layer_count = 1,
                .mip_level = 0,
                .base_array_layer = 0,
            };

            var src_region_offsets = [2]vk.Offset3D{
                .{ .x = 0, .y = 0, .z = 0 },
                .{
                    .x = @floatToInt(i32, video_stream_dimensions.width),
                    .y = @floatToInt(i32, video_stream_dimensions.height),
                    .z = 1,
                },
            };
            const dst_region_offsets = [2]vk.Offset3D{
                .{ .x = 0, .y = 0, .z = 0 },
                .{
                    .x = @floatToInt(i32, @floor(video_stream_scaled_dimensions.width)),
                    .y = @floatToInt(i32, @floor(video_stream_scaled_dimensions.height)),
                    .z = 1,
                },
            };

            const regions = [_]vk.ImageBlit{.{
                .src_subresource = subresource_layers,
                .src_offsets = src_region_offsets,
                .dst_subresource = subresource_layers,
                .dst_offsets = dst_region_offsets,
            }};

            device_dispatch.cmdBlitImage(
                command_buffer,
                texture_pipeline.unscaled_image,
                .general,
                texture_pipeline.texture_image,
                .general,
                1,
                &regions,
                .linear,
            );
        }

        device_dispatch.cmdBeginRenderPass(command_buffer, &vk.RenderPassBeginInfo{
            .render_pass = render_pass.pass,
            .framebuffer = framebuffers[i],
            .render_area = vk.Rect2D{
                .offset = vk.Offset2D{
                    .x = 0,
                    .y = 0,
                },
                .extent = swapchain_extent,
            },
            .clear_value_count = clear_colors.len,
            .p_clear_values = &clear_colors,
        }, .@"inline");

        device_dispatch.cmdBindPipeline(
            command_buffer,
            .graphics,
            generic_pipeline.graphics_pipeline,
        );

        {
            const viewports = [1]vk.Viewport{
                vk.Viewport{
                    .x = 0.0,
                    .y = 0.0,
                    .width = @intToFloat(f32, screen_dimensions.width),
                    .height = @intToFloat(f32, screen_dimensions.height),
                    .min_depth = 0.0,
                    .max_depth = 1.0,
                },
            };
            device_dispatch.cmdSetViewport(command_buffer, 0, 1, @ptrCast([*]const vk.Viewport, &viewports));
        }
        {
            const scissors = [1]vk.Rect2D{
                vk.Rect2D{
                    .offset = vk.Offset2D{
                        .x = 0,
                        .y = 0,
                    },
                    .extent = vk.Extent2D{
                        .width = screen_dimensions.width,
                        .height = screen_dimensions.height,
                    },
                },
            };
            device_dispatch.cmdSetScissor(command_buffer, 0, 1, @ptrCast([*]const vk.Rect2D, &scissors));
        }

        const vertex_buffers = [_]vk.Buffer{generic_pipeline.vulkan_vertices_buffer};
        device_dispatch.cmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &[1]vk.DeviceSize{0});
        device_dispatch.cmdBindIndexBuffer(command_buffer, generic_pipeline.vulkan_indices_buffer, 0, .uint16);
        device_dispatch.cmdBindDescriptorSets(
            command_buffer,
            .graphics,
            generic_pipeline.pipeline_layout,
            0,
            1,
            &[1]vk.DescriptorSet{generic_pipeline.descriptor_sets[i]},
            0,
            undefined,
        );

        const push_constant = generic_pipeline.PushConstant{
            .width = @intToFloat(f32, screen_dimensions.width),
            .height = @intToFloat(f32, screen_dimensions.height),
            .frame = 0.0,
        };

        device_dispatch.cmdPushConstants(
            command_buffer,
            generic_pipeline.pipeline_layout,
            .{ .fragment_bit = true },
            0,
            @sizeOf(generic_pipeline.PushConstant),
            &push_constant,
        );
        device_dispatch.cmdDrawIndexed(command_buffer, indices_count, 1, 0, 0, 0);

        //
        // Video pipeline
        //
        if (video_stream_enabled) {
            device_dispatch.cmdBindPipeline(
                command_buffer,
                .graphics,
                texture_pipeline.graphics_pipeline,
            );

            {
                const viewports = [1]vk.Viewport{
                    vk.Viewport{
                        .x = 0.0,
                        .y = 0.0,
                        .width = @intToFloat(f32, screen_dimensions.width),
                        .height = @intToFloat(f32, screen_dimensions.height),
                        .min_depth = 0.0,
                        .max_depth = 1.0,
                    },
                };
                device_dispatch.cmdSetViewport(command_buffer, 0, 1, @ptrCast([*]const vk.Viewport, &viewports));
            }
            {
                const scissors = [1]vk.Rect2D{
                    vk.Rect2D{
                        .offset = vk.Offset2D{
                            .x = 0,
                            .y = 0,
                        },
                        .extent = vk.Extent2D{
                            .width = screen_dimensions.width,
                            .height = screen_dimensions.height,
                        },
                    },
                };
                device_dispatch.cmdSetScissor(command_buffer, 0, 1, @ptrCast([*]const vk.Rect2D, &scissors));
            }

            const video_vertex_buffers = [_]vk.Buffer{texture_pipeline.vulkan_vertices_buffer};
            device_dispatch.cmdBindVertexBuffers(command_buffer, 0, 1, &video_vertex_buffers, &[1]vk.DeviceSize{0});
            device_dispatch.cmdBindIndexBuffer(command_buffer, texture_pipeline.vulkan_indices_buffer, 0, .uint16);
            device_dispatch.cmdBindDescriptorSets(
                command_buffer,
                .graphics,
                texture_pipeline.pipeline_layout,
                0,
                1,
                &[1]vk.DescriptorSet{texture_pipeline.descriptor_set_buffer[i]},
                0,
                undefined,
            );
            device_dispatch.cmdDrawIndexed(command_buffer, 6, 1, 0, 0, 0);
        }
        device_dispatch.cmdEndRenderPass(command_buffer);
        try device_dispatch.endCommandBuffer(command_buffer);
    }
}

pub const Texture = struct {
    pixels: [*]graphics.RGBA(f32),
    width: u32,
    height: u32,
};

pub fn textureGet() !Texture {
    try transitionTextureToGeneral();
    const pixel_count = @intCast(u32, texture_layer_dimensions.width) * texture_layer_dimensions.height;
    return Texture{
        .pixels = generic_pipeline.texture_memory_map[0..pixel_count],
        .width = texture_layer_dimensions.width,
        .height = texture_layer_dimensions.height,
    };
}

pub fn textureCommit() !void {
    try transitionTextureToOptimal();
}

fn transitionTextureToGeneral() !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan_core.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };

    try device_dispatch.allocateCommandBuffers(
        logical_device,
        &command_buffer_allocate_info,
        @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
    );

    try device_dispatch.beginCommandBuffer(jobs_command_buffer, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const barrier = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{ .shader_read_bit = true },
            .dst_access_mask = .{},
            .old_layout = .shader_read_only_optimal,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = generic_pipeline.texture_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
    };
    const src_stage = vk.PipelineStageFlags{ .fragment_shader_bit = true };
    const dst_stage = vk.PipelineStageFlags{ .bottom_of_pipe_bit = true };
    const dependency_flags = vk.DependencyFlags{};
    device_dispatch.cmdPipelineBarrier(
        jobs_command_buffer,
        src_stage,
        dst_stage,
        dependency_flags,
        0,
        undefined,
        0,
        undefined,
        1,
        &barrier,
    );

    try device_dispatch.endCommandBuffer(jobs_command_buffer);

    const submit_command_infos = [_]vk.SubmitInfo{.{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    }};

    const job_fence = try device_dispatch.createFence(
        logical_device,
        &.{ .flags = .{ .signaled_bit = false } },
        null,
    );

    try device_dispatch.queueSubmit(vulkan_core.graphics_present_queue, 1, &submit_command_infos, job_fence);
    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &job_fence),
        vk.TRUE,
        std.time.ns_per_s * 2,
    );
    device_dispatch.destroyFence(logical_device, job_fence, null);
    device_dispatch.freeCommandBuffers(
        logical_device,
        vulkan_core.command_pool,
        1,
        @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
    );
}

fn transitionTextureToOptimal() !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan_core.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    try device_dispatch.allocateCommandBuffers(
        logical_device,
        &command_buffer_allocate_info,
        @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
    );
    try device_dispatch.beginCommandBuffer(jobs_command_buffer, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const barrier = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .general,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = generic_pipeline.texture_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
    };

    {
        const src_stage = vk.PipelineStageFlags{ .top_of_pipe_bit = true };
        const dst_stage = vk.PipelineStageFlags{ .fragment_shader_bit = true };
        const dependency_flags = vk.DependencyFlags{};
        device_dispatch.cmdPipelineBarrier(
            jobs_command_buffer,
            src_stage,
            dst_stage,
            dependency_flags,
            0,
            undefined,
            0,
            undefined,
            1,
            &barrier,
        );
    }

    try device_dispatch.endCommandBuffer(jobs_command_buffer);

    const submit_command_infos = [_]vk.SubmitInfo{.{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    }};

    const job_fence = try device_dispatch.createFence(logical_device, &.{ .flags = .{} }, null);
    try device_dispatch.queueSubmit(vulkan_core.graphics_present_queue, 1, &submit_command_infos, job_fence);
    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &job_fence),
        vk.TRUE,
        std.time.ns_per_s * 4,
    );
    device_dispatch.destroyFence(logical_device, job_fence, null);
    device_dispatch.freeCommandBuffers(
        logical_device,
        vulkan_core.command_pool,
        1,
        @ptrCast([*]vk.CommandBuffer, &jobs_command_buffer),
    );
}

pub fn addTexture(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: [*]const graphics.RGBA(u8),
) !ImageHandle {
    _ = try vulkan_core.device_dispatch.waitForFences(
        vulkan_core.logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[previous_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );
    try transitionTextureToGeneral();

    const dst_extent = try texture_atlas.reserve(geometry.Extent2D(u32), allocator, width, height);
    var src_y: u32 = 0;
    while (src_y < height) : (src_y += 1) {
        var src_x: u32 = 0;
        while (src_x < width) : (src_x += 1) {
            const src_index = src_x + (src_y * width);
            const dst_index = dst_extent.x + src_x + ((dst_extent.y + src_y) * texture_layer_dimensions.width);
            // const pixel = pixels[src_index];
            // _ = pixel;
            // const value: f32 = @intToFloat(f32, @intCast(u16, pixel.r) + @intCast(u16, pixel.g) + @intCast(u16, pixel.b)) / @as(f32, 255.0 * 3.0);
            // std.debug.assert(value <= 1.0);
            // std.debug.assert(value >= 0.0);
            generic_pipeline.texture_memory_map[dst_index].r = 1.0; // @intToFloat(f32, pixels[src_index].r) / 255;
            generic_pipeline.texture_memory_map[dst_index].g = 1.0; // @intToFloat(f32, pixels[src_index].g) / 255;
            generic_pipeline.texture_memory_map[dst_index].b = 1.0; // @intToFloat(f32, pixels[src_index].b) / 255;
            generic_pipeline.texture_memory_map[dst_index].a = @intToFloat(f32, pixels[src_index].a) / 255;
        }
    }
    std.debug.assert(dst_extent.width == width);
    std.debug.assert(dst_extent.height == height);

    try transitionTextureToOptimal();

    return ImageHandle{
        .texture_array_index = 0,
        .x = @intCast(u12, dst_extent.x),
        .y = @intCast(u12, dst_extent.y),
        ._width = @intCast(u12, dst_extent.width),
        ._height = @intCast(u12, dst_extent.height),
        .reserved = 0,
    };
}

pub fn renderFrame(screen_dimensions: geometry.Dimensions2D(u16)) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    //
    // TODO: Audit Fence management
    //
    _ = try device_dispatch.waitForFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[current_frame]),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    try device_dispatch.resetFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[current_frame]),
    );

    const acquire_image_result = try device_dispatch.acquireNextImageKHR(
        logical_device,
        swapchain,
        std.math.maxInt(u64),
        images_available[current_frame],
        .null_handle,
    );

    // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/vkAcquireNextImageKHR.html
    switch (acquire_image_result.result) {
        .success => {},
        .error_out_of_date_khr, .suboptimal_khr => {
            std.log.warn("error_out_of_date_khr or suboptimal_khr", .{});
            try recreateSwapchain(screen_dimensions);
            return;
        },
        .error_out_of_host_memory => return error.VulkanHostOutOfMemory,
        .error_out_of_device_memory => return error.VulkanDeviceOutOfMemory,
        .error_device_lost => return error.VulkanDeviceLost,
        .error_surface_lost_khr => return error.VulkanSurfaceLost,
        .error_full_screen_exclusive_mode_lost_ext => return error.VulkanFullScreenExclusiveModeLost,
        .timeout => return error.VulkanAcquireFramebufferImageTimeout,
        .not_ready => return error.VulkanAcquireFramebufferImageNotReady,
        else => return error.VulkanAcquireNextImageUnknown,
    }

    const swapchain_image_index = acquire_image_result.image_index;

    const wait_semaphores = [1]vk.Semaphore{images_available[current_frame]};
    const wait_stages = [1]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
    const signal_semaphores = [1]vk.Semaphore{renders_finished[current_frame]};

    const command_submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = @ptrCast([*]align(4) const vk.PipelineStageFlags, &wait_stages),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &command_buffers[swapchain_image_index]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = &signal_semaphores,
    };

    try device_dispatch.queueSubmit(
        vulkan_core.graphics_present_queue,
        1,
        @ptrCast([*]const vk.SubmitInfo, &command_submit_info),
        inflight_fences[current_frame],
    );

    const swapchains = [1]vk.SwapchainKHR{swapchain};
    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &signal_semaphores,
        .swapchain_count = 1,
        .p_swapchains = &swapchains,
        .p_image_indices = @ptrCast([*]const u32, &swapchain_image_index),
        .p_results = null,
    };

    const present_result = try device_dispatch.queuePresentKHR(vulkan_core.graphics_present_queue, &present_info);

    // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/vkQueuePresentKHR.html
    switch (present_result) {
        .success => {},
        .error_out_of_date_khr, .suboptimal_khr => {
            try recreateSwapchain(screen_dimensions);
            return;
        },
        .error_out_of_host_memory => return error.VulkanHostOutOfMemory,
        .error_out_of_device_memory => return error.VulkanDeviceOutOfMemory,
        .error_device_lost => return error.VulkanDeviceLost,
        .error_surface_lost_khr => return error.VulkanSurfaceLost,
        .error_full_screen_exclusive_mode_lost_ext => return error.VulkanFullScreenExclusiveModeLost,
        .timeout => return error.VulkanAcquireFramebufferImageTimeout,
        .not_ready => return error.VulkanAcquireFramebufferImageNotReady,
        else => {
            return error.VulkanQueuePresentUnknown;
        },
    }

    previous_frame = current_frame;
    current_frame = (current_frame + 1) % max_frames_in_flight;
}

fn createSwapchainImageViews() !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    for (swapchain_image_views, 0..) |*image_view, image_view_i| {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .image = swapchain_images[image_view_i],
            .view_type = .@"2d",
            .format = swapchain_surface_format.format,
            .components = vk.ComponentMapping{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = vk.ImageSubresourceRange{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .flags = .{},
        };
        image_view.* = try device_dispatch.createImageView(logical_device, &image_view_create_info, null);
    }
}

fn cleanupSwapchain(allocator: std.mem.Allocator) void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    device_dispatch.freeCommandBuffers(
        logical_device,
        vulkan_core.command_pool,
        @intCast(u32, command_buffers.len),
        command_buffers.ptr,
    );
    allocator.free(command_buffers);

    for (swapchain_image_views) |image_view| {
        device_dispatch.destroyImageView(logical_device, image_view, null);
    }
    device_dispatch.destroySwapchainKHR(logical_device, swapchain, null);
}

fn createFramebuffers(
    allocator: std.mem.Allocator,
    screen_dimensions: geometry.Dimensions2D(u16),
) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    std.debug.assert(swapchain_image_views.len > 0);
    var framebuffer_create_info = vk.FramebufferCreateInfo{
        .render_pass = render_pass.pass,
        .attachment_count = 2,
        .p_attachments = undefined,
        .width = screen_dimensions.width,
        .height = screen_dimensions.height,
        .layers = 1,
        .flags = .{},
    };

    framebuffers = try allocator.alloc(vk.Framebuffer, swapchain_image_views.len);
    var attachment_buffer = [2]vk.ImageView{ render_pass.multisampled_image_view, undefined };
    var i: u32 = 0;
    while (i < swapchain_image_views.len) : (i += 1) {
        // We reuse framebuffer_create_info for each framebuffer we create,
        // only updating the swapchain_image_view that is attached
        attachment_buffer[1] = swapchain_image_views[i];
        framebuffer_create_info.p_attachments = &attachment_buffer;
        framebuffers[i] = try device_dispatch.createFramebuffer(logical_device, &framebuffer_create_info, null);
    }
}

pub fn deinit(allocator: std.mem.Allocator) void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    device_dispatch.deviceWaitIdle(logical_device) catch std.time.sleep(std.time.ns_per_ms * 20);

    cleanupSwapchain(allocator);

    generic_pipeline.deinit(allocator);

    allocator.free(images_available);
    allocator.free(renders_finished);
    allocator.free(inflight_fences);

    allocator.free(swapchain_image_views);
    allocator.free(swapchain_images);

    allocator.free(framebuffers);

    //
    // TODO: Move to vulkan_core
    //
    vulkan_core.instance_dispatch.destroySurfaceKHR(vulkan_core.instance, vulkan_core.surface, null);
}

fn selectSurfaceFormat(
    allocator: std.mem.Allocator,
    color_space: vk.ColorSpaceKHR,
    surface_format: vk.Format,
) !?vk.SurfaceFormatKHR {
    const physical_device = vulkan_core.physical_device;
    const instance_dispatch = vulkan_core.instance_dispatch;
    var format_count: u32 = undefined;
    if (.success != (try instance_dispatch.getPhysicalDeviceSurfaceFormatsKHR(physical_device, vulkan_core.surface, &format_count, null))) {
        return error.FailedToGetSurfaceFormats;
    }

    if (format_count == 0) {
        // NOTE: This should not happen. As per spec:
        //       "The number of format pairs supported must be greater than or equal to 1"
        // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/vkGetPhysicalDeviceSurfaceFormatsKHR.html
        std.log.err("Selected surface doesn't support any formats. This may be a vulkan driver bug", .{});
        return error.VulkanSurfaceContainsNoSupportedFormats;
    }

    var formats: []vk.SurfaceFormatKHR = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
    defer allocator.free(formats);

    if (.success != (try instance_dispatch.getPhysicalDeviceSurfaceFormatsKHR(physical_device, vulkan_core.surface, &format_count, formats.ptr))) {
        return error.FailedToGetSurfaceFormats;
    }

    for (formats) |format| {
        if (format.format == surface_format and format.color_space == color_space) {
            return format;
        }
    }
    return null;
}

//
// Print Functions
//

fn printVulkanMemoryHeap(memory_properties: vk.PhysicalDeviceMemoryProperties, heap_index: u32, comptime indent_level: u32) void {
    const heap_count: u32 = memory_properties.memory_heap_count;
    std.debug.assert(heap_index <= heap_count);
    const base_indent = "  " ** indent_level;

    const heap_properties = memory_properties.memory_heaps[heap_index];

    const print = std.debug.print;
    print(base_indent ++ "Heap Index #{d}\n", .{heap_index});
    print(base_indent ++ "  Capacity:       {}\n", .{std.fmt.fmtIntSizeDec(heap_properties.size)});
    print(base_indent ++ "  Device Local:   {}\n", .{heap_properties.flags.device_local_bit});
    print(base_indent ++ "  Multi Instance: {}\n", .{heap_properties.flags.multi_instance_bit});
    print(base_indent ++ "  Memory Types:\n", .{});

    const memory_type_count = memory_properties.memory_type_count;

    var memory_type_i: u32 = 0;
    while (memory_type_i < memory_type_count) : (memory_type_i += 1) {
        if (memory_properties.memory_types[memory_type_i].heap_index == heap_index) {
            print(base_indent ++ "    Memory Index #{}\n", .{memory_type_i});
            const memory_flags = memory_properties.memory_types[memory_type_i].property_flags;
            print(base_indent ++ "      Device Local:     {}\n", .{memory_flags.device_local_bit});
            print(base_indent ++ "      Host Visible:     {}\n", .{memory_flags.host_visible_bit});
            print(base_indent ++ "      Host Coherent:    {}\n", .{memory_flags.host_coherent_bit});
            print(base_indent ++ "      Host Cached:      {}\n", .{memory_flags.host_cached_bit});
            print(base_indent ++ "      Lazily Allocated: {}\n", .{memory_flags.lazily_allocated_bit});
            print(base_indent ++ "      Protected:        {}\n", .{memory_flags.protected_bit});
        }
    }
}

fn printVulkanMemoryHeaps(memory_properties: vk.PhysicalDeviceMemoryProperties, comptime indent_level: u32) void {
    var heap_count: u32 = memory_properties.memory_heap_count;
    var heap_i: u32 = 0;
    while (heap_i < heap_count) : (heap_i += 1) {
        printVulkanMemoryHeap(memory_properties, heap_i, indent_level);
    }
}

fn printSurfaceCapabilities(surface_capabilities: vk.SurfaceCapabilitiesKHR, comptime indent_level: u32) void {
    const print = std.debug.print;
    const base_indent = "  " ** indent_level;
    print(base_indent ++ "min_image_count: {d}\n", .{surface_capabilities.min_image_count});
    print(base_indent ++ "max_image_count: {d}\n", .{surface_capabilities.max_image_count});

    print(base_indent ++ "current_extent\n", .{});
    print(base_indent ++ "  width:    {d}\n", .{surface_capabilities.current_extent.width});
    print(base_indent ++ "  height:   {d}\n", .{surface_capabilities.current_extent.height});

    print(base_indent ++ "min_image_extent\n", .{});
    print(base_indent ++ "  width:    {d}\n", .{surface_capabilities.min_image_extent.width});
    print(base_indent ++ "  height:   {d}\n", .{surface_capabilities.min_image_extent.height});

    print(base_indent ++ "max_image_extent\n", .{});
    print(base_indent ++ "  width:    {d}\n", .{surface_capabilities.max_image_extent.width});
    print(base_indent ++ "  height:   {d}\n", .{surface_capabilities.max_image_extent.height});
    print(base_indent ++ "max_image_array_layers: {d}\n", .{surface_capabilities.max_image_array_layers});

    print(base_indent ++ "supported_usages\n", .{});
    const supported_usage_flags = surface_capabilities.supported_usage_flags;
    print(base_indent ++ "  sampled:                          {}\n", .{supported_usage_flags.sampled_bit});
    print(base_indent ++ "  storage:                          {}\n", .{supported_usage_flags.storage_bit});
    print(base_indent ++ "  color_attachment:                 {}\n", .{supported_usage_flags.color_attachment_bit});
    print(base_indent ++ "  depth_stencil:                    {}\n", .{supported_usage_flags.depth_stencil_attachment_bit});
    print(base_indent ++ "  input_attachment:                 {}\n", .{supported_usage_flags.input_attachment_bit});
    print(base_indent ++ "  transient_attachment:             {}\n", .{supported_usage_flags.transient_attachment_bit});
    print(base_indent ++ "  fragment_shading_rate_attachment: {}\n", .{supported_usage_flags.fragment_shading_rate_attachment_bit_khr});
    print(base_indent ++ "  fragment_density_map:             {}\n", .{supported_usage_flags.fragment_density_map_bit_ext});
    print(base_indent ++ "  video_decode_dst:                 {}\n", .{supported_usage_flags.video_decode_dst_bit_khr});
    print(base_indent ++ "  video_decode_dpb:                 {}\n", .{supported_usage_flags.video_decode_dpb_bit_khr});
    print(base_indent ++ "  video_encode_src:                 {}\n", .{supported_usage_flags.video_encode_src_bit_khr});
    print(base_indent ++ "  video_encode_dpb:                 {}\n", .{supported_usage_flags.video_encode_dpb_bit_khr});

    print(base_indent ++ "supportedCompositeAlpha:\n", .{});
    print(base_indent ++ "  Opaque KHR      {}\n", .{surface_capabilities.supported_composite_alpha.opaque_bit_khr});
    print(base_indent ++ "  Pre Mult KHR    {}\n", .{surface_capabilities.supported_composite_alpha.pre_multiplied_bit_khr});
    print(base_indent ++ "  Post Mult KHR   {}\n", .{surface_capabilities.supported_composite_alpha.post_multiplied_bit_khr});
    print(base_indent ++ "  Inherit KHR     {}\n", .{surface_capabilities.supported_composite_alpha.inherit_bit_khr});
}
