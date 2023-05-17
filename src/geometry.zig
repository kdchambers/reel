// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

pub const ui_layer = struct {
    pub const top = 0.0;

    pub const high_upper = 0.25;
    pub const high = 0.3;
    pub const high_lower = 0.35;

    pub const middle_upper = 0.45;
    pub const middle = 0.5;
    pub const middle_lower = 0.55;

    pub const low_upper = 0.75;
    pub const low = 0.8;
    pub const low_lower = 0.85;

    pub const bottom = 1.0;
};

pub fn Coordinates2D(comptime BaseType: type) type {
    return extern struct {
        x: BaseType,
        y: BaseType,
    };
}

pub fn Coordinates3D(comptime BaseType: type) type {
    return extern struct {
        x: BaseType,
        y: BaseType,
        z: BaseType = ui_layer.middle,
    };
}

pub fn Dimensions2D(comptime BaseType: type) type {
    return extern struct {
        height: BaseType,
        width: BaseType,
    };
}

pub fn Extent2D(comptime BaseType: type) type {
    return extern struct {
        x: BaseType,
        y: BaseType,
        height: BaseType,
        width: BaseType,

        inline fn isWithinBounds(self: @This(), comptime T: type, point: T) bool {
            const end_x = self.x + self.width;
            const end_y = self.y + self.height;
            return (point.x >= self.x and point.y >= self.y and point.x <= end_x and point.y <= end_y);
        }

        pub inline fn to3D(self: @This(), z: f32) Extent3D(BaseType) {
            return .{
                .x = self.x,
                .y = self.y,
                .z = z,
                .width = self.width,
                .height = self.height,
            };
        }
    };
}

pub fn Extent3D(comptime BaseType: type) type {
    return extern struct {
        x: BaseType,
        y: BaseType,
        z: BaseType = ui_layer.middle,
        height: BaseType,
        width: BaseType,

        pub inline fn to2D(self: @This()) Extent2D(BaseType) {
            return .{
                .x = self.x,
                .y = self.y,
                .width = self.width,
                .height = self.height,
            };
        }
    };
}

pub fn ScaleFactor2D(comptime BaseType: type) type {
    return struct {
        horizontal: BaseType,
        vertical: BaseType,
    };
}

pub fn Radius2D(comptime Type: type) type {
    return struct {
        h: Type,
        v: Type,
    };
}
