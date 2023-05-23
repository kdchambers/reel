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
const ui_layer = geometry.ui_layer;
const graphics = @import("../graphics.zig");

const Coordinates2D = geometry.Coordinates2D;
const Coordinates3D = geometry.Coordinates3D;
const Extent2D = geometry.Extent2D;
const Extent3D = geometry.Extent3D;
const Dimensions2D = geometry.Dimensions2D;
const Radius2D = geometry.Radius2D;
const RGBA = graphics.RGBA;

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32 = ui_layer.middle,
    color: RGBA(u8) = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
};

comptime {
    assert(@sizeOf(Vertex) == 16);
    assert(@alignOf(Vertex) == 4);
}

var graphics_pipeline: vk.Pipeline = undefined;
var vertices_buffer: []Vertex = undefined;
var indices_buffer: []u16 = undefined;
var vulkan_vertices_buffer: vk.Buffer = undefined;
var vulkan_indices_buffer: vk.Buffer = undefined;

var pipeline_layout: vk.PipelineLayout = undefined;

var vertex_shader_module: vk.ShaderModule = undefined;
var fragment_shader_module: vk.ShaderModule = undefined;

var vertices_used: u16 = 0;
var indices_used: u16 = 0;

pub fn resetVertexBuffer() void {
    vertices_used = 0;
    indices_used = 0;
}

pub inline fn nextVertexIndex() u16 {
    return vertices_used;
}

pub inline fn quad(vertex_index: u32) *[4]Vertex {
    return @ptrCast(*[4]Vertex, &vertices_buffer[vertex_index]);
}

pub inline fn quadSlice(vertex_index: u32, count: u32) [][4]Vertex {
    return @ptrCast([*][4]Vertex, &vertices_buffer[vertex_index])[0..count];
}

pub inline fn vertexSlice(vertex_index: u32, count: u32) []Vertex {
    return vertices_buffer[vertex_index .. vertex_index + count];
}

pub inline fn updateQuadColor(vertex_index: u32, color: RGBA(u8)) void {
    const quad_ptr = @ptrCast(*[4]Vertex, &vertices_buffer[vertex_index]);
    quad_ptr[0].color = color;
    quad_ptr[1].color = color;
    quad_ptr[2].color = color;
    quad_ptr[3].color = color;
}

pub inline fn updateQuadRangeColor(vertex_index: u32, quad_count: u16, color: RGBA(u8)) void {
    const quads = @ptrCast([*][4]Vertex, &vertices_buffer[vertex_index])[0..quad_count];
    for (quads) |*quad_ptr| {
        quad_ptr.*[0].color = color;
        quad_ptr.*[1].color = color;
        quad_ptr.*[2].color = color;
        quad_ptr.*[3].color = color;
    }
}

pub inline fn drawQuad(extent: Extent3D(f32), color: RGBA(u8), comptime anchor_point: graphics.AnchorPoint) u16 {
    const vertex_index = vertices_used;
    var quad_ptr = @ptrCast(*[4]Vertex, &vertices_buffer[vertices_used]);
    graphics.writeQuad(Vertex, extent, anchor_point, quad_ptr);
    quad_ptr[0].color = color;
    quad_ptr[1].color = color;
    quad_ptr[2].color = color;
    quad_ptr[3].color = color;
    writeQuadIndices(vertices_used);
    vertices_used += 4;
    return vertex_index;
}

pub inline fn overwriteQuad(
    vertex_index: u16,
    extent: Extent3D(f32),
    color: RGBA(u8),
    comptime anchor_point: graphics.AnchorPoint,
) void {
    var quad_ptr = @ptrCast(*[4]Vertex, &vertices_buffer[vertex_index]);
    graphics.writeQuad(Vertex, extent, anchor_point, quad_ptr);
    quad_ptr[0].color = color;
    quad_ptr[1].color = color;
    quad_ptr[2].color = color;
    quad_ptr[3].color = color;
}

pub const VertexRange = packed struct(u32) {
    start: u16,
    count: u16,
};

