// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");
const event_system = @import("event_system.zig");
const mini_heap = @import("mini_heap.zig");

const QuadFaceWriter = graphics.QuadFaceWriter;
const QuadFace = graphics.QuadFace;
const HoverZoneState = event_system.HoverZoneState;
const Index = mini_heap.Index;

pub const button = struct {
    pub const Handle = packed struct(u32) {
        face_index: u16,
        state: Index(HoverZoneState),
    };

    pub fn draw(
        face_writer: *QuadFaceWriter,
        extent: geometry.Extent2D(f32),
        color: graphics.RGBA(f32),
    ) !Handle {
        const face_index = face_writer.used;
        (try face_writer.create()).* = graphics.quadColored(extent, color, .bottom_left);
        const state_index = event_system.addMouseEvent(extent, true);
        return Handle{
            .face_index = @intCast(u16, face_index),
            .state = state_index,
        };
    }
};
