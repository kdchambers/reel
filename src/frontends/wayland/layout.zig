// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;

const Model = @import("../../Model.zig");
const UIState = @import("UIState.zig");
const audio = @import("audio.zig");

const widgets = @import("widgets.zig");
const Section = widgets.Section;
const TabbedSection = widgets.TabbedSection;

const utils = @import("../../utils.zig");
const Duration = utils.Duration;

const geometry = @import("../../geometry.zig");
pub const ui_layer = geometry.ui_layer;
const Extent2D = geometry.Extent2D;
const Extent3D = geometry.Extent3D;
const Coordinates2D = geometry.Coordinates2D;
const Coordinates3D = geometry.Coordinates3D;
const ScaleFactor2D = geometry.ScaleFactor2D;

pub const Anchors = struct {
    left: ?f32 = null,
    right: ?f32 = null,
    top: ?f32 = null,
    bottom: ?f32 = null,
};

pub const Margins = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,
};

pub const Placement = struct {
    anchor: Anchors = .{},
    margin: Margins = .{},
    z: f32 = ui_layer.middle,

    pub inline fn top(self: @This()) f32 {
        const base = self.anchor.top orelse self.anchor.bottom.? - self.margin.bottom;
        return base + self.margin.top;
    }

    pub inline fn bottom(self: @This()) f32 {
        const base = self.anchor.bottom orelse self.anchor.top.? + self.margin.top;
        return base - self.margin.bottom;
    }

    pub inline fn left(self: @This()) f32 {
        const base = self.anchor.left orelse self.anchor.right.? - self.margin.right;
        return base + self.margin.left;
    }

    pub inline fn right(self: @This()) f32 {
        const base = self.anchor.right orelse self.anchor.left.? + self.margin.left;
        return base - self.margin.right;
    }

    pub fn placement(self: @This()) Coordinates3D(f32) {
        const base_x = self.anchor.left orelse self.anchor.right.? - self.margin.right;
        const base_y = self.anchor.bottom orelse self.anchor.top.? + self.margin.top;
        return .{
            .x = base_x + self.margin.left,
            .y = base_y - self.margin.bottom,
            .z = self.z,
        };
    }
};

pub const Region = struct {
    anchor: Anchors = .{},
    margin: Margins = .{},
    width: ?f32 = null,
    height: ?f32 = null,
    z: f32 = ui_layer.middle,

    pub inline fn top(self: @This()) f32 {
        const base = self.anchor.top orelse self.anchor.bottom.? - self.margin.bottom - self.height.?;
        return base + self.margin.top;
    }

    pub inline fn bottom(self: @This()) f32 {
        const base = self.anchor.bottom orelse self.anchor.top.? + self.margin.top + self.height.?;
        return base - self.margin.bottom;
    }

    pub inline fn left(self: @This()) f32 {
        const base = self.anchor.left orelse self.anchor.right.? - self.width.? - self.margin.right;
        return base + self.margin.left;
    }

    pub inline fn right(self: @This()) f32 {
        const base = self.anchor.right orelse self.anchor.left.? + self.margin.left + self.width.?;
        return base - self.margin.right;
    }

    pub fn toExtent(self: @This()) Extent3D(f32) {
        const x = self.anchor.left orelse self.anchor.right.? - self.width.? - self.margin.right;
        const y = self.anchor.bottom orelse self.anchor.top.? + self.height.? + self.margin.top;
        const width = blk: {
            if (self.width) |width| {
                break :blk width;
            }
            if (self.anchor.right) |right_anchor| {
                break :blk (right_anchor - self.margin.right) - (x + self.margin.left);
            }
            unreachable;
        };
        const height = blk: {
            if (self.height) |height| {
                break :blk height;
            }
            if (self.anchor.top) |top_anchor| {
                break :blk (y - top_anchor) - self.margin.top;
            }
            unreachable;
        };
        return .{
            .x = x + self.margin.left,
            .y = y - self.margin.bottom,
            .z = self.z,
            .width = width,
            .height = height,
        };
    }

    pub fn placement(self: @This()) Coordinates3D(f32) {
        const base_x = self.anchor.left orelse self.anchor.right.? - self.width.? - self.margin.right;
        const base_y = self.anchor.bottom orelse self.anchor.top.? + self.height.? + self.margin.top;
        return .{
            .x = base_x + self.margin.left,
            .y = base_y - self.margin.bottom,
            .z = self.z,
        };
    }
};
