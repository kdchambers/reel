// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const geometry = @import("geometry.zig");
const Extent2D = geometry.Extent2D;
const Dimensions2D = geometry.Dimensions2D;

const graphics = @import("graphics.zig");
const RGBA = graphics.RGBA;
const TextureGreyscale = graphics.TextureGreyscale;

const vk = @import("vulkan");

const color_pipeline = @import("renderer/color_pipeline.zig");
const icon_pipeline = @import("renderer/icon_pipeline.zig");
const video_pipeline = @import("renderer/video_pipeline.zig");

const render_pass = @import("renderer/render_pass.zig");
const vulkan_core = @import("renderer/vulkan_core.zig");

const VulkanAllocator = @import("VulkanBumpAllocator.zig");

pub const Surface = opaque {};
pub const Display = opaque {};

const icon_quad_capacity = 512;
const icon_vertex_buffer_capacity = icon_quad_capacity * 4;
const icon_index_buffer_capacity = icon_quad_capacity * 6;

const color_quad_capacity = 256;
const color_vertex_buffer_capacity = color_quad_capacity * 5;
const color_index_buffer_capacity = color_quad_capacity * 6;

const required_cpu_memory: usize = calcRequiredCpuMemory();
const required_gpu_memory: usize = calcRequiredGpuMemory();

const PreviewFrameReadyCallbackFn = fn (pixels: []const RGBA(u8)) void;
pub var onPreviewFrameReady: ?*const PreviewFrameReadyCallbackFn = null;

//
// Draw API
//

pub const VertexRange = color_pipeline.VertexRange; // TODO: move

pub const quadSlice = color_pipeline.quadSlice;
pub const quad = color_pipeline.quad;
pub const vertexSlice = color_pipeline.vertexSlice;
pub const nextVertexIndex = color_pipeline.nextVertexIndex;

pub const reserveQuad = color_pipeline.reserveQuad;
pub const reserveQuads = color_pipeline.reserveQuads;
pub const drawTriangle = color_pipeline.drawTriangle;
pub const drawQuad = color_pipeline.drawQuad;
pub const overwriteQuad = color_pipeline.overwriteQuad;
pub const drawRoundedRect = color_pipeline.drawRoundedRect;
pub const drawCircle = color_pipeline.drawCircle;
pub const drawArc = color_pipeline.drawArc;
pub const updateQuadColor = color_pipeline.updateQuadColor;
pub const updateQuadRangeColor = color_pipeline.updateQuadRangeColor;
pub const updateVertexRangeColor = color_pipeline.updateVertexRangeColor;
pub const updateVertexRangeHPosition = color_pipeline.updateVertexRangeHPosition;

pub const Icon = icon_pipeline.Icon;

pub const calculateRenderedDimensions = icon_pipeline.calculateRenderedDimensions;
pub const drawIcon = icon_pipeline.drawIcon;
pub const drawGreyscale = icon_pipeline.drawGreyscale;
pub const drawText = icon_pipeline.drawText;
pub const reserveTextBuffer = icon_pipeline.reserveTextBuffer;
pub const overwriteText = icon_pipeline.overwriteText;
pub const overwriteGreyscale = icon_pipeline.overwriteGreyscale;
pub const reserveGreyscale = icon_pipeline.reserveGreyscale;
pub const updateIconColor = icon_pipeline.updateIconColor;
pub const debugDrawTexture = icon_pipeline.debugDrawTexture;

pub const SupportedVideoImageFormat = video_pipeline.SupportedImageFormat;

pub const writeStreamFrame = video_pipeline.writeStreamFrame;
pub const drawVideoFrame = video_pipeline.drawVideoFrame;
pub const addVideoSource = video_pipeline.addVideoSource;
pub const createStream = video_pipeline.createStream;
pub const resizeCanvas = video_pipeline.resizeCanvas;

pub const videoSourceExtents = video_pipeline.videoSourceExtents;
pub const moveSource = video_pipeline.moveSource;
pub const sourceRelativePlacement = video_pipeline.sourceRelativePlacement;
pub const sourceRelativeExtent = video_pipeline.sourceRelativeExtent;

pub const moveEdgeLeft = video_pipeline.moveEdgeLeft;
pub const moveEdgeRight = video_pipeline.moveEdgeRight;
pub const moveEdgeTop = video_pipeline.moveEdgeTop;
pub const moveEdgeBottom = video_pipeline.moveEdgeBottom;

