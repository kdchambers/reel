// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const vk = @import("vulkan");
const vulkan_config = @import("vulkan_config.zig");
const shaders = @import("shaders");

const vulkan_core = @import("vulkan_core.zig");
const render_pass = @import("render_pass.zig");
const VulkanAllocator = @import("../VulkanBumpAllocator.zig");

const geometry = @import("../geometry.zig");
const Extent2D = geometry.Extent2D;
const Extent3D = geometry.Extent3D;
const Dimensions2D = geometry.Dimensions2D;

const graphics = @import("../graphics.zig");
const RGBA = graphics.RGBA;
const TextureGreyscale = graphics.TextureGreyscale;

var descriptor_set_layout_buffer: [8]vk.DescriptorSetLayout = undefined;
var descriptor_set_buffer: [8]vk.DescriptorSet = undefined;

var texture_image: vk.Image = undefined;
var descriptor_sets: []vk.DescriptorSet = undefined;
var descriptor_set_layouts: []vk.DescriptorSetLayout = undefined;
var pipeline_layout: vk.PipelineLayout = undefined;
var graphics_pipeline: vk.Pipeline = undefined;
var vertices_buffer: []Vertex = undefined;
var indices_buffer: []u16 = undefined;
var vulkan_vertices_buffer: vk.Buffer = undefined;
var vulkan_indices_buffer: vk.Buffer = undefined;

var texture_image_view: vk.ImageView = undefined;
var vertex_shader_module: vk.ShaderModule = undefined;
var fragment_shader_module: vk.ShaderModule = undefined;
var descriptor_pool: vk.DescriptorPool = undefined;
var sampler: vk.Sampler = undefined;

var vertices_used: u16 = 0;
var indices_used: u16 = 0;

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32 = 0.8,
    u: f32,
    v: f32,
    color: RGBA(u8),
};

const InitOptions = struct {
    vertex_buffer_capacity: u32,
    index_buffer_capacity: u32,
    viewport_dimensions: geometry.Dimensions2D(u32),
};

pub fn resetVertexBuffer() void {
    vertices_used = 0;
    indices_used = 0;
}

pub fn drawIcon(
    extent: Extent3D(f32),
    texture_extent: Extent2D(f32),
    color: RGBA(u8),
    comptime anchor_point: graphics.AnchorPoint,
) *[4]Vertex {
    var quad = @ptrCast(*[4]Vertex, &vertices_buffer[vertices_used]);
    graphics.writeQuad(Vertex, extent, anchor_point, quad);
    quad[0].color = color;
    quad[1].color = color;
    quad[2].color = color;
    quad[3].color = color;
    quad[0].u = texture_extent.x;
    quad[0].v = texture_extent.y;
    quad[1].u = texture_extent.x + texture_extent.width;
    quad[1].v = texture_extent.y;
    quad[2].u = texture_extent.x + texture_extent.width;
    quad[2].v = texture_extent.y + texture_extent.height;
    quad[3].u = texture_extent.x;
    quad[3].v = texture_extent.y + texture_extent.height;
    writeQuadIndices(vertices_used);
    vertices_used += 4;
    return quad;
}

inline fn writeQuadIndices(vertex_offset: u16) void {
    indices_buffer[indices_used + 0] = vertex_offset + 0; // Top left
    indices_buffer[indices_used + 1] = vertex_offset + 1; // Top right
    indices_buffer[indices_used + 2] = vertex_offset + 2; // Bottom right
    indices_buffer[indices_used + 3] = vertex_offset + 0; // Top left
    indices_buffer[indices_used + 4] = vertex_offset + 2; // Bottom right
    indices_buffer[indices_used + 5] = vertex_offset + 3; // Bottom left
    indices_used += 6;
}

