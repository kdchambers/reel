// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const linux = std.os.linux;

const Model = @import("../Model.zig");
const app_core = @import("../app_core.zig");
const CoreUpdateDecoder = app_core.UpdateDecoder;
const CoreRequestEncoder = app_core.CoreRequestEncoder;
const CoreRequestDecoder = app_core.CoreRequestDecoder;

const Command = enum(u8) {
    screenshot,
    screenshot_display_set,
    quit,
    display_help,
    display_list,
    invalid,
};

var request_encoder: CoreRequestEncoder = .{};

const bindings = struct {
    const quit = [_]u8{'q'};
    const screenshot = [_]u8{'s'};
    const help = [_]u8{'h'};
    const screenshot_display_set = [_]u8{ 's', 'd', 's' };
    const list_displays = [_]u8{ 'l', 'd' };
};

const help_message =
    \\h: Display this help message
    \\q: Quit Reel
    \\s: Take a screenshot
    \\ld: List displays
    \\sds: Set screenshot display
;

var input_loop_thread: std.Thread = undefined;
var user_command: ?Command = null;
var commands_mutex: std.Thread.Mutex = .{};
var input_loop_shutdown: bool = false;

pub const InitError = error{};
pub const UpdateError = error{};

//
// TODO: Update interface to allow init to return errors
//
pub fn init(_: std.mem.Allocator) InitError!void {
    input_loop_thread = std.Thread.spawn(.{}, inputLoop, .{}) catch return;
    _ = std.io.getStdOut().write("reel: ") catch {};
}

var screenshot_display_index: u8 = 0;

fn inputLoop() void {
    var input_buffer: [512]u8 = undefined;
    const stdin = std.io.getStdIn();
    while (!input_loop_shutdown) {
        const timeout_milliseconds = 10;
        var pollfd = linux.pollfd{
            .fd = stdin.handle,
            .events = linux.POLL.IN,
            .revents = 0,
        };
        const poll_code = linux.poll(@ptrCast([*]linux.pollfd, &pollfd), 1, timeout_milliseconds);
        if (poll_code == 0) {
            // Poll timed-out, jump back to top of loop and see if we should terminate
            continue;
        }

        if (poll_code < 0) {
            // An error occurred in polling
            continue;
        }

        // Input should be available and call to read shouldn't block
        const bytes_read = stdin.read(&input_buffer) catch 0;
        if (bytes_read > 1) process_line: {
            commands_mutex.lock();
            defer commands_mutex.unlock();

            const input_line = input_buffer[0 .. bytes_read - 1];

            if (std.mem.eql(u8, &bindings.quit, input_line)) {
                user_command = .quit;
                break :process_line;
            }

            if (std.mem.eql(u8, &bindings.screenshot, input_line)) {
                user_command = .screenshot;
                break :process_line;
            }

            if (std.mem.eql(u8, &bindings.help, input_line)) {
                user_command = .display_help;
                break :process_line;
            }

            if (std.mem.eql(u8, &bindings.list_displays, input_line)) {
                user_command = .display_list;
                break :process_line;
            }

            if (input_line.len == 5 and std.mem.eql(u8, &bindings.screenshot_display_set, input_line[0..3])) {
                screenshot_display_index = input_line[4] - '0';
                user_command = .screenshot_display_set;
                break :process_line;
            }

            user_command = .invalid;
        }
    }
}

pub fn update(_: *const Model, _: *CoreUpdateDecoder) UpdateError!CoreRequestDecoder {
    request_encoder.used = 0;
    const stdout = std.io.getStdOut();

    commands_mutex.lock();
    defer commands_mutex.unlock();

    if (user_command) |command| {
        switch (command) {
            .screenshot => request_encoder.write(.screenshot_do) catch {},
            .screenshot_display_set => {
                request_encoder.write(.screenshot_display_set) catch {};
                request_encoder.writeInt(u16, screenshot_display_index) catch {};
            },
            .quit => request_encoder.write(.core_shutdown) catch {},
            .display_list => {
                const display_list = app_core.displayList();
                _ = stdout.write("Display List:\n") catch {};
                for (display_list, 0..) |display, display_i| {
                    const index_char = [1]u8{@intCast(u8, display_i) + '0'};
                    _ = stdout.write("  ") catch {};
                    _ = stdout.write(&index_char) catch {};
                    _ = stdout.write(". ") catch {};
                    _ = stdout.write(display) catch {};
                    _ = stdout.write("\n") catch {};
                }
            },
            .display_help, .invalid => {
                _ = stdout.write(help_message) catch {};
            },
        }
        _ = stdout.write("\nreel: ") catch {};
    }
    user_command = null;

    return request_encoder.decoder();
}

pub fn deinit() void {
    input_loop_shutdown = true;
    input_loop_thread.join();
}