const max_frames_in_flight = 2;

var current_frame: u32 = 0;
var previous_frame: u32 = undefined;

var cpu_memory_index: u32 = undefined;
var gpu_memory_index: u32 = undefined;

var cpu_memory_allocator: VulkanAllocator = undefined;
var gpu_memory_allocator: VulkanAllocator = undefined;

var command_buffers: []vk.CommandBuffer = undefined;

pub var swapchain_dimensions: Dimensions2D(u32) = undefined;
var swapchain: vk.SwapchainKHR = undefined;
var swapchain_images: []vk.Image = undefined;
var swapchain_image_views: []vk.ImageView = undefined;
var swapchain_surface_format: vk.SurfaceFormatKHR = undefined;
var swapchain_min_image_count: u32 = undefined;

var alpha_mode: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true };

var images_available: [max_frames_in_flight]vk.Semaphore = undefined;
var renders_finished: [max_frames_in_flight]vk.Semaphore = undefined;
var inflight_fences: [max_frames_in_flight]vk.Fence = undefined;

var framebuffers: []vk.Framebuffer = undefined;

var allocator: std.mem.Allocator = undefined;

pub inline fn init(
    ally: std.mem.Allocator,
    wayland_display: *Display,
    wayland_surface: *Surface,
    dimensions: Dimensions2D(u32),
) !void {
    swapchain_dimensions = dimensions;
    allocator = ally;

    try vulkan_core.init(@ptrCast(*vk.wl_display, wayland_display), @ptrCast(*vk.wl_surface, wayland_surface));
    cpu_memory_index = findCpuLocalMemoryIndex(required_cpu_memory) orelse return error.InsufficientMemory;
    gpu_memory_index = findGpuLocalMemoryIndex(required_gpu_memory) orelse return error.InsufficientMemory;

    if (comptime required_cpu_memory > 0)
        try cpu_memory_allocator.init(cpu_memory_index, required_cpu_memory);
    if (comptime required_gpu_memory > 0)
        try gpu_memory_allocator.init(gpu_memory_index, required_gpu_memory);

    try setupSwapchain(true);
    const swapchain_image_count = @intCast(u32, swapchain_images.len);
    command_buffers = try allocateCommandBuffers(swapchain_image_count);
    try render_pass.init(swapchain_dimensions, swapchain_surface_format.format, gpu_memory_index);
    try setupSynchronization();

    framebuffers = try allocator.alloc(vk.Framebuffer, swapchain_image_views.len);
    try setupFramebuffers();

    try color_pipeline.init(
        .{
            .vertex_buffer_capacity = color_vertex_buffer_capacity,
            .index_buffer_capacity = color_index_buffer_capacity,
            .viewport_dimensions = swapchain_dimensions,
        },
        &cpu_memory_allocator,
    );

    try icon_pipeline.init(
        .{
            .vertex_buffer_capacity = icon_vertex_buffer_capacity,
            .index_buffer_capacity = icon_index_buffer_capacity,
            .viewport_dimensions = swapchain_dimensions,
        },
        swapchain_image_count,
        &cpu_memory_allocator,
        &gpu_memory_allocator,
        allocator,
    );

    try video_pipeline.init(
        swapchain_dimensions,
        swapchain_image_count,
        &cpu_memory_allocator,
    );
}

pub inline fn deinit() void {
    allocator.free(swapchain_image_views);
    allocator.free(swapchain_images);
    allocator.free(command_buffers);
    allocator.free(framebuffers);
}

pub fn resetVertexBuffers() void {
    color_pipeline.resetVertexBuffer();
    icon_pipeline.resetVertexBuffer();
    video_pipeline.resetVertexBuffer();
}

fn setupSynchronization() !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const semaphore_create_info = vk.SemaphoreCreateInfo{ .flags = .{} };
    const fence_create_info = vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } };
    for (0..max_frames_in_flight) |i| {
        images_available[i] = try device_dispatch.createSemaphore(logical_device, &semaphore_create_info, null);
        renders_finished[i] = try device_dispatch.createSemaphore(logical_device, &semaphore_create_info, null);
        inflight_fences[i] = try device_dispatch.createFence(logical_device, &fence_create_info, null);
    }
}

