// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const linux = std.os.linux;
const termios = linux.termios;

const app_core = @import("../app_core.zig");
const RequestBuffer = app_core.RequestBuffer;
const Request = app_core.Request;

const RequestEncoder = @import("../RequestEncoder.zig");

var request_encoder: RequestEncoder = .{};

var modified_termios: termios = undefined;
var original_termios: termios = undefined;

pub fn init() void {
    _ = linux.tcgetattr(0, &original_termios);
    modified_termios = original_termios;
    cfmakeraw(&modified_termios);
    _ = linux.tcsetattr(0, .NOW, &modified_termios);
}

pub fn update() RequestBuffer {
    request_encoder.used = 0;

    const timeout_milliseconds = 4;
    var pollfd = linux.pollfd{
        .fd = 0,
        .events = linux.POLL.IN,
        .revents = 0,
    };
    const poll_code = linux.poll(@ptrCast([*]linux.pollfd, &pollfd), 1, timeout_milliseconds);
    if (poll_code == 0) {
        //
        // Timed out
        //
        return request_encoder.toRequestBuffer();
    }
    if (poll_code < 0) {
        //
        // Error occurred
        //
        std.log.err("Error in cli poll", .{});
        return request_encoder.toRequestBuffer();
    }

    var term_char: u8 = 0;
    const read_code = linux.read(0, @ptrCast([*]u8, &term_char), @sizeOf(@TypeOf(term_char)));
    if (read_code <= 0) {
        std.log.err("Error in cli read", .{});
        return request_encoder.toRequestBuffer();
    }

    if (term_char == 'q') {
        request_encoder.write(.core_shutdown) catch {};
    }
    return request_encoder.toRequestBuffer();
}

pub fn deinit() void {
    _ = linux.tcsetattr(0, .NOW, &original_termios);
}

// https://linux.die.net/man/3/cfmakeraw
fn cfmakeraw(termios_p: *termios) void {
    termios_p.iflag &= ~(linux.IGNBRK | linux.BRKINT | linux.PARMRK | linux.ISTRIP | linux.INLCR | linux.IGNCR | linux.ICRNL | linux.IXON);
    termios_p.oflag &= ~linux.OPOST;
    termios_p.lflag &= ~(linux.ECHO | linux.ECHONL | linux.ICANON | linux.ISIG | linux.IEXTEN);
    termios_p.cflag &= ~(linux.CSIZE | linux.PARENB);
    termios_p.cflag |= linux.CS8;
}
