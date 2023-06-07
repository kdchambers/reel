// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const vk = @import("vulkan");
const VulkanAllocator = @import("../VulkanBumpAllocator.zig");

const vulkan_core = @import("vulkan_core.zig");
const vulkan_config = @import("vulkan_config.zig");
const shaders = @import("shaders");

const geometry = @import("../geometry.zig");
const Extent3D = geometry.Extent3D;
const Extent2D = geometry.Extent2D;
const ScaleFactor2D = geometry.ScaleFactor2D;
const Dimensions2D = geometry.Dimensions2D;
const Coordinates2D = geometry.Coordinates2D;
const Coordinates3D = geometry.Coordinates3D;
const AnchorPoint = geometry.AnchorPoint;

const graphics = @import("../graphics.zig");
const RGBA = graphics.RGBA;

const utils = @import("../utils.zig");
const Timer = utils.Timer;

const shared_render_pass = @import("render_pass.zig");

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    u: f32,
    v: f32,
};

var descriptor_set_layout_buffer: [8]vk.DescriptorSetLayout = undefined;
var descriptor_set_buffer: [8]vk.DescriptorSet = undefined;
var descriptor_pool: vk.DescriptorPool = undefined;

var descriptor_count: u32 = 0;

var command_pool: vk.CommandPool = undefined;

var sampler: vk.Sampler = undefined;

var pipeline_layout: vk.PipelineLayout = undefined;
var graphics_pipeline: vk.Pipeline = undefined;

var vertex_shader_module: vk.ShaderModule = undefined;
var fragment_shader_module: vk.ShaderModule = undefined;

var vertices_buffer: []Vertex = undefined;
var indices_buffer: []u16 = undefined;
var vulkan_vertices_buffer: vk.Buffer = undefined;
var vulkan_indices_buffer: vk.Buffer = undefined;

const quad_capacity = 16;
const vertex_buffer_capacity = quad_capacity * 4;
const index_buffer_capacity = quad_capacity * 6;

const max_stream_count = 8;
const max_draw_count = 16;

var draw_quad_count: u32 = 0;
var source_count: u32 = 0;
var stream_count: u32 = 0;
var stream_buffer: [max_stream_count]Stream = undefined;

var cpu_memory_index: u32 = std.math.maxInt(u32);

const DrawContext = struct {
    relative_extent: Extent2D(f32),
    stream_handle: u32,
};

var draw_context_buffer: [max_draw_count]DrawContext = undefined;

var canvas_memory: vk.DeviceMemory = undefined;
var canvas_image: vk.Image = undefined;
var canvas_image_view: vk.ImageView = undefined;
var canvas_mapped_memory: []RGBA(u8) = undefined;
var canvas_dimensions: Dimensions2D(f32) = .{ .width = 0, .height = 0 };

var unscaled_canvas_dimensions: Dimensions2D(u32) = .{ .width = 1920, .height = 1080 };
var unscaled_canvas_memory: vk.DeviceMemory = undefined;
var unscaled_canvas_image: vk.Image = undefined;
var unscaled_canvas_image_view: vk.ImageView = undefined;
var unscaled_canvas_mapped_memory: []RGBA(u8) = undefined;

var scale_method: vk.Filter = .nearest;

const DrawHandle = u32;

// Binds stream handles to `stream_buffer` entries
// E.G: stream_handle_buffer[0] = 55 (handle 55 corresponds to `stream_buffer[0]`)
var stream_handle_buffer = [1]u32{std.math.maxInt(u32)} ** max_stream_count;

var draw_handle_buffer = [1]DrawHandle{std.math.maxInt(DrawHandle)} ** max_draw_count;

const Stream = struct {
    dimensions: Dimensions2D(f32),
    mapped_memory: []u8,
    memory: vk.DeviceMemory,
    image: vk.Image,
    format: vk.Format,
};

pub const SupportedImageFormat = enum {
    rgba,
    bgrx,
};

pub fn resetVertexBuffer() void {
    draw_quad_count = 0;
}

pub inline fn unscaledFrame() []RGBA(u8) {
    const pixel_count = unscaled_canvas_dimensions.width * unscaled_canvas_dimensions.height;
    return unscaled_canvas_mapped_memory[0..pixel_count];
}

pub inline fn writeStreamFrame(stream_handle: u32, pixels: []const u8) !void {
    const stream_index = streamIndexFromHandle(stream_handle);
    assert(stream_count > stream_index);
    const stream_ptr: *Stream = &stream_buffer[stream_index];
    assert(stream_ptr.mapped_memory.len > 0);
    assert(stream_ptr.mapped_memory.len == pixels.len);
    @memcpy(stream_ptr.mapped_memory, pixels);
}

pub inline fn drawVideoFrame(extent: Extent3D(f32)) void {
    const full_texture_extent: Extent2D(f32) = .{ .x = 0.0, .y = 0.0, .width = 1.0, .height = 1.0 };
    const vertex_index: usize = draw_quad_count * 4;
    graphics.writeQuadTextured(Vertex, extent, full_texture_extent, .bottom_left, @ptrCast(*[4]Vertex, &vertices_buffer[vertex_index]));
    draw_quad_count += 1;
}