pub inline fn drawRoundedRect(
    extent: Extent3D(f32),
    color: RGBA(u8),
    comptime anchor_point: graphics.AnchorPoint,
    radius: Radius2D(f32),
    points_per_arc: u16,
) VertexRange {
    const start_vertex_index: u16 = vertices_used;

    assert(points_per_arc >= 8);

    //
    // TODO: Implement
    //
    _ = anchor_point;

    const middle_extent = Extent3D(f32){
        .x = extent.x,
        .y = extent.y - radius.v,
        .z = extent.z,
        .width = extent.width,
        .height = extent.height - (radius.v * 2.0),
    };
    const top_extent = Extent3D(f32){
        .x = extent.x + radius.h,
        .y = extent.y - extent.height + radius.v,
        .z = extent.z,
        .width = extent.width - (radius.h * 2.0),
        .height = radius.v,
    };
    const bottom_extent = Extent3D(f32){
        .x = extent.x + radius.h,
        .y = extent.y,
        .z = extent.z,
        .width = extent.width - (radius.h * 2.0),
        .height = radius.v,
    };

    _ = drawQuad(middle_extent, color, .bottom_left);
    _ = drawQuad(top_extent, color, .bottom_left);
    _ = drawQuad(bottom_extent, color, .bottom_left);

    {
        //
        // Top Left
        //
        const arc_center = Coordinates3D(f32){
            .x = extent.x + radius.h,
            .y = extent.y - (extent.height - radius.v),
            .z = extent.z,
        };
        _ = drawArc(arc_center, radius, color, 180, 90, points_per_arc);
    }

    {
        //
        // Bottom Left
        //
        const arc_center = Coordinates3D(f32){
            .x = extent.x + radius.h,
            .y = extent.y - radius.v,
            .z = extent.z,
        };
        _ = drawArc(arc_center, radius, color, 90, 90, points_per_arc);
    }

    {
        //
        // Top Right
        //
        const arc_center = Coordinates3D(f32){
            .x = extent.x + extent.width - radius.h,
            .y = extent.y - (extent.height - radius.v),
            .z = extent.z,
        };
        _ = drawArc(arc_center, radius, color, 270, 90, points_per_arc);
    }

    {
        //
        // Bottom Right
        //
        const arc_center = Coordinates3D(f32){
            .x = extent.x + extent.width - radius.h,
            .y = extent.y - radius.v,
            .z = extent.z,
        };
        _ = drawArc(arc_center, radius, color, 0, 90, points_per_arc);
    }

    assert(vertices_used > start_vertex_index);
    return .{
        .start = start_vertex_index,
        .count = vertices_used - start_vertex_index,
    };
}

pub inline fn drawTriangle(
    p0: Coordinates2D(f32),
    p1: Coordinates2D(f32),
    p2: Coordinates2D(f32),
    depth: f32,
    color: RGBA(u8),
) u32 {
    const vertex_index = vertices_used;
    var tri_ptr = @ptrCast(*[3]Vertex, &vertices_buffer[vertices_used]);
    tri_ptr[0].x = p0.x;
    tri_ptr[0].y = p0.x;
    tri_ptr[0].z = depth;
    tri_ptr[1].x = p1.x;
    tri_ptr[1].y = p1.x;
    tri_ptr[1].z = depth;
    tri_ptr[2].x = p2.x;
    tri_ptr[2].y = p2.x;
    tri_ptr[2].z = depth;
    tri_ptr[0].color = color;
    tri_ptr[1].color = color;
    tri_ptr[2].color = color;
    indices_buffer[indices_used + 0] = vertices_used + 0; // Top left
    indices_buffer[indices_used + 1] = vertices_used + 1; // Top right
    indices_buffer[indices_used + 2] = vertices_used + 2; // Bottom right
    indices_used += 3;
    vertices_used += 3;
    return vertex_index;
}

pub inline fn drawCircle(
    center: Coordinates3D(f32),
    radius: Radius2D(f32),
    color: RGBA(u8),
    point_count: u16,
) VertexRange {
    return drawArc(center, radius, color, 0, 360, point_count);
}

pub fn drawArc(
    center: Coordinates3D(f32),
    radius: Radius2D(f32),
    color: RGBA(u8),
    rotation_begin: f32,
    rotation_length: f32,
    point_count: u16,
) VertexRange {
    assert(point_count >= 8);

    const arc_vertices = VertexRange{ .start = vertices_used, .count = point_count + 1 };
    const degreesToRadians = std.math.degreesToRadians;

    const base_rotation = degreesToRadians(f32, rotation_begin);
    const rotation_per_point = degreesToRadians(f32, rotation_length / @intToFloat(f32, point_count - 1));

    var vertices = vertices_buffer[vertices_used .. vertices_used + point_count + 1];

    vertices[0] = Vertex{
        .x = center.x,
        .y = center.y,
        .z = center.z,
        .color = color,
    };

    vertices[1] = Vertex{
        .x = @floatCast(f32, center.x + (radius.h * @cos(base_rotation))),
        .y = @floatCast(f32, center.y + (radius.v * @sin(base_rotation))),
        .z = center.z,
        .color = color,
    };

    var i: u16 = 1;
    while (i < point_count) : (i += 1) {
        const angle_radians: f64 = base_rotation + (rotation_per_point * @intToFloat(f32, i));
        vertices[i + 1] = Vertex{
            .x = @floatCast(f32, center.x + (radius.h * @cos(angle_radians))),
            .y = @floatCast(f32, center.y + (radius.v * @sin(angle_radians))),
            .z = center.z,
            .color = color,
        };

        indices_buffer[indices_used + 0] = vertices_used; // Center
        indices_buffer[indices_used + 1] = vertices_used + i + 0; // Previous
        indices_buffer[indices_used + 2] = vertices_used + i + 1; // Current
        indices_used += 3;
    }
    vertices_used += point_count + 1;

    return arc_vertices;
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

const InitOptions = struct {
    vertex_buffer_capacity: u32,
    index_buffer_capacity: u32,
    viewport_dimensions: geometry.Dimensions2D(u32),
};

pub fn recordDrawCommands(command_buffer: vk.CommandBuffer, i: usize, screen_dimensions: Dimensions2D(u32)) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    _ = i;

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
    device_dispatch.cmdDrawIndexed(command_buffer, indices_used, 1, 0, 0, 0);
}

