// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const vulkan_config = @import("vulkan_config.zig");
const shaders = @import("shaders");

const root = @import("../vulkan_renderer.zig");

const vulkan_core = @import("vulkan_core.zig");
const render_pass = @import("render_pass.zig");
const defines = @import("defines.zig");
const VulkanAllocator = @import("../VulkanBumpAllocator.zig");

const geometry = @import("../geometry.zig");
const graphics = @import("../graphics.zig");

pub const PushConstant = packed struct {
    width: f32,
    height: f32,
    frame: f32,
};

pub var texture_image: vk.Image = undefined;
pub var descriptor_sets: []vk.DescriptorSet = undefined;
pub var descriptor_set_layouts: []vk.DescriptorSetLayout = undefined;
pub var pipeline_layout: vk.PipelineLayout = undefined;
pub var graphics_pipeline: vk.Pipeline = undefined;
pub var vertices_buffer: []graphics.GenericVertex = undefined;
pub var indices_buffer: []u16 = undefined;
pub var vulkan_vertices_buffer: vk.Buffer = undefined;
pub var vulkan_indices_buffer: vk.Buffer = undefined;

var texture_image_view: vk.ImageView = undefined;
var alpha_mode: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true };
var vertex_shader_module: vk.ShaderModule = undefined;
var fragment_shader_module: vk.ShaderModule = undefined;
var descriptor_pool: vk.DescriptorPool = undefined;
var sampler: vk.Sampler = undefined;

pub fn init(
    allocator: std.mem.Allocator,
    graphics_present_queue: vk.Queue,
    swapchain_image_count: u32,
    vulkan_allocator: *VulkanAllocator,
    static_texture: root.Texture,
) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const command_pool = vulkan_core.command_pool;

    const initial_viewport_dimensions = defines.initial_screen_dimensions;

    //
    // Create staging buffer for static texture
    //

    const staging_buffer_size = static_texture.pixelCount() * @sizeOf(graphics.RGBA(f32));
    const staging_buffer_create_info = vk.BufferCreateInfo{
        .size = staging_buffer_size,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .flags = .{},
    };
    const staging_buffer = try device_dispatch.createBuffer(logical_device, &staging_buffer_create_info, null);
    const staging_memory_requirements = device_dispatch.getBufferMemoryRequirements(logical_device, staging_buffer);
    const staging_memory = try device_dispatch.allocateMemory(logical_device, &vk.MemoryAllocateInfo{
        .allocation_size = staging_memory_requirements.size,
        .memory_type_index = vulkan_allocator.memory_index,
    }, null);
    try device_dispatch.bindBufferMemory(
        logical_device,
        staging_buffer,
        staging_memory,
        0,
    );

    var staging_buffer_memory_map = @ptrCast([*]u8, (try device_dispatch.mapMemory(logical_device, staging_memory, 0, staging_memory_requirements.size, .{})).?);
    @memcpy(
        staging_buffer_memory_map[0..staging_buffer_size],
        @ptrCast([*]u8, static_texture.pixels)[0..staging_buffer_size],
    );

    {
        const image_create_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r32g32b32a32_sfloat,
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
    const texture_memory_offset = try vulkan_allocator.allocate(
        texture_memory_requirements.size,
        texture_memory_requirements.alignment,
    );
    try device_dispatch.bindImageMemory(logical_device, texture_image, vulkan_allocator.memory, texture_memory_offset);

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
        .view_type = .@"2d_array",
        .format = .r32g32b32a32_sfloat,
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
        .size = defines.memory.pipeline_generic.vertices_range_size,
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        // NOTE: Only valid when `sharing_mode` is CONCURRENT
        // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/VkBufferCreateInfo.html
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .flags = .{},
    };
    vulkan_vertices_buffer = try device_dispatch.createBuffer(logical_device, &vertex_buffer_create_info, null);
    const vertex_memory_requirements = device_dispatch.getBufferMemoryRequirements(logical_device, vulkan_vertices_buffer);
    const vertex_buffer_memory_offset = try vulkan_allocator.allocate(
        vertex_memory_requirements.size,
        vertex_memory_requirements.alignment,
    );

    try device_dispatch.bindBufferMemory(
        logical_device,
        vulkan_vertices_buffer,
        vulkan_allocator.memory,
        vertex_buffer_memory_offset,
    );

    const index_buffer_create_info = vk.BufferCreateInfo{
        .size = defines.memory.pipeline_generic.indices_range_size,
        .usage = .{ .transfer_dst_bit = true, .index_buffer_bit = true },
        .sharing_mode = .exclusive,
        // NOTE: Only valid when `sharing_mode` is CONCURRENT
        // https://www.khronos.org/registry/vulkan/specs/1.3-extensions/man/html/VkBufferCreateInfo.html
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .flags = .{},
    };

    vulkan_indices_buffer = try device_dispatch.createBuffer(logical_device, &index_buffer_create_info, null);
    const index_memory_requirements = device_dispatch.getBufferMemoryRequirements(logical_device, vulkan_indices_buffer);
    const index_buffer_memory_offset = try vulkan_allocator.allocate(
        index_memory_requirements.size,
        index_memory_requirements.alignment,
    );

    try device_dispatch.bindBufferMemory(
        logical_device,
        vulkan_indices_buffer,
        vulkan_allocator.memory,
        index_buffer_memory_offset,
    );

    {
        const Vertex = graphics.GenericVertex;
        const vertex_ptr = @ptrCast([*]Vertex, @alignCast(@alignOf(Vertex), &vulkan_allocator.mapped_memory[vertex_buffer_memory_offset]));
        vertices_buffer = vertex_ptr[0..defines.memory.pipeline_generic.vertices_range_count];
        const indices_ptr = @ptrCast([*]u16, @alignCast(16, &vulkan_allocator.mapped_memory[index_buffer_memory_offset]));
        indices_buffer = indices_ptr[0..defines.memory.pipeline_generic.indices_range_count];
    }

    vertex_shader_module = try createVertexShaderModule(device_dispatch, logical_device);
    fragment_shader_module = try createFragmentShaderModule(device_dispatch, logical_device);

    try createDescriptorSetLayouts(allocator, device_dispatch, logical_device, swapchain_image_count);
    pipeline_layout = try createPipelineLayout(device_dispatch, logical_device);
    descriptor_pool = try createDescriptorPool(device_dispatch, logical_device, swapchain_image_count);
    try createDescriptorSets(allocator, device_dispatch, logical_device, swapchain_image_count);
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
    allocator: std.mem.Allocator,
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !void {

    // 1. Allocate DescriptorSets from DescriptorPool
    descriptor_sets = try allocator.alloc(vk.DescriptorSet, create_count);
    {
        const descriptor_set_allocator_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = create_count,
            .p_set_layouts = descriptor_set_layouts.ptr,
        };
        try device_dispatch.allocateDescriptorSets(logical_device, &descriptor_set_allocator_info, @ptrCast(
            [*]vk.DescriptorSet,
            descriptor_sets.ptr,
        ));
    }

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
        .unnormalized_coordinates = vk.FALSE,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .mipmap_mode = .linear,
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
    const push_constant = vk.PushConstantRange{
        .stage_flags = .{ .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf(PushConstant),
    };
    const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = descriptor_set_layouts.ptr,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast([*]const vk.PushConstantRange, &push_constant),
        .flags = .{},
    };
    return device_dispatch.createPipelineLayout(logical_device, &pipeline_layout_create_info, null);
}