pub inline fn addVideoSource(stream_handle: u32, relative_extent: Extent2D(f32)) DrawHandle {
    const stream_index = streamIndexFromHandle(stream_handle);
    assert(stream_count > stream_index);
    assert(source_count < max_draw_count);

    assert(relative_extent.x >= 0.0);
    assert(relative_extent.x <= 1.0);
    assert(relative_extent.y >= 0.0);
    assert(relative_extent.y <= 1.0);
    assert(relative_extent.width >= 0.0);
    assert(relative_extent.width <= 1.0);
    assert(relative_extent.height >= 0.0);
    assert(relative_extent.height <= 1.0);
    assert(relative_extent.width + relative_extent.x <= 1.0);
    assert(relative_extent.height + relative_extent.y <= 1.0);

    const draw_handle = assignNewDrawHandle();
    var draw_context_ptr = drawContextFromHandle(draw_handle);
    draw_context_ptr.* = .{
        .relative_extent = relative_extent,
        .stream_handle = stream_handle,
    };
    return draw_handle;
}

var source_extent_buffer: [8]Extent3D(f32) = undefined;

pub fn videoSourceExtents(screen_scale: ScaleFactor2D(f32)) []Extent3D(f32) {
    var z_level: f32 = 0.0;
    const z_increment: f32 = 0.01;
    for (draw_context_buffer[0..source_count], 0..) |draw_context, i| {
        std.log.info("Source dimensions: {d} x {d}", .{ draw_context.relative_extent.width, draw_context.relative_extent.height });
        source_extent_buffer[i] = .{
            .x = draw_context.relative_extent.x * canvas_dimensions.width * screen_scale.horizontal,
            .y = draw_context.relative_extent.y * canvas_dimensions.height * screen_scale.vertical,
            .z = z_level,
            .width = draw_context.relative_extent.width * canvas_dimensions.width * screen_scale.horizontal,
            .height = draw_context.relative_extent.height * canvas_dimensions.height * screen_scale.vertical,
        };
        z_level += z_increment;
    }
    return source_extent_buffer[0..source_count];
}

pub fn sourceRelativePlacement(source_index: u16) Coordinates2D(u16) {
    return .{
        .x = @floatToInt(u16, draw_context_buffer[source_index].relative_extent.x * canvas_dimensions.width),
        .y = @floatToInt(u16, draw_context_buffer[source_index].relative_extent.y * canvas_dimensions.height),
    };
}

pub fn sourceRelativeExtent(source_index: u16) Extent2D(u16) {
    return .{
        .x = @floatToInt(u16, draw_context_buffer[source_index].relative_extent.x * canvas_dimensions.width),
        .y = @floatToInt(u16, draw_context_buffer[source_index].relative_extent.y * canvas_dimensions.height),
        .width = @floatToInt(u16, draw_context_buffer[source_index].relative_extent.width * canvas_dimensions.width),
        .height = @floatToInt(u16, draw_context_buffer[source_index].relative_extent.height * canvas_dimensions.height),
    };
}

pub fn moveSource(source_index: u16, placement: Coordinates2D(u16)) void {
    const relative_extent_ptr: *Extent2D(f32) = &draw_context_buffer[source_index].relative_extent;
    const max_x: f32 = 1.0 - relative_extent_ptr.width;
    const max_y: f32 = 1.0 - relative_extent_ptr.height;
    relative_extent_ptr.x = @max(0.0, @min(max_x, @intToFloat(f32, placement.x) / canvas_dimensions.width));
    relative_extent_ptr.y = @max(0.0, @min(max_y, @intToFloat(f32, placement.y) / canvas_dimensions.height));
    assert(relative_extent_ptr.x >= 0.0);
    assert(relative_extent_ptr.x <= 1.0);
    assert(relative_extent_ptr.y >= 0.0);
    assert(relative_extent_ptr.y <= 1.0);
    assert(relative_extent_ptr.width >= 0.0);
    assert(relative_extent_ptr.width <= 1.0);
    assert(relative_extent_ptr.height >= 0.0);
    assert(relative_extent_ptr.height <= 1.0);
    assert(relative_extent_ptr.x + relative_extent_ptr.width <= 1.0);
    assert(relative_extent_ptr.y + relative_extent_ptr.height <= 1.0);
}

pub inline fn moveEdgeLeft(source_index: u16, value: f32) void {
    if (value < 0.0)
        return;
    if (value > canvas_dimensions.width)
        return;
    const new_x: f32 = value / canvas_dimensions.width;
    const old_x: f32 = draw_context_buffer[source_index].relative_extent.x;
    const end_x: f32 = old_x + draw_context_buffer[source_index].relative_extent.width;
    draw_context_buffer[source_index].relative_extent.width = end_x - new_x;
    draw_context_buffer[source_index].relative_extent.x = new_x;
    assert(new_x >= 0.0);
    assert(new_x <= 1.0);
}

