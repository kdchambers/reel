// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

pub fn Coordinates2D(comptime BaseType: type) type {
    return extern struct {
        x: BaseType,
        y: BaseType,
    };
}

pub fn Dimensions2D(comptime BaseType: type) type {
    return extern struct {
        height: BaseType,
        width: BaseType,
    };
}

pub fn Extent2D(comptime BaseType: type) type {
    return packed struct {
        x: BaseType,
        y: BaseType,
        height: BaseType,
        width: BaseType,

        inline fn isWithinBounds(self: @This(), comptime T: type, point: T) bool {
            const end_x = self.x + self.width;
            const end_y = self.y + self.height;
            return (point.x >= self.x and point.y >= self.y and point.x <= end_x and point.y <= end_y);
        }
    };
}

pub fn ScaleFactor2D(comptime BaseType: type) type {
    return struct {
        horizontal: BaseType,
        vertical: BaseType,
    };
}