fn setupFramebuffers() !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    assert(swapchain_image_views.len > 0);
    var framebuffer_create_info = vk.FramebufferCreateInfo{
        .render_pass = render_pass.pass,
        .attachment_count = if (render_pass.have_multisample) 3 else 2,
        .p_attachments = undefined,
        .width = swapchain_dimensions.width,
        .height = swapchain_dimensions.height,
        .layers = 1,
        .flags = .{},
    };

    var attachment_buffer = [3]vk.ImageView{ undefined, render_pass.depth_image_view, render_pass.multisampled_image_view };
    for (0..swapchain_image_views.len) |i| {
        // We reuse framebuffer_create_info for each framebuffer we create,
        // only updating the swapchain_image_view that is attached
        attachment_buffer[0] = swapchain_image_views[i];
        framebuffer_create_info.p_attachments = &attachment_buffer;
        framebuffers[i] = try device_dispatch.createFramebuffer(logical_device, &framebuffer_create_info, null);
    }
}

pub fn resizeSwapchain(dimensions: Dimensions2D(u32)) !void {
    assert(dimensions.width != swapchain_dimensions.width or dimensions.height != swapchain_dimensions.height);
    const start_timestamp = std.time.nanoTimestamp();

    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    swapchain_dimensions = dimensions;

    try waitForFences(&inflight_fences);
    try render_pass.resizeSwapchain(dimensions);

    for (swapchain_image_views, framebuffers) |swapchain_image, framebuffer| {
        device_dispatch.destroyImageView(logical_device, swapchain_image, null);
        device_dispatch.destroyFramebuffer(logical_device, framebuffer, null);
    }

    const old_swapchain = swapchain;
    swapchain = try device_dispatch.createSwapchainKHR(logical_device, &vk.SwapchainCreateInfoKHR{
        .surface = vulkan_core.surface,
        .min_image_count = swapchain_min_image_count,
        .image_format = swapchain_surface_format.format,
        .image_color_space = swapchain_surface_format.color_space,
        .image_extent = .{ .width = swapchain_dimensions.width, .height = swapchain_dimensions.height },
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

    assert(swapchain_images.len == (try getSwapchainImageCount()));
    try getSwapchainImages(swapchain_images);

    for (swapchain_image_views, 0..) |*image_view, i| {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .image = swapchain_images[i],
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

    try setupFramebuffers();

    const end_timestamp = std.time.nanoTimestamp();
    std.log.info("Swapchain resized in {}", .{std.fmt.fmtDuration(@intCast(u64, end_timestamp - start_timestamp))});
}

pub fn recordDrawCommands() !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const command_pool = vulkan_core.command_pool;

    try waitForFences(&inflight_fences);

    try device_dispatch.resetCommandPool(logical_device, command_pool, .{});

    const clear_color = graphics.RGBA(f32).fromInt(28, 30, 35, 255);
    const clear_colors = [3]vk.ClearValue{
        .{ .color = .{ .float_32 = @bitCast([4]f32, clear_color) } },
        .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        .{ .color = .{ .float_32 = @bitCast([4]f32, clear_color) } },
    };

    const swapchain_extent = vk.Extent2D{
        .width = swapchain_dimensions.width,
        .height = swapchain_dimensions.height,
    };

    for (command_buffers, 0..) |command_buffer, i| {
        try device_dispatch.beginCommandBuffer(command_buffer, &.{
            .flags = .{},
            .p_inheritance_info = null,
        });

        try video_pipeline.recordBlitCommand(command_buffer);

        device_dispatch.cmdBeginRenderPass(command_buffer, &vk.RenderPassBeginInfo{
            .render_pass = render_pass.pass,
            .framebuffer = framebuffers[i],
            .render_area = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain_extent },
            .clear_value_count = clear_colors.len,
            .p_clear_values = &clear_colors,
        }, .@"inline");

        try color_pipeline.recordDrawCommands(
            command_buffer,
            i,
            swapchain_dimensions,
        );

        try icon_pipeline.recordDrawCommands(
            command_buffer,
            i,
            swapchain_dimensions,
        );

        try video_pipeline.recordDrawCommands(
            command_buffer,
            i,
            swapchain_dimensions,
        );

        device_dispatch.cmdEndRenderPass(command_buffer);
        try device_dispatch.endCommandBuffer(command_buffer);
    }
}

pub fn renderFrame() !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    try waitForFence(inflight_fences[current_frame]);

    if (onPreviewFrameReady) |callback|
        callback(video_pipeline.unscaledFrame());

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
            assert(false);
            // try recreateSwapchain(screen_dimensions);
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

    try device_dispatch.resetFences(
        logical_device,
        1,
        @ptrCast([*]const vk.Fence, &inflight_fences[current_frame]),
    );

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
            assert(false);
            // try recreateSwapchain(screen_dimensions);
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

fn setupSwapchain(transparancy_enabled: bool) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const instance_dispatch = vulkan_core.instance_dispatch;

    swapchain_surface_format = (try selectSurfaceFormat(.srgb_nonlinear_khr, .b8g8r8a8_unorm)) orelse
        return error.RequiredSurfaceFormatUnavailable;

    const surface_capabilities = try instance_dispatch.getPhysicalDeviceSurfaceCapabilitiesKHR(vulkan_core.physical_device, vulkan_core.surface);
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

    if (surface_capabilities.current_extent.width != 0xFFFFFFFF) {
        swapchain_dimensions.width = @intCast(u16, surface_capabilities.current_extent.width);
    }

    if (surface_capabilities.current_extent.height != 0xFFFFFFFF) {
        swapchain_dimensions.height = @intCast(u16, surface_capabilities.current_extent.height);
    }

    assert(swapchain_dimensions.width >= surface_capabilities.min_image_extent.width);
    assert(swapchain_dimensions.height >= surface_capabilities.min_image_extent.height);

    assert(swapchain_dimensions.width <= surface_capabilities.max_image_extent.width);
    assert(swapchain_dimensions.height <= surface_capabilities.max_image_extent.height);

    swapchain_min_image_count = surface_capabilities.min_image_count + 1;

    // TODO: Perhaps more flexibily should be allowed here. I'm unsure if an application is
    //       supposed to match the rotation of the system / monitor, but I would assume not..
    //       It is also possible that the inherit_bit_khr bit would be set in place of identity_bit_khr
    if (surface_capabilities.current_transform.identity_bit_khr == false) {
        std.log.err("Selected surface does not have the option to leave framebuffer image untransformed." ++
            "This is likely a vulkan bug.", .{});
        return error.VulkanSurfaceTransformInvalid;
    }

    swapchain = try vulkan_core.device_dispatch.createSwapchainKHR(vulkan_core.logical_device, &vk.SwapchainCreateInfoKHR{
        .surface = vulkan_core.surface,
        .min_image_count = swapchain_min_image_count,
        .image_format = swapchain_surface_format.format,
        .image_color_space = swapchain_surface_format.color_space,
        .image_extent = .{ .width = swapchain_dimensions.width, .height = swapchain_dimensions.height },
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_src_bit = true },
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .pre_transform = .{ .identity_bit_khr = true },
        .composite_alpha = alpha_mode,
        .present_mode = .fifo_khr,
        .clipped = vk.TRUE,
        .flags = .{},
        .old_swapchain = .null_handle,
    }, null);

    const swapchain_image_count = try getSwapchainImageCount();
    swapchain_images = try allocator.alloc(vk.Image, swapchain_image_count);
    try getSwapchainImages(swapchain_images);
    swapchain_image_views = try allocator.alloc(vk.ImageView, swapchain_images.len);
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

    std.log.info("Swapchain images: {d}", .{swapchain_images.len});
}