pub fn recordDrawCommands(command_buffer: vk.CommandBuffer, i: usize, screen_dimensions: Dimensions2D(u32)) !void {
    const device_dispatch = vulkan_core.device_dispatch;

    device_dispatch.cmdBindPipeline(
        command_buffer,
        .graphics,
        graphics_pipeline,
    );

    {
        const viewports = [1]vk.Viewport{
            .{
                .x = 0.0,
                .y = 0.0,
                .width = @intToFloat(f32, screen_dimensions.width),
                .height = @intToFloat(f32, screen_dimensions.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            },
        };
        device_dispatch.cmdSetViewport(command_buffer, 0, 1, &viewports);
    }
    {
        const scissors = [1]vk.Rect2D{
            .{
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
        device_dispatch.cmdSetScissor(command_buffer, 0, 1, &scissors);
    }

    const vertex_buffers = [_]vk.Buffer{vulkan_vertices_buffer};
    device_dispatch.cmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &[1]vk.DeviceSize{0});
    device_dispatch.cmdBindIndexBuffer(command_buffer, vulkan_indices_buffer, 0, .uint16);
    device_dispatch.cmdBindDescriptorSets(
        command_buffer,
        .graphics,
        pipeline_layout,
        0,
        1,
        &[1]vk.DescriptorSet{descriptor_sets[i]},
        0,
        undefined,
    );

    device_dispatch.cmdDrawIndexed(command_buffer, indices_used, 1, 0, 0, 0);
}

pub fn init(
    options: InitOptions,
    graphics_present_queue: vk.Queue,
    swapchain_image_count: u32,
    cpu_memory_allocator: *VulkanAllocator,
    gpu_memory_allocator: *VulkanAllocator,
    static_texture: TextureGreyscale,
) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const command_pool = vulkan_core.command_pool;

    const initial_viewport_dimensions = options.viewport_dimensions;

    //
    // Create staging buffer for static texture
    //

    const staging_buffer_create_info = vk.BufferCreateInfo{
        .size = static_texture.pixels.len,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .flags = .{},
    };
    const staging_buffer = try device_dispatch.createBuffer(logical_device, &staging_buffer_create_info, null);
    const staging_memory_requirements = device_dispatch.getBufferMemoryRequirements(logical_device, staging_buffer);
    // TODO: Free this memory once transfer is complete
    const staging_buffer_memory_offset = try cpu_memory_allocator.allocate(
        staging_memory_requirements.size,
        staging_memory_requirements.alignment,
    );
    try device_dispatch.bindBufferMemory(
        logical_device,
        staging_buffer,
        cpu_memory_allocator.memory,
        staging_buffer_memory_offset,
    );

    var staging_buffer_memory_map = cpu_memory_allocator.mappedBytes(
        staging_buffer_memory_offset,
        staging_memory_requirements.size,
    );
    @memcpy(
        staging_buffer_memory_map[0..static_texture.pixels.len],
        static_texture.pixels,
    );

    {
        const image_create_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8_unorm,
            .tiling = .optimal,
            .extent = vk.Extent3D{
                .width = static_texture.width,
                .height = static_texture.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .initial_layout = .undefined,
            .usage = .{ .sampled_bit = true, .transfer_dst_bit = true },
            .samples = .{ .@"1_bit" = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };
        texture_image = try device_dispatch.createImage(logical_device, &image_create_info, null);
    }

    const texture_memory_requirements = device_dispatch.getImageMemoryRequirements(logical_device, texture_image);
    const texture_memory_offset = try gpu_memory_allocator.allocate(
        texture_memory_requirements.size,
        texture_memory_requirements.alignment,
    );
    try device_dispatch.bindImageMemory(logical_device, texture_image, gpu_memory_allocator.memory, texture_memory_offset);

    {
        //
        // Transition from undefined to transfer_dst
        //

        var command_buffer: vk.CommandBuffer = undefined;
        const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        try device_dispatch.allocateCommandBuffers(
            logical_device,
            &command_buffer_allocate_info,
            @ptrCast([*]vk.CommandBuffer, &command_buffer),
        );

        try device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        const barrier = [_]vk.ImageMemoryBarrier{
            .{
                .src_access_mask = .{},
                .dst_access_mask = .{ .transfer_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = texture_image,
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
            const dst_stage = vk.PipelineStageFlags{ .transfer_bit = true };
            const dependency_flags = vk.DependencyFlags{};
            device_dispatch.cmdPipelineBarrier(
                command_buffer,
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

        try device_dispatch.endCommandBuffer(command_buffer);

        const submit_command_infos = [_]vk.SubmitInfo{.{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        }};

        {
            const fence_create_info = vk.FenceCreateInfo{
                .flags = .{},
            };
            const fence = try device_dispatch.createFence(logical_device, &fence_create_info, null);

            try device_dispatch.queueSubmit(
                graphics_present_queue,
                1,
                &submit_command_infos,
                fence,
            );

            _ = try device_dispatch.waitForFences(
                logical_device,
                1,
                @ptrCast([*]const vk.Fence, &fence),
                vk.TRUE,
                std.time.ns_per_s * 3,
            );
            device_dispatch.destroyFence(logical_device, fence, null);
            device_dispatch.freeCommandBuffers(
                logical_device,
                command_pool,
                1,
                @ptrCast([*]const vk.CommandBuffer, &command_buffer),
            );
        }
    }

    {
        //
        // Copy buffer to image
        //

        var command_buffer: vk.CommandBuffer = undefined;
        const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        try device_dispatch.allocateCommandBuffers(
            logical_device,
            &command_buffer_allocate_info,
            @ptrCast([*]vk.CommandBuffer, &command_buffer),
        );

        try device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        const region = [_]vk.BufferImageCopy{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{
                .width = static_texture.width,
                .height = static_texture.height,
                .depth = 1,
            },
        }};

        device_dispatch.cmdCopyBufferToImage(command_buffer, staging_buffer, texture_image, .transfer_dst_optimal, 1, &region);
        try device_dispatch.endCommandBuffer(command_buffer);

        const submit_command_infos = [_]vk.SubmitInfo{.{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        }};

        {
            const fence_create_info = vk.FenceCreateInfo{ .flags = .{} };
            const fence = try device_dispatch.createFence(logical_device, &fence_create_info, null);

            try device_dispatch.queueSubmit(
                graphics_present_queue,
                1,
                &submit_command_infos,
                fence,
            );

            _ = try device_dispatch.waitForFences(
                logical_device,
                1,
                @ptrCast([*]const vk.Fence, &fence),
                vk.TRUE,
                std.time.ns_per_s * 3,
            );
            device_dispatch.destroyFence(logical_device, fence, null);
            device_dispatch.freeCommandBuffers(
                logical_device,
                command_pool,
                1,
                @ptrCast([*]const vk.CommandBuffer, &command_buffer),
            );
        }
    }

    {
        //
        // Transition Image from transfer_dst to shader_read_optimal
        //

        var command_buffer: vk.CommandBuffer = undefined;
        const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        try device_dispatch.allocateCommandBuffers(
            logical_device,
            &command_buffer_allocate_info,
            @ptrCast([*]vk.CommandBuffer, &command_buffer),
        );

        try device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        const barrier = [_]vk.ImageMemoryBarrier{
            .{
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .transfer_dst_optimal,
                .new_layout = .shader_read_only_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = texture_image,
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
            const src_stage = vk.PipelineStageFlags{ .transfer_bit = true };
            const dst_stage = vk.PipelineStageFlags{ .fragment_shader_bit = true };
            const dependency_flags = vk.DependencyFlags{};
            device_dispatch.cmdPipelineBarrier(
                command_buffer,
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

        try device_dispatch.endCommandBuffer(command_buffer);

        const submit_command_infos = [_]vk.SubmitInfo{.{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        }};

        {
            const fence_create_info = vk.FenceCreateInfo{ .flags = .{} };
            const fence = try device_dispatch.createFence(logical_device, &fence_create_info, null);

            try device_dispatch.queueSubmit(
                graphics_present_queue,
                1,
                &submit_command_infos,
                fence,
            );

            _ = try device_dispatch.waitForFences(
                logical_device,
                1,
                @ptrCast([*]const vk.Fence, &fence),
                vk.TRUE,
                std.time.ns_per_s * 3,
            );
            device_dispatch.destroyFence(logical_device, fence, null);
            device_dispatch.freeCommandBuffers(
                logical_device,
                command_pool,
                1,
                @ptrCast([*]const vk.CommandBuffer, &command_buffer),
            );
        }
    }

    texture_image_view = try device_dispatch.createImageView(logical_device, &vk.ImageViewCreateInfo{
        .flags = .{},
        .image = texture_image,
        .view_type = .@"2d",
        .format = .r8_unorm,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    }, null);

    const vertex_buffer_create_info = vk.BufferCreateInfo{
        .size = options.vertex_buffer_capacity * @sizeOf(Vertex),
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .flags = .{},
    };
    vulkan_vertices_buffer = try device_dispatch.createBuffer(logical_device, &vertex_buffer_create_info, null);
    const vertex_memory_requirements = device_dispatch.getBufferMemoryRequirements(logical_device, vulkan_vertices_buffer);
    const vertex_buffer_memory_offset = try cpu_memory_allocator.allocate(
        vertex_memory_requirements.size,
        vertex_memory_requirements.alignment,
    );

    try device_dispatch.bindBufferMemory(
        logical_device,
        vulkan_vertices_buffer,
        cpu_memory_allocator.memory,
        vertex_buffer_memory_offset,
    );

    const index_buffer_create_info = vk.BufferCreateInfo{
        .size = options.index_buffer_capacity * @sizeOf(u16),
        .usage = .{ .index_buffer_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .flags = .{},
    };

    vulkan_indices_buffer = try device_dispatch.createBuffer(logical_device, &index_buffer_create_info, null);
    const index_memory_requirements = device_dispatch.getBufferMemoryRequirements(logical_device, vulkan_indices_buffer);
    const index_buffer_memory_offset = try cpu_memory_allocator.allocate(
        index_memory_requirements.size,
        index_memory_requirements.alignment,
    );

    try device_dispatch.bindBufferMemory(
        logical_device,
        vulkan_indices_buffer,
        cpu_memory_allocator.memory,
        index_buffer_memory_offset,
    );

    vertices_buffer = cpu_memory_allocator.toSlice(Vertex, vertex_buffer_memory_offset, options.vertex_buffer_capacity);
    indices_buffer = cpu_memory_allocator.toSlice(u16, index_buffer_memory_offset, options.index_buffer_capacity);

    vertex_shader_module = try createVertexShaderModule(device_dispatch, logical_device);
    fragment_shader_module = try createFragmentShaderModule(device_dispatch, logical_device);

    try createDescriptorSetLayouts(device_dispatch, logical_device, swapchain_image_count);
    pipeline_layout = try createPipelineLayout(device_dispatch, logical_device);
    descriptor_pool = try createDescriptorPool(device_dispatch, logical_device, swapchain_image_count);
    try createDescriptorSets(device_dispatch, logical_device, swapchain_image_count);
    try createGraphicsPipeline(
        device_dispatch,
        logical_device,
        initial_viewport_dimensions,
    );
}

pub fn deinit(allocator: std.mem.Allocator) void {
    allocator.free(descriptor_set_layouts);
    allocator.free(descriptor_sets);
}

fn createDescriptorSets(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !void {
    assert(create_count <= descriptor_set_buffer.len);

    {
        const descriptor_set_allocator_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = create_count,
            .p_set_layouts = descriptor_set_layouts.ptr,
        };
        try device_dispatch.allocateDescriptorSets(
            logical_device,
            &descriptor_set_allocator_info,
            &descriptor_set_buffer,
        );
    }

    descriptor_sets = descriptor_set_buffer[0..create_count];

    // 2. Create Sampler that will be written to DescriptorSet
    const sampler_create_info = vk.SamplerCreateInfo{
        .flags = .{},
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 16.0,
        .border_color = .int_opaque_black,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .unnormalized_coordinates = vk.TRUE,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .mipmap_mode = .nearest,
    };
    sampler = try device_dispatch.createSampler(logical_device, &sampler_create_info, null);

    // 3. Write to DescriptorSets
    var i: u32 = 0;
    while (i < create_count) : (i += 1) {
        const descriptor_image_info = [_]vk.DescriptorImageInfo{
            .{
                .image_layout = .shader_read_only_optimal,
                .image_view = texture_image_view,
                .sampler = sampler,
            },
        };
        const write_descriptor_set = [_]vk.WriteDescriptorSet{.{
            .dst_set = descriptor_sets[i],
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .p_image_info = &descriptor_image_info,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }};
        device_dispatch.updateDescriptorSets(logical_device, 1, &write_descriptor_set, 0, undefined);
    }
}

fn createPipelineLayout(device_dispatch: vulkan_config.DeviceDispatch, logical_device: vk.Device) !vk.PipelineLayout {
    const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = descriptor_set_layouts.ptr,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
        .flags = .{},
    };
    return device_dispatch.createPipelineLayout(logical_device, &pipeline_layout_create_info, null);
}

fn createGraphicsPipeline(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    screen_dimensions: geometry.Dimensions2D(u32),
) !void {
    const vertex_input_attribute_descriptions = [_]vk.VertexInputAttributeDescription{
        vk.VertexInputAttributeDescription{ // inPosition
            .binding = 0,
            .location = 0,
            .format = .r32g32b32_sfloat,
            .offset = 0,
        },
        vk.VertexInputAttributeDescription{ // inTexCoord
            .binding = 0,
            .location = 1,
            .format = .r32g32_sfloat,
            .offset = 12,
        },
        vk.VertexInputAttributeDescription{ // inColor
            .binding = 0,
            .location = 2,
            .format = .r8g8b8a8_unorm,
            .offset = 20,
        },
    };

    const vertex_shader_stage_info = vk.PipelineShaderStageCreateInfo{
        .stage = .{ .vertex_bit = true },
        .module = vertex_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
        .flags = .{},
    };

    const fragment_shader_stage_info = vk.PipelineShaderStageCreateInfo{
        .stage = .{ .fragment_bit = true },
        .module = fragment_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
        .flags = .{},
    };

    const shader_stages = [2]vk.PipelineShaderStageCreateInfo{
        vertex_shader_stage_info,
        fragment_shader_stage_info,
    };

    const vertex_input_binding_descriptions = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = @intCast(u32, 1),
        .vertex_attribute_description_count = @intCast(u32, 3),
        .p_vertex_binding_descriptions = @ptrCast([*]const vk.VertexInputBindingDescription, &vertex_input_binding_descriptions),
        .p_vertex_attribute_descriptions = @ptrCast([*]const vk.VertexInputAttributeDescription, &vertex_input_attribute_descriptions),
        .flags = .{},
    };

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
        .flags = .{},
    };

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

    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = &viewports,
        .scissor_count = 1,
        .p_scissors = &scissors,
        .flags = .{},
    };

    const rasterizer = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1.0,
        .cull_mode = .{},
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,
        .flags = .{},
    };

    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = render_pass.antialias_sample_count,
        .min_sample_shading = 0.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
        .flags = .{},
    };

    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = vk.TRUE,
        .alpha_blend_op = .add,
        .color_blend_op = .add,
        .dst_alpha_blend_factor = .one,
        .src_alpha_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .src_color_blend_factor = .src_alpha,
    };

    const blend_constants = [1]f32{0.0} ** 4;
    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &color_blend_attachment),
        .blend_constants = blend_constants,
        .flags = .{},
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state_create_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = 2,
        .p_dynamic_states = @ptrCast([*]const vk.DynamicState, &dynamic_states),
        .flags = .{},
    };

    const depth_options = vk.PipelineDepthStencilStateCreateInfo{
        .depth_test_enable = vk.TRUE,
        .depth_write_enable = vk.FALSE,
        .depth_compare_op = .less_or_equal,
        .depth_bounds_test_enable = vk.FALSE,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
        .back = undefined,
        .front = undefined,
        .stencil_test_enable = vk.FALSE,
    };

    const pipeline_create_infos = [1]vk.GraphicsPipelineCreateInfo{
        vk.GraphicsPipelineCreateInfo{
            .stage_count = 2,
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input_info,
            .p_input_assembly_state = &input_assembly,
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = &depth_options,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = &dynamic_state_create_info,
            .layout = pipeline_layout,
            .render_pass = render_pass.pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = 0,
            .flags = .{},
        },
    };

    // TODO: Check vkResult
    _ = try device_dispatch.createGraphicsPipelines(
        logical_device,
        .null_handle,
        1,
        &pipeline_create_infos,
        null,
        @ptrCast([*]vk.Pipeline, &graphics_pipeline),
    );
}

