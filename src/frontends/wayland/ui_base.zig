// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

// A View can manage a visible part of the screen, when it gets destroyed
// it will de-register all related events in event system
// Can be a union?
// const ViewRoot = union(enum) {
//     main: ViewMain,

//     pub fn changeView(view: View) {}
// };

// const View = struct {
//     //
//     pub fn init() void {}
//     pub fn update() void {}
//     pub fn deinit() void {}
// };

//
// Classification of User Interface
//
// Widgets (Reuseable high level components)
//   Section
//   Checkbox
//   Button
// Event System
// Graphics base (For drawing shapes, etc)
// User Interface Base (Higher level components used in specific UI) Like Audio thing?
//   I guess I can create a higher level button here
//

// Hmm maybe I can use user_interface and graphic_interface
// or ui and gui ui_base, gui_base

// How would you make a GUI library?

// It would just output vertices, indices
// So would need to take an face_write interface as a dependency
// Maybe all widgets should be part of Wayland ??
// I guess it would be nice to create Buttons using comptime

const RecordButton = Button(.{
    .hover = true,
    .label = true,
    .image = false,
    .rounding = false,
});

var record_button: Button(.{
    .hover = true,
    .label = true,
    .image = false,
    .rounding = false,
}) = undefined;

const ButtonOptions = struct {
    hover: bool = false,
    label: bool = false,
    image: bool = false,
    rounding: bool = false,
};

fn Button(comptime options: ButtonOptions) type {
    // TODO: Implement image
    comptime assert(options.image == false);
    return struct {
        const DrawOptions = struct {
            rounding_radius: if (options.rounding) f32 else void,
        };

        color: RGBA,
        on_hover_color: if (options.hover) RGBA else void,

        pub inline fn init(self: *@This()) void {
            self.internal = widget.Button.create();
        }

        pub const draw = drawLabel;

        /// Spawn an instance of this widget. This will allocate space in the
        /// vertex buffer and register events with event system
        inline fn drawLabel(
            self: *@This(),
            extent: Extent2D(f32),
            label: []const u8,
        ) void {
            if (comptime !options.label)
                unreachable;
            self.internal.draw(
                extent,
                self.color,
                label,
                &pen,
                screen_scale,
                .{ .rounding_radius = null },
            ) catch |err| {
                std.log.err("Failed to draw Button widget. Error: {}", .{err});
            };
        }
    };
}

const Widget = struct {
    init: *const InitFn,
    draw: *const DrawFn,
    update: *const UpdateFn,
};

const View = struct {
    fn draw(widgets: []Widget) !void {
        //
    }
};

/// Wrapper over widget.Button
const Button = struct {
    internal: widget.Button,
    color: RGBA(f32),
    on_hover_color: RGBA(f32),

    /// Allocates space within event system to keep track of state
    /// that doesn't change across redraws
    pub inline fn init(self: *@This()) void {
        self.internal = widget.Button.create();
    }

    /// Spawn an instance of this widget. This will allocate space in the
    /// vertex buffer and register events with event system
    pub inline fn draw(
        self: *@This(),
        extent: Extent2D(f32),
        label: []const u8,
    ) void {
        self.internal.draw(
            extent,
            self.color,
            label,
            &pen,
            screen_scale,
            .{ .rounding_radius = null },
        ) catch |err| {
            std.log.err("Failed to draw Button widget. Error: {}", .{err});
        };
    }

    /// Update the color if hovered and return remaining events, if any
    /// If there are no other state changes, null is returned instead
    pub inline fn update() ?State {
        var state = self.internal.state();
        if (state.hover_enter)
            self.internal.setColor(self.on_hover_color);
        if (state.hover_exit)
            self.internal.setColor(self.color);
        state.hover_enter = false;
        state.hover_exit = false;
        return if (@bitCast(u8, state) != 0) state else null;
    }
};