pub inline fn moveEdgeRight(source_index: u16, value: f32) void {
    if (value < 0)
        return;
    if (value > canvas_dimensions.width)
        return;
    const new_end_x: f32 = value / canvas_dimensions.width;
    const new_width: f32 = new_end_x - draw_context_buffer[source_index].relative_extent.x;
    draw_context_buffer[source_index].relative_extent.width = new_width;
    assert(new_width >= 0.0);
    assert(new_width <= 1.0);
}

pub inline fn moveEdgeTop(source_index: u16, value: f32) void {
    if (value < 0)
        return;
    if (value > canvas_dimensions.height)
        return;
    const new_height: f32 = value / canvas_dimensions.height;
    draw_context_buffer[source_index].relative_extent.height = new_height;
    assert(new_height >= 0.0);
    assert(new_height <= 1.0);
}

pub inline fn moveEdgeBottom(source_index: u16, value: f32) void {
    if (value < 0.0)
        return;
    if (value > canvas_dimensions.height)
        return;
    const new_y: f32 = value / canvas_dimensions.height;
    const old_y: f32 = draw_context_buffer[source_index].relative_extent.y;
    const end_y: f32 = old_y + draw_context_buffer[source_index].relative_extent.height;
    const new_height: f32 = end_y - new_y;
    draw_context_buffer[source_index].relative_extent.height = new_height;
    draw_context_buffer[source_index].relative_extent.y = new_y;
    assert(new_y >= 0.0);
    assert(new_y <= 1.0);
    assert(new_height >= 0.0);
    assert(new_height <= 1.0);
    assert(new_y + new_height >= 0.0);
    assert(new_y + new_height <= 1.0);
}

pub inline fn assignNewDrawHandle() DrawHandle {
    const next_free_handle: DrawHandle = source_count;
    for (&draw_handle_buffer) |*mapped_buffer_index| {
        if (mapped_buffer_index.* == std.math.maxInt(DrawHandle)) {
            mapped_buffer_index.* = next_free_handle;
            source_count += 1;
            return next_free_handle;
        }
    }
    unreachable;
}

pub inline fn drawContextFromHandle(draw_handle: DrawHandle) *DrawContext {
    for (draw_handle_buffer, 0..) |mapped_buffer_index, i| {
        if (mapped_buffer_index == draw_handle)
            return &draw_context_buffer[i];
    }
    unreachable;
}

pub inline fn drawContextIndexFromHandle(draw_handle: DrawHandle) usize {
    for (draw_handle_buffer, 0..) |mapped_buffer_index, i| {
        if (mapped_buffer_index == draw_handle)
            return i;
    }
    unreachable;
}

pub inline fn assignNewStreamHandle() u32 {
    const next_free_handle: u32 = stream_count;
    for (&stream_handle_buffer) |*mapped_buffer_index| {
        if (mapped_buffer_index.* == std.math.maxInt(u32)) {
            mapped_buffer_index.* = next_free_handle;
            stream_count += 1;
            return next_free_handle;
        }
    }
    unreachable;
}

pub inline fn streamFromHandle(stream_handle: u32) *Stream {
    for (stream_handle_buffer, 0..) |mapped_buffer_index, i| {
        if (mapped_buffer_index == stream_handle)
            return &stream_buffer[i];
    }
    unreachable;
}

pub inline fn streamIndexFromHandle(stream_handle: u32) usize {
    for (stream_handle_buffer, 0..) |mapped_buffer_index, i| {
        if (mapped_buffer_index == stream_handle)
            return i;
    }
    unreachable;
}

pub fn removeStream(stream_handle: u32) void {
    assert(pending_remove_stream_handle == null);
    pending_remove_stream_handle = stream_handle;
}

fn destroyStream(stream_handle: u32) void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;
    const stream_ptr = streamFromHandle(stream_handle);
    for (&stream_handle_buffer) |*mapped_buffer_index| {
        if (mapped_buffer_index.* == stream_handle) {
            mapped_buffer_index.* = std.math.maxInt(u32);
            break;
        }
    }
    device_dispatch.destroyImage(logical_device, stream_ptr.image, null);
    device_dispatch.unmapMemory(logical_device, stream_ptr.memory);
    device_dispatch.freeMemory(logical_device, stream_ptr.memory, null);

    //
    // Remove all draw commands for this stream
    //
    var draw_index_signed: i32 = @intCast(i32, source_count);
    while (draw_index_signed >= 0) : (draw_index_signed -= 1) {
        const draw_index = @intCast(usize, draw_index_signed);
        //
        // This draw command references the stream_handle we are deleting.
        //
        if (draw_context_buffer[draw_index].stream_handle == stream_handle) {
            std.log.info("Found draw context at index {d}. Deleting.", .{draw_index});
            //
            // Remove the buffer entry
            //
            utils.leftShiftRemove(DrawContext, &draw_context_buffer, draw_index);
            source_count -= 1;
            // Since we're left shifting, we have to decrement the index again or else 
            // we'll just be seeing the same buffer value next iteration
            draw_index_signed -= 1;
            //
            // Set the handle -> buffer index binding to null so it can be reused
            //
            draw_handle_buffer[draw_index] = std.math.maxInt(DrawHandle);
        }
    }
    stream_count -= 1;
}

