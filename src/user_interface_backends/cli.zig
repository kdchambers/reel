// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const linux = std.os.linux;

const app_core = @import("../app_core.zig");
const RequestBuffer = app_core.RequestBuffer;
const Request = app_core.Request;

const RequestEncoder = @import("../RequestEncoder.zig");

var request_encoder: RequestEncoder = .{};

const bindings = struct {
    const quit = [_]u8{'q'};
    const screenshot = [_]u8{'s'};
    const help = [_]u8{'h'};
    const list_displays = [_]u8{ 'l', 'd' };
};

var input_loop_thread: std.Thread = undefined;

pub fn init() void {
    input_loop_thread = std.Thread.spawn(.{}, inputLoop, .{}) catch return;
    _ = std.io.getStdOut().write("reel: ") catch {};
}

const help_message =
    \\h: Display this help message
    \\q: Quit Reel
    \\s: Take a screenshot
    \\ld: List displays
;

const Command = enum(u8) {
    screenshot,
    quit,
    display_help,
    display_list,
    invalid,
};

var user_command: ?Command = null;
var commands_mutex: std.Thread.Mutex = .{};

var input_loop_shutdown: bool = false;

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
        if (bytes_read > 1) do_command: {
            commands_mutex.lock();
            defer commands_mutex.unlock();

            const input_line = input_buffer[0 .. bytes_read - 1];

            if (std.mem.eql(u8, &bindings.quit, input_line)) {
                user_command = .quit;
                break :do_command;
            }

            if (std.mem.eql(u8, &bindings.screenshot, input_line)) {
                user_command = .screenshot;
                break :do_command;
            }

            if (std.mem.eql(u8, &bindings.help, input_line)) {
                user_command = .display_help;
                break :do_command;
            }

            if (std.mem.eql(u8, &bindings.list_displays, input_line)) {
                user_command = .display_list;
                break :do_command;
            }

            user_command = .invalid;
        }
    }
}

pub fn update() RequestBuffer {
    request_encoder.used = 0;
    const stdout = std.io.getStdOut();

    commands_mutex.lock();
    defer commands_mutex.unlock();

    if (user_command) |command| {
        switch (command) {
            .screenshot => request_encoder.write(.screenshot_do) catch {},
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

    return request_encoder.toRequestBuffer();
}

pub fn deinit() void {
    input_loop_shutdown = true;
    input_loop_thread.join();
}