fn getSwapchainImages(swapchain_image_buffer: []vk.Image) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    var image_count = @intCast(u32, swapchain_image_buffer.len);
    if (.success != (try device_dispatch.getSwapchainImagesKHR(
        vulkan_core.logical_device,
        swapchain,
        &image_count,
        swapchain_image_buffer.ptr,
    ))) {
        return error.FailedToGetSwapchainImages;
    }
}

fn getSwapchainImageCount() !u32 {
    const device_dispatch = vulkan_core.device_dispatch;
    var image_count: u32 = undefined;
    if (.success != (try device_dispatch.getSwapchainImagesKHR(vulkan_core.logical_device, swapchain, &image_count, null))) {
        return error.FailedToGetSwapchainImagesCount;
    }
    return image_count;
}

fn calcRequiredCpuMemory() usize {
    return comptime blk: {
        var bytes: comptime_int = 0;

        bytes += icon_vertex_buffer_capacity * @sizeOf(icon_pipeline.Vertex);
        bytes += icon_index_buffer_capacity * @sizeOf(u16);
        bytes += 512 * 512; // staging buffer

        bytes += video_pipeline.requiredCpuMemory();

        bytes += color_vertex_buffer_capacity * @sizeOf(color_pipeline.Vertex);
        bytes += color_index_buffer_capacity * @sizeOf(u16);

        bytes += 1024;

        break :blk bytes;
    };
}

