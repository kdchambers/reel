// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");

pub const pulse = @import("audio/pulse.zig");

const Backend = enum {
    alsa,
    pulseaudio,
    jack,
    pipewire,
};

pub const OpenError = pulse.OpenErrors || error{Unknown};
pub const InitError = pulse.InitErrors || error{Unknown};

pub const InitFn = fn (
    successCallback: *const InitSuccessCallbackFn,
    failureCallback: *const InitFailCallbackFn,
) InitError!void;

pub const OpenFn = fn (
    device_name: ?[*:0]const u8,
    successCallback: *const OpenSuccessCallbackFn,
    failureCallback: *const OpenFailCallbackFn,
) OpenError!void;

pub const InitSuccessCallbackFn = fn () void;
pub const InitFailCallbackFn = fn (err: InitError) void;

pub const OpenSuccessCallbackFn = fn () void;
pub const OpenFailCallbackFn = fn (err: OpenError) void;

pub const CloseFn = fn () void;
pub const GetStateFn = fn () State;
pub const InputListFn = fn (allocator: std.mem.Allocator, callback: *const InputListCallbackFn) void;
pub const InputListCallbackFn = fn (input_devices: []InputDeviceInfo) void;

pub const OnReadSamplesFn = fn (samples: []i16) void;

pub const InputDeviceInfo = struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
};

pub const State = enum {
    initialized,
    closed,
    open,
};

pub const Interface = struct {
    init: *const InitFn,
    open: *const OpenFn,
    close: *const CloseFn,
    inputList: *const InputListFn,
    state: *const GetStateFn,
};

// TODO: Support more backends
pub fn createBestInterface(on_read_sample_callback: *const OnReadSamplesFn) Interface {
    return pulse.createInterface(on_read_sample_callback);
}

pub fn availableBackends(backend_buffer: *[4]Backend) []Backend {
    backend_buffer[0] = .pulseaudio;
    return backend_buffer[0..1];
}

//
// Utility audio functions
// TODO: Separate "audio" from audio input backends
//

pub fn SampleRingBuffer(
    comptime SampleType: type,
    comptime samples_per_buffer: usize,
    comptime buffer_count: usize,
) type {
    return struct {
        buffers: [buffer_count][samples_per_buffer]SampleType = undefined,
        used: [buffer_count]usize = [1]usize{0} ** buffer_count,
        head: usize = 0,
        len: usize = 0,

        mutex: std.Thread.Mutex = .{},

        pub fn reset(self: *@This()) void {
            self.head = 0;
            self.len = 0;
        }

        pub fn push(self: *@This(), samples: []const i16) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            //
            // TODO: Calculate whether there is enough space upfront
            //
            var src_index: usize = 0;
            while (src_index < samples.len) {
                const tail_index = @mod(self.head + self.len, buffer_count);
                const space_in_buffer: usize = samples_per_buffer - self.used[tail_index];
                const start_index: usize = self.used[tail_index];
                const src_samples_remaining: usize = samples.len - src_index;
                const samples_to_copy_count: usize = @min(src_samples_remaining, space_in_buffer);
                const buffer_filled = (samples_to_copy_count == space_in_buffer);
                for (start_index..start_index + samples_to_copy_count) |i| {
                    //
                    // TODO: Use SIMD
                    //
                    self.buffers[tail_index][i] = @max(-1.0, @intToFloat(f32, samples[src_index]) / std.math.maxInt(i16));
                    std.debug.assert(self.buffers[tail_index][i] >= -1.0);
                    std.debug.assert(self.buffers[tail_index][i] <= 1.0);
                    src_index += 1;
                    std.debug.assert(src_index <= samples.len);
                }
                self.used[tail_index] += samples_to_copy_count;

                std.debug.assert((self.used[tail_index] == samples_per_buffer) == buffer_filled);
                std.debug.assert(self.used[tail_index] <= samples_per_buffer);

                if (buffer_filled) {
                    self.len += 1;
                    if (self.len > buffer_count)
                        return error.OutOfSpace;
                }
            }
        }

        pub fn pop(self: *@This()) ?*[samples_per_buffer]f32 {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == 0)
                return null;

            const head_index = self.head;
            std.debug.assert(head_index < buffer_count);

            self.used[head_index] = 0;
            self.head = @mod(self.head + 1, buffer_count);
            self.len -= 1;
            return &self.buffers[head_index];
        }
    };
}

pub fn calculateHammingWindowTable(comptime freq_bin_count: comptime_int) [freq_bin_count]f32 {
    comptime {
        var i: comptime_int = 0;
        var result: [freq_bin_count]f32 = undefined;
        while (i < freq_bin_count) : (i += 1) {
            // 0.54 - 0.46cos(2pi*n/(N-1))
            result[i] = 0.54 - (0.46 * @cos((2 * std.math.pi * i) / @as(f32, freq_bin_count - 1)));
        }
        return result;
    }
}

pub fn calculateHanningWindowTable(comptime freq_bin_count: comptime_int) [freq_bin_count]f32 {
    comptime {
        var i: comptime_int = 0;
        var result: [freq_bin_count]f32 = undefined;
        while (i < freq_bin_count) : (i += 1) {
            // 0.50 - 0.50cos(2pi*n/(N-1))
            result[i] = 0.50 - (0.50 * @cos((2 * std.math.pi * i) / @as(f32, freq_bin_count - 1)));
        }
        return result;
    }
}

pub fn melScale(freq_band: f32) f32 {
    return 2595 * std.math.log10(1.0 + (freq_band / 700));
}

pub fn generateMelTable(
    comptime bin_count: comptime_int,
    comptime frequency_resolution: comptime_float,
) [bin_count]f32 {
    var result: [bin_count]f32 = undefined;
    var i: usize = 0;
    while (i < bin_count) : (i += 1) {
        result[i] = melScale(frequency_resolution * (@intToFloat(f32, i) + 1));
    }
    return result;
}

pub fn calculateFreqToMelTable(
    comptime bin_count: comptime_int,
    comptime frequency_resolution: comptime_float,
) [bin_count]f32 {
    return comptime blk: {
        @setEvalBranchQuota(bin_count * bin_count);
        const mel_upper: f32 = melScale(frequency_resolution * bin_count);
        var result = [1]f32{0.0} ** bin_count;
        const mel_increment = mel_upper / bin_count;
        var freq_i: usize = 0;
        outer: while (freq_i < bin_count) : (freq_i += 1) {
            const freq = @intToFloat(f32, freq_i) * frequency_resolution;
            const freq_in_mel: f32 = melScale(freq);
            var lower_mel: f32 = 0;
            var upper_mel: f32 = mel_increment;
            var mel_bin_index: usize = 0;
            while (mel_bin_index < bin_count) : (mel_bin_index += 1) {
                if (freq_in_mel >= lower_mel and freq_in_mel < upper_mel) {
                    const fraction: f32 = (freq_in_mel - lower_mel) / mel_increment;
                    std.debug.assert(fraction >= 0.0);
                    std.debug.assert(fraction <= 1.0);
                    result[freq_i] = @intToFloat(f32, mel_bin_index) + fraction;
                    continue :outer;
                }
                lower_mel += mel_increment;
                upper_mel += mel_increment;
            }
            unreachable;
        }
        break :blk result;
    };
}
