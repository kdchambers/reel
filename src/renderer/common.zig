// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

pub const VertexRange = packed struct(u32) {
    start: u16,
    count: u16,

    pub inline fn end(self: @This()) usize {
        return self.start + self.count;
    }
};