fn calcRequiredGpuMemory() usize {
    return 512 * 512;
}

fn findGpuLocalMemoryIndex(minimum_size_bytes: u32) ?u32 {
    const memory_properties = vulkan_core.instance_dispatch.getPhysicalDeviceMemoryProperties(vulkan_core.physical_device);
    var memory_type_index: u32 = 0;
    var memory_type_count = memory_properties.memory_type_count;

    var selected_memory_type_index_opt: ?u32 = null;
    var selected_heap_size: u64 = 0;

    while (memory_type_index < memory_type_count) : (memory_type_index += 1) {
        const memory_entry = memory_properties.memory_types[memory_type_index];
        const heap_index = memory_entry.heap_index;

        if (heap_index == memory_properties.memory_heap_count) {
            continue;
        }

        const heap_size = memory_properties.memory_heaps[heap_index].size;

        if (heap_size < minimum_size_bytes) {
            continue;
        }

        const memory_flags = memory_entry.property_flags;
        if (memory_flags.device_local_bit) {
            if (selected_memory_type_index_opt) |*selected_memory_type_index| {
                if (heap_size > selected_heap_size) {
                    selected_memory_type_index.* = memory_type_index;
                    selected_heap_size = heap_size;
                }
            } else selected_memory_type_index_opt = memory_type_index;
        }
    }

    return selected_memory_type_index_opt;
}

fn findCpuLocalMemoryIndex(minimum_size_bytes: u32) ?u32 {
    const memory_properties = vulkan_core.instance_dispatch.getPhysicalDeviceMemoryProperties(vulkan_core.physical_device);
    var memory_type_index: u32 = 0;
    var memory_type_count = memory_properties.memory_type_count;

    var selected_memory_type_index_opt: ?u32 = null;
    var selected_heap_size: u64 = 0;

    while (memory_type_index < memory_type_count) : (memory_type_index += 1) {
        const memory_entry = memory_properties.memory_types[memory_type_index];
        const heap_index = memory_entry.heap_index;

        if (heap_index == memory_properties.memory_heap_count) {
            continue;
        }

        const heap_size = memory_properties.memory_heaps[heap_index].size;

        if (heap_size < minimum_size_bytes) {
            continue;
        }

        const memory_flags = memory_entry.property_flags;
        if (memory_flags.host_visible_bit) {
            if (selected_memory_type_index_opt) |*selected_memory_type_index| {
                if (heap_size > selected_heap_size) {
                    selected_memory_type_index.* = memory_type_index;
                    selected_heap_size = heap_size;
                }
            } else selected_memory_type_index_opt = memory_type_index;
        }
    }

    return selected_memory_type_index_opt;
}

inline fn waitForFence(fence: vk.Fence) !void {
    _ = try vulkan_core.device_dispatch.waitForFences(
        vulkan_core.logical_device,
        1,
        &[1]vk.Fence{fence},
        vk.TRUE,
        std.math.maxInt(u64),
    );
}

inline fn waitForFences(fences: []vk.Fence) !void {
    assert(fences.len > 0);
    _ = try vulkan_core.device_dispatch.waitForFences(
        vulkan_core.logical_device,
        @intCast(u32, fences.len),
        fences.ptr,
        vk.TRUE,
        std.math.maxInt(u64),
    );
}

fn allocateCommandBuffers(amount: u32) ![]vk.CommandBuffer {
    command_buffers = try allocator.alloc(vk.CommandBuffer, amount);
    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan_core.command_pool,
        .level = .primary,
        .command_buffer_count = amount,
    };
    try vulkan_core.device_dispatch.allocateCommandBuffers(
        vulkan_core.logical_device,
        &command_buffer_allocate_info,
        command_buffers.ptr,
    );
    return command_buffers;
}

fn selectSurfaceFormat(
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

    var formats_buffer: [32]vk.SurfaceFormatKHR = undefined;
    var formats = if (format_count > 32)
        try allocator.alloc(vk.SurfaceFormatKHR, format_count)
    else
        formats_buffer[0..format_count];

    defer if (format_count > 32) allocator.free(formats);

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