fn createDescriptorSetLayouts(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !void {
    assert(descriptor_set_layout_buffer.len >= create_count);

    {
        const descriptor_set_layout_bindings = [_]vk.DescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_immutable_samplers = null,
            .stage_flags = .{ .fragment_bit = true },
        }};
        const descriptor_set_layout_create_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = 1,
            .p_bindings = &descriptor_set_layout_bindings,
            .flags = .{},
        };
        descriptor_set_layout_buffer[0] = try device_dispatch.createDescriptorSetLayout(
            logical_device,
            &descriptor_set_layout_create_info,
            null,
        );

        // We can copy the same descriptor set layout for each swapchain image
        var x: u32 = 1;
        while (x < create_count) : (x += 1) {
            descriptor_set_layout_buffer[x] = descriptor_set_layout_buffer[0];
        }

        descriptor_set_layouts = descriptor_set_layout_buffer[0..create_count];
    }
}

fn createFragmentShaderModule(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.icon_fragment_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.icon_fragment_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}

fn createVertexShaderModule(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.icon_vertex_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.icon_vertex_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}

fn createDescriptorPool(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !vk.DescriptorPool {
    const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = .sampler,
            .descriptor_count = create_count,
        },
        .{
            .type = .sampled_image,
            .descriptor_count = create_count,
        },
    };
    const create_pool_info = vk.DescriptorPoolCreateInfo{
        .pool_size_count = descriptor_pool_sizes.len,
        .p_pool_sizes = &descriptor_pool_sizes,
        .max_sets = create_count,
        .flags = .{},
    };
    return try device_dispatch.createDescriptorPool(logical_device, &create_pool_info, null);
}