pub fn init(options: InitOptions, cpu_memory_allocator: *VulkanAllocator) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    const initial_viewport_dimensions = options.viewport_dimensions;

    {
        const buffer_create_info = vk.BufferCreateInfo{
            .size = options.vertex_buffer_capacity * @sizeOf(Vertex),
            .usage = .{ .vertex_buffer_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .flags = .{},
        };
        vulkan_vertices_buffer = try device_dispatch.createBuffer(logical_device, &buffer_create_info, null);

        const memory_requirements = device_dispatch.getBufferMemoryRequirements(logical_device, vulkan_vertices_buffer);
        const buffer_memory_offset = try cpu_memory_allocator.allocate(
            memory_requirements.size,
            memory_requirements.alignment,
        );

        try device_dispatch.bindBufferMemory(
            logical_device,
            vulkan_vertices_buffer,
            cpu_memory_allocator.memory,
            buffer_memory_offset,
        );

        vertices_buffer = cpu_memory_allocator.toSlice(Vertex, buffer_memory_offset, options.vertex_buffer_capacity);
    }

    {
        const buffer_create_info = vk.BufferCreateInfo{
            .size = options.index_buffer_capacity * @sizeOf(u16),
            .usage = .{ .index_buffer_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .flags = .{},
        };
        vulkan_indices_buffer = try device_dispatch.createBuffer(logical_device, &buffer_create_info, null);

        const memory_requirements = device_dispatch.getBufferMemoryRequirements(logical_device, vulkan_indices_buffer);
        const buffer_memory_offset = try cpu_memory_allocator.allocate(
            memory_requirements.size,
            memory_requirements.alignment,
        );

        try device_dispatch.bindBufferMemory(
            logical_device,
            vulkan_indices_buffer,
            cpu_memory_allocator.memory,
            buffer_memory_offset,
        );

        indices_buffer = cpu_memory_allocator.toSlice(u16, buffer_memory_offset, options.index_buffer_capacity);
    }

    vertex_shader_module = try createVertexShaderModule(device_dispatch, logical_device);
    fragment_shader_module = try createFragmentShaderModule(device_dispatch, logical_device);

    try createGraphicsPipeline(
        device_dispatch,
        logical_device,
        initial_viewport_dimensions,
    );
}

pub fn deinit() void {
    //
}

fn createGraphicsPipeline(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    screen_dimensions: geometry.Dimensions2D(u32),
) !void {
    const vertex_input_attribute_descriptions = [_]vk.VertexInputAttributeDescription{
        .{ // inPosition
            .binding = 0,
            .location = 0,
            .format = .r32g32b32_sfloat,
            .offset = 0,
        },
        .{ // inColor
            .binding = 0,
            .location = 1,
            .format = .r8g8b8a8_unorm,
            .offset = 12,
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
        .vertex_attribute_description_count = vertex_input_attribute_descriptions.len,
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

    const color_blend_attachment = [1]vk.PipelineColorBlendAttachmentState{.{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = vk.TRUE,
        .alpha_blend_op = .add,
        .color_blend_op = .add,
        .dst_alpha_blend_factor = .one,
        .src_alpha_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .src_color_blend_factor = .src_alpha,
    }};

    const blend_constants = [1]f32{0.0} ** 4;
    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = color_blend_attachment.len,
        .p_attachments = &color_blend_attachment,
        .blend_constants = blend_constants,
        .flags = .{},
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state_create_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
        .flags = .{},
    };

    const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
        .flags = .{},
    };
    pipeline_layout = try device_dispatch.createPipelineLayout(logical_device, &pipeline_layout_create_info, null);

    const depth_options = vk.PipelineDepthStencilStateCreateInfo{
        .depth_test_enable = vk.TRUE,
        .depth_write_enable = vk.TRUE,
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

fn createFragmentShaderModule(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.color_fragment_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.color_fragment_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}

fn createVertexShaderModule(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.color_vertex_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.color_vertex_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}
