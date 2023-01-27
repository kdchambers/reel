// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const graphics = @import("graphics.zig");

pub const State = enum(u8) {
    uninitialized,
    init_pending,
    init_failed,
    open,
    closed,
};

pub const OpenOnSuccessFn = fn (width: u32, height: u32) void;
pub const OpenOnErrorFn = fn () void;

pub const PixelType = graphics.RGBA(u8);
pub const FrameImage = graphics.Image(PixelType);