var pending_remove_stream_handle: ?u32 = null;

pub fn createStream(
    supported_image_format: SupportedImageFormat,
    source_dimensions: Dimensions2D(u32),
) !u32 {
    if (stream_count == max_stream_count)
        return error.StreamLimitReached;

    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    const stream_handle = assignNewStreamHandle();
    const stream_ptr: *Stream = streamFromHandle(stream_handle);
    stream_ptr.dimensions = .{
        .width = @intToFloat(f32, source_dimensions.width),
        .height = @intToFloat(f32, source_dimensions.height),
    };

    std.log.info("renderer: Adding stream #{d} with dimensions: {d} x {d}", .{
        streamIndexFromHandle(stream_handle),
        stream_ptr.dimensions.width,
        stream_ptr.dimensions.height,
    });

    const image_format = switch (supported_image_format) {
        .rgba => vk.Format.r8g8b8a8_unorm,
        .bgrx => vk.Format.b8g8r8a8_unorm,
    };

    const pixel_count = source_dimensions.width * source_dimensions.height;
    const bytes_per_pixel = 4;
    const image_size_bytes: usize = pixel_count * bytes_per_pixel;
    const image_create_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = image_format,
        .tiling = .linear,
        .extent = vk.Extent3D{
            .width = source_dimensions.width,
            .height = source_dimensions.height,
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .initial_layout = .undefined,
        .usage = .{ .transfer_src_bit = true },
        .samples = .{ .@"1_bit" = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    stream_ptr.image = try device_dispatch.createImage(logical_device, &image_create_info, null);
    const memory_requirements = device_dispatch.getImageMemoryRequirements(logical_device, stream_ptr.image);
    stream_ptr.memory = try device_dispatch.allocateMemory(logical_device, &.{
        .allocation_size = memory_requirements.size,
        .memory_type_index = cpu_memory_index,
    }, null);

    stream_ptr.mapped_memory = @ptrCast([*]u8, (try device_dispatch.mapMemory(logical_device, stream_ptr.memory, 0, image_size_bytes, .{})).?)[0 .. pixel_count * 4];

    try device_dispatch.bindImageMemory(logical_device, stream_ptr.image, stream_ptr.memory, 0);

    //
    // Transition from `undefined` to `general`
    //

    var command_buffer: vk.CommandBuffer = undefined;
    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan_core.command_pool,
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

    const image_barriers = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{},
            .old_layout = .undefined,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = stream_ptr.image,
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
        //
        // Transfer will produce the data, and in this case we nothing in the pipeline depends on it
        //
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
            image_barriers.len,
            &image_barriers,
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

    const fence = try device_dispatch.createFence(logical_device, &.{ .flags = .{} }, null);
    try device_dispatch.queueSubmit(
        vulkan_core.graphics_present_queue,
        1,
        &submit_command_infos,
        fence,
    );

    const wait_fence_result = try device_dispatch.waitForFences(
        logical_device,
        1,
        &[1]vk.Fence{fence},
        vk.TRUE,
        std.math.maxInt(u64),
    );
    assert(wait_fence_result == .success);
    device_dispatch.destroyFence(logical_device, fence, null);
    device_dispatch.freeCommandBuffers(
        logical_device,
        vulkan_core.command_pool,
        1,
        @ptrCast([*]vk.CommandBuffer, &command_buffer),
    );
    return stream_handle;
}

pub fn recordBlitCommand(command_buffer: vk.CommandBuffer) !void {
    if (pending_remove_stream_handle) |stream_handle| {
        destroyStream(stream_handle);
        pending_remove_stream_handle = null;
    }

    if (draw_quad_count == 0)
        return;

    assert(source_count != 0);
    assert(draw_quad_count == 1);

    const device_dispatch = vulkan_core.device_dispatch;

    @memset(canvas_mapped_memory, RGBA(u8).black);
    @memset(unscaled_canvas_mapped_memory, RGBA(u8).black);

    for (0..source_count) |i| {
        const draw_context_ptr: *const DrawContext = &draw_context_buffer[i];
        const stream_index = streamIndexFromHandle(draw_context_ptr.stream_handle);
        const stream_ptr: *const Stream = &stream_buffer[stream_index];
        const relative_extent = draw_context_ptr.relative_extent;

        assert(relative_extent.x >= 0.0);
        assert(relative_extent.x <= 1.0);
        assert(relative_extent.y >= 0.0);
        assert(relative_extent.y <= 1.0);
        assert(relative_extent.width >= 0.0);
        assert(relative_extent.width <= 1.0);
        assert(relative_extent.height >= 0.0);
        assert(relative_extent.height <= 1.0);

        assert(relative_extent.x + relative_extent.width <= 1.0);
        assert(relative_extent.y + relative_extent.height <= 1.0);

        const scale_factor = ScaleFactor2D(f32){
            .horizontal = stream_ptr.dimensions.width / @intToFloat(f32, unscaled_canvas_dimensions.width),
            .vertical = stream_ptr.dimensions.height / @intToFloat(f32, unscaled_canvas_dimensions.height),
        };
        //
        // Assert we're not upscaling the image as that isn't supported currently
        //
        assert(scale_factor.horizontal <= 1.0);
        assert(scale_factor.vertical <= 1.0);

        const subresource_layers = vk.ImageSubresourceLayers{
            .aspect_mask = .{ .color_bit = true },
            .layer_count = 1,
            .mip_level = 0,
            .base_array_layer = 0,
        };

        var src_region_offsets = [2]vk.Offset3D{
            .{ .x = 0, .y = 0, .z = 0 },
            .{
                .x = @floatToInt(i32, stream_ptr.dimensions.width),
                .y = @floatToInt(i32, stream_ptr.dimensions.height),
                .z = 1,
            },
        };

        const top_left = Coordinates2D(f32){
            .x = canvas_dimensions.width * relative_extent.x,
            .y = canvas_dimensions.height * (1.0 - (relative_extent.height + relative_extent.y)),
        };
        const bottom_right = Coordinates2D(f32){
            .x = canvas_dimensions.width * relative_extent.width * scale_factor.horizontal,
            .y = canvas_dimensions.height * relative_extent.height * scale_factor.vertical,
        };

        assert(top_left.x <= canvas_dimensions.width);
        assert(bottom_right.x <= canvas_dimensions.width);
        assert(top_left.y <= canvas_dimensions.height);
        assert(bottom_right.y <= canvas_dimensions.height);

        const dst_region_offsets = [2]vk.Offset3D{
            .{
                .x = @floatToInt(i32, @floor(top_left.x)),
                .y = @floatToInt(i32, @floor(top_left.y)),
                .z = 0,
            },
            .{
                .x = @floatToInt(i32, @floor(bottom_right.x)),
                .y = @floatToInt(i32, @floor(bottom_right.y)),
                .z = 1,
            },
        };

        assert(dst_region_offsets[0].x >= 0);
        assert(dst_region_offsets[0].y >= 0);
        assert(dst_region_offsets[1].x >= 0);
        assert(dst_region_offsets[1].y >= 0);

        const regions = [_]vk.ImageBlit{.{
            .src_subresource = subresource_layers,
            .src_offsets = src_region_offsets,
            .dst_subresource = subresource_layers,
            .dst_offsets = dst_region_offsets,
        }};

        device_dispatch.cmdBlitImage(
            command_buffer,
            stream_ptr.image,
            .general,
            canvas_image,
            .general,
            1,
            &regions,
            scale_method,
        );
    }

    for (0..source_count) |i| {
        const draw_context_ptr: *const DrawContext = &draw_context_buffer[i];
        const stream_index = streamIndexFromHandle(draw_context_ptr.stream_handle);
        const stream_ptr: *const Stream = &stream_buffer[stream_index];
        const relative_extent = draw_context_ptr.relative_extent;

        const subresource_layers = vk.ImageSubresourceLayers{
            .aspect_mask = .{ .color_bit = true },
            .layer_count = 1,
            .mip_level = 0,
            .base_array_layer = 0,
        };

        var src_region_offsets = [2]vk.Offset3D{
            .{ .x = 0, .y = 0, .z = 0 },
            .{
                .x = @floatToInt(i32, stream_ptr.dimensions.width),
                .y = @floatToInt(i32, stream_ptr.dimensions.height),
                .z = 1,
            },
        };

        const scale_factor = ScaleFactor2D(f32){
            .horizontal = stream_ptr.dimensions.width / @intToFloat(f32, unscaled_canvas_dimensions.width),
            .vertical = stream_ptr.dimensions.height / @intToFloat(f32, unscaled_canvas_dimensions.height),
        };

        const dst_dimensions = Dimensions2D(f32){
            .width = @intToFloat(f32, unscaled_canvas_dimensions.width),
            .height = @intToFloat(f32, unscaled_canvas_dimensions.height),
        };

        const top_left = Coordinates2D(f32){
            .x = dst_dimensions.width * relative_extent.x,
            .y = dst_dimensions.height * (1.0 - (relative_extent.height + relative_extent.y)),
        };
        const bottom_right = Coordinates2D(f32){
            .x = dst_dimensions.width * relative_extent.width * scale_factor.horizontal,
            .y = dst_dimensions.height * relative_extent.height * scale_factor.vertical,
        };

        const dst_region_offsets = [2]vk.Offset3D{
            .{
                .x = @floatToInt(i32, @floor(top_left.x)),
                .y = @floatToInt(i32, @floor(top_left.y)),
                .z = 0,
            },
            .{
                .x = @floatToInt(i32, @floor(bottom_right.x)),
                .y = @floatToInt(i32, @floor(bottom_right.y)),
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
            stream_ptr.image,
            .general,
            unscaled_canvas_image,
            .general,
            1,
            &regions,
            scale_method,
        );
    }

    const image_barriers = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .general,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = canvas_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .general,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = unscaled_canvas_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
    };

    const src_stage = vk.PipelineStageFlags{ .top_of_pipe_bit = true };
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
        image_barriers.len,
        &image_barriers,
    );
}

pub fn recordDrawCommands(command_buffer: vk.CommandBuffer, i: usize, screen_dimensions: Dimensions2D(u32)) !void {
    const device_dispatch = vulkan_core.device_dispatch;

    if (draw_quad_count == 0)
        return;

    assert(stream_count > 0);

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
        &[1]vk.DescriptorSet{descriptor_set_buffer[i]},
        0,
        undefined,
    );

    device_dispatch.cmdDrawIndexed(command_buffer, draw_quad_count * 6, 1, 0, 0, 0);
}