fn createGraphicsPipeline(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    screen_dimensions: geometry.Dimensions2D(u16),
) !void {
    const vertex_input_attribute_descriptions = [_]vk.VertexInputAttributeDescription{
        vk.VertexInputAttributeDescription{ // inPosition
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = 0,
        },
        vk.VertexInputAttributeDescription{ // inTexCoord
            .binding = 0,
            .location = 1,
            .format = .r32g32_sfloat,
            .offset = 8,
        },
        vk.VertexInputAttributeDescription{ // inColor
            .binding = 0,
            .location = 2,
            .format = .r32g32b32a32_sfloat,
            .offset = 16,
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
        .stride = @sizeOf(graphics.GenericVertex),
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
            .p_depth_stencil_state = null,
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
    allocator: std.mem.Allocator,
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !void {
    descriptor_set_layouts = try allocator.alloc(vk.DescriptorSetLayout, create_count);
    {
        const descriptor_set_layout_bindings = [_]vk.DescriptorSetLayoutBinding{vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_immutable_samplers = null,
            .stage_flags = .{ .fragment_bit = true },
        }};
        const descriptor_set_layout_create_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = 1,
            .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &descriptor_set_layout_bindings[0]),
            .flags = .{},
        };
        descriptor_set_layouts[0] = try device_dispatch.createDescriptorSetLayout(
            logical_device,
            &descriptor_set_layout_create_info,
            null,
        );

        // We can copy the same descriptor set layout for each swapchain image
        var x: u32 = 1;
        while (x < descriptor_set_layouts.len) : (x += 1) {
            descriptor_set_layouts[x] = descriptor_set_layouts[0];
        }
    }
}

fn createFragmentShaderModule(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.fragment_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.fragment_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}

fn createVertexShaderModule(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.vertex_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.vertex_spv)),
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