pub fn requiredCpuMemory() comptime_int {
    return comptime quad_capacity * ((@sizeOf(Vertex) * 4) + (@sizeOf(u16) * 6));
}

pub fn resizeCanvas(dimensions: Dimensions2D(u32)) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    assert(dimensions.width > 0);
    assert(dimensions.height > 0);

    const width_equal = (dimensions.width == @floatToInt(u32, canvas_dimensions.width));
    const height_equal = (dimensions.height == @floatToInt(u32, canvas_dimensions.height));

    if (width_equal and height_equal)
        return;

    const pixel_count = dimensions.width * dimensions.height;
    var create_image_view: bool = true;
    var reallocate_memory: bool = true;

    if (dimensions.width != 0) {
        create_image_view = false;

        //
        // TODO: This is a hack, we need to wait until images aren't in use before
        //       we destroy them. We could wait until all command buffers finish but
        //       a better solution would be to defer deletion until a later frame
        //
        std.time.sleep(std.time.ns_per_ms * 1);

        const current_pixel_count = @floatToInt(usize, canvas_dimensions.width) * @floatToInt(usize, canvas_dimensions.height);
        device_dispatch.destroyImageView(logical_device, canvas_image_view, null);
        device_dispatch.destroyImage(logical_device, canvas_image, null);
        if (current_pixel_count < pixel_count) {
            //
            // Requested dimensions are larger, re-allocate resources
            //
            device_dispatch.freeMemory(logical_device, canvas_memory, null);
        } else {
            reallocate_memory = false;
        }
    }
    canvas_dimensions = .{
        .width = @intToFloat(f32, dimensions.width),
        .height = @intToFloat(f32, dimensions.height),
    };

    assert(@floatToInt(u32, canvas_dimensions.width) == dimensions.width);
    assert(@floatToInt(u32, canvas_dimensions.height) == dimensions.height);

    const bytes_per_pixel = 4;
    const image_size_bytes: usize = pixel_count * bytes_per_pixel;
    const image_create_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = .r8g8b8a8_unorm,
        .tiling = .linear,
        .extent = vk.Extent3D{
            .width = dimensions.width,
            .height = dimensions.height,
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .initial_layout = .undefined,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .samples = .{ .@"1_bit" = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    canvas_image = try device_dispatch.createImage(logical_device, &image_create_info, null);

    if (reallocate_memory) {
        const memory_requirements = device_dispatch.getImageMemoryRequirements(logical_device, canvas_image);
        canvas_memory = try vulkan_core.device_dispatch.allocateMemory(logical_device, &.{
            .allocation_size = memory_requirements.size,
            .memory_type_index = cpu_memory_index,
        }, null);
        canvas_mapped_memory = @ptrCast([*]RGBA(u8), (try device_dispatch.mapMemory(logical_device, canvas_memory, 0, image_size_bytes, .{})).?)[0..pixel_count];
        @memset(canvas_mapped_memory, RGBA(u8).black);
    }
    try device_dispatch.bindImageMemory(logical_device, canvas_image, canvas_memory, 0);

    canvas_image_view = try device_dispatch.createImageView(logical_device, &.{
        .flags = .{},
        .image = canvas_image,
        .view_type = .@"2d_array",
        .format = .r8g8b8a8_unorm,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    }, null);

    //
    // Transition from .undefined to .general
    //

    var command_buffer: vk.CommandBuffer = undefined;

    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan_core.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    try device_dispatch.allocateCommandBuffers(
        vulkan_core.logical_device,
        &command_buffer_allocate_info,
        @ptrCast([*]vk.CommandBuffer, &command_buffer),
    );

    try device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const image_barriers = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{},
            .old_layout = .undefined,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = canvas_image,
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
        //
        // Transfer will produce the data, and in this case we nothing in the pipeline depends on it
        //
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
            image_barriers.len,
            &image_barriers,
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

    const fence = try device_dispatch.createFence(logical_device, &.{ .flags = .{} }, null);
    try device_dispatch.queueSubmit(
        vulkan_core.graphics_present_queue,
        1,
        &submit_command_infos,
        fence,
    );

    const wait_fence_result = try device_dispatch.waitForFences(
        logical_device,
        1,
        &[1]vk.Fence{fence},
        vk.TRUE,
        std.math.maxInt(u64),
    );
    assert(wait_fence_result == .success);
    device_dispatch.destroyFence(logical_device, fence, null);
    device_dispatch.freeCommandBuffers(
        logical_device,
        vulkan_core.command_pool,
        1,
        @ptrCast([*]vk.CommandBuffer, &command_buffer),
    );

    try createDescriptorSets(device_dispatch, logical_device, descriptor_count);
}

pub fn init(
    viewport_dimensions: Dimensions2D(u32),
    swapchain_image_count: u32,
    cpu_memory_allocator: *VulkanAllocator,
) !void {
    const device_dispatch = vulkan_core.device_dispatch;
    const logical_device = vulkan_core.logical_device;

    {
        var properties: vk.FormatProperties = undefined;
        properties = vulkan_core.instance_dispatch.getPhysicalDeviceFormatProperties(
            vulkan_core.physical_device,
            .r8g8b8a8_unorm,
        );
        const linear = properties.linear_tiling_features;
        if (!linear.blit_src_bit) {
            std.log.err("Scaling not supported for r8g8b8_unorm image format. Try updating your vulkan driver", .{});
            return error.BlitScalingNotSupported;
        }

        if (linear.sampled_image_filter_linear_bit) {
            scale_method = .linear;
        } else {
            const warning_message =
                "Linear scaling not supported for r8g8b8_unorm image format. Quality of preview canvas will be degraded." ++
                "Try updating your vulkan driver";
            std.log.err(warning_message, .{});
        }
    }

    descriptor_count = swapchain_image_count;

    cpu_memory_index = cpu_memory_allocator.memory_index;

    const vertex_buffer_create_info = vk.BufferCreateInfo{
        .size = vertex_buffer_capacity * @sizeOf(Vertex),
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
        .size = index_buffer_capacity * @sizeOf(u16),
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

    vertices_buffer = cpu_memory_allocator.toSlice(Vertex, vertex_buffer_memory_offset, vertex_buffer_capacity);
    indices_buffer = cpu_memory_allocator.toSlice(u16, index_buffer_memory_offset, index_buffer_capacity);

    //
    // Preinitialize Index buffer since we'll only be drawing quads
    //
    {
        var index_offset: usize = 0;
        var vertex_offset: u16 = 0;
        inline for (0..max_draw_count) |_| {
            indices_buffer[index_offset + 0] = vertex_offset + 0; // Top left
            indices_buffer[index_offset + 1] = vertex_offset + 1; // Top right
            indices_buffer[index_offset + 2] = vertex_offset + 2; // Bottom right
            indices_buffer[index_offset + 3] = vertex_offset + 0; // Top left
            indices_buffer[index_offset + 4] = vertex_offset + 2; // Bottom right
            indices_buffer[index_offset + 5] = vertex_offset + 3; // Bottom left
            index_offset += 6;
            vertex_offset += 4;
        }
    }

    vertex_shader_module = try createVertexShaderModule(device_dispatch, logical_device);
    fragment_shader_module = try createFragmentShaderModule(device_dispatch, logical_device);

    try createDescriptorSetLayouts(device_dispatch, logical_device, swapchain_image_count);

    const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = &descriptor_set_layout_buffer,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
        .flags = .{},
    };
    pipeline_layout = try device_dispatch.createPipelineLayout(logical_device, &pipeline_layout_create_info, null);
    try createDescriptorPool(device_dispatch, logical_device, swapchain_image_count);
    try createGraphicsPipeline(device_dispatch, logical_device, viewport_dimensions);

    //
    // Setup unscaled canvas image
    //

    const pixel_count = unscaled_canvas_dimensions.width * unscaled_canvas_dimensions.height;
    const bytes_per_pixel = 4;
    const image_size_bytes: usize = pixel_count * bytes_per_pixel;
    const image_create_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = .r8g8b8a8_unorm,
        .tiling = .linear,
        .extent = vk.Extent3D{
            .width = unscaled_canvas_dimensions.width,
            .height = unscaled_canvas_dimensions.height,
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .initial_layout = .undefined,
        .usage = .{ .transfer_dst_bit = true },
        .samples = .{ .@"1_bit" = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    unscaled_canvas_image = try device_dispatch.createImage(logical_device, &image_create_info, null);

    const memory_requirements = device_dispatch.getImageMemoryRequirements(logical_device, unscaled_canvas_image);
    unscaled_canvas_memory = try vulkan_core.device_dispatch.allocateMemory(logical_device, &.{
        .allocation_size = memory_requirements.size,
        .memory_type_index = cpu_memory_index,
    }, null);
    unscaled_canvas_mapped_memory = @ptrCast([*]RGBA(u8), (try device_dispatch.mapMemory(logical_device, unscaled_canvas_memory, 0, image_size_bytes, .{})).?)[0..pixel_count];
    @memset(unscaled_canvas_mapped_memory, RGBA(u8).black);

    try device_dispatch.bindImageMemory(logical_device, unscaled_canvas_image, unscaled_canvas_memory, 0);

    //
    // Transition from .undefined to .general
    //

    var command_buffer: vk.CommandBuffer = undefined;

    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = vulkan_core.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    try device_dispatch.allocateCommandBuffers(
        vulkan_core.logical_device,
        &command_buffer_allocate_info,
        @ptrCast([*]vk.CommandBuffer, &command_buffer),
    );

    try device_dispatch.beginCommandBuffer(command_buffer, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const image_barriers = [_]vk.ImageMemoryBarrier{
        .{
            .src_access_mask = .{},
            .dst_access_mask = .{},
            .old_layout = .undefined,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = unscaled_canvas_image,
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
        //
        // Transfer will produce the data, and in this case we nothing in the pipeline depends on it
        //
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
            image_barriers.len,
            &image_barriers,
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

    const fence = try device_dispatch.createFence(logical_device, &.{ .flags = .{} }, null);
    try device_dispatch.queueSubmit(
        vulkan_core.graphics_present_queue,
        1,
        &submit_command_infos,
        fence,
    );

    const wait_fence_result = try device_dispatch.waitForFences(
        logical_device,
        1,
        &[1]vk.Fence{fence},
        vk.TRUE,
        std.math.maxInt(u64),
    );
    assert(wait_fence_result == .success);
    device_dispatch.destroyFence(logical_device, fence, null);
    device_dispatch.freeCommandBuffers(
        logical_device,
        vulkan_core.command_pool,
        1,
        @ptrCast([*]vk.CommandBuffer, &command_buffer),
    );
}

fn createDescriptorPool(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !void {
    const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = .combined_image_sampler,
            .descriptor_count = create_count * 1024,
        },
    };
    const create_pool_info = vk.DescriptorPoolCreateInfo{
        .pool_size_count = descriptor_pool_sizes.len,
        .p_pool_sizes = &descriptor_pool_sizes,
        .max_sets = create_count * 1024,
        .flags = .{},
    };
    descriptor_pool = try device_dispatch.createDescriptorPool(logical_device, &create_pool_info, null);
}

fn createDescriptorSetLayouts(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !void {
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

    // We can copy the same descriptor set layout for each image
    var x: u32 = 1;
    while (x < create_count) : (x += 1) {
        descriptor_set_layout_buffer[x] = descriptor_set_layout_buffer[0];
    }
}

fn createDescriptorSets(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    create_count: u32,
) !void {
    const descriptor_set_allocator_info = vk.DescriptorSetAllocateInfo{
        .descriptor_pool = descriptor_pool,
        .descriptor_set_count = create_count,
        .p_set_layouts = &descriptor_set_layout_buffer,
    };
    device_dispatch.allocateDescriptorSets(
        logical_device,
        &descriptor_set_allocator_info,
        &descriptor_set_buffer,
    ) catch |err| {
        if (err != error.OutOfPoolMemory)
            return err;
        device_dispatch.destroyDescriptorPool(logical_device, descriptor_pool, null);
        descriptor_pool = undefined;
        createDescriptorPool(device_dispatch, logical_device, descriptor_count) catch return error.ReallocateDescriptorPoolFail;
        device_dispatch.allocateDescriptorSets(
            logical_device,
            &descriptor_set_allocator_info,
            &descriptor_set_buffer,
        ) catch |sub_err| return sub_err;
    };

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

    var i: u32 = 0;
    while (i < create_count) : (i += 1) {
        const descriptor_image_info = [_]vk.DescriptorImageInfo{
            .{
                .image_layout = .general,
                .image_view = canvas_image_view,
                .sampler = sampler,
            },
        };
        const write_descriptor_set = [_]vk.WriteDescriptorSet{.{
            .dst_set = descriptor_set_buffer[i],
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

fn createGraphicsPipeline(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
    initial_viewport_dimensions: Dimensions2D(u32),
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

    const vertex_input_binding_descriptions = [_]vk.VertexInputBindingDescription{
        .{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        },
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = @intCast(u32, vertex_input_binding_descriptions.len),
        .vertex_attribute_description_count = @intCast(u32, vertex_input_attribute_descriptions.len),
        .p_vertex_binding_descriptions = &vertex_input_binding_descriptions,
        .p_vertex_attribute_descriptions = &vertex_input_attribute_descriptions,
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
            .width = @intToFloat(f32, initial_viewport_dimensions.width),
            .height = @intToFloat(f32, initial_viewport_dimensions.height),
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
                .width = initial_viewport_dimensions.width,
                .height = initial_viewport_dimensions.height,
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
        .rasterization_samples = shared_render_pass.antialias_sample_count,
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
        .dynamic_state_count = @intCast(u32, dynamic_states.len),
        .p_dynamic_states = &dynamic_states,
        .flags = .{},
    };

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
            .render_pass = shared_render_pass.pass,
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
        .code_size = shaders.texture_fragment_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.texture_fragment_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}

fn createVertexShaderModule(
    device_dispatch: vulkan_config.DeviceDispatch,
    logical_device: vk.Device,
) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = shaders.texture_vertex_spv.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shaders.texture_vertex_spv)),
        .flags = .{},
    };
    return try device_dispatch.createShaderModule(logical_device, &create_info, null);
}
