// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const zmath = @import("zmath");
const audio_input = @import("../../audio.zig");

pub var unity_table: [256]zmath.F32x4 = undefined;
const fft_bin_count = 256;

var mel_bin_buffer: [128]f32 = undefined;
const sample_rate = 44100;
const freq_resolution: f32 = sample_rate / fft_bin_count;
const freq_to_mel_table = audio_input.calculateFreqToMelTable(fft_bin_count / 2, freq_resolution);

const FilterMap = struct {
    index: usize,
    weight: f32,
};

// Takes a point and distributes it linearly-ish across 5 bins
fn triangleFilter(point: f32, filter_map_buffer: *[5]FilterMap) []FilterMap {
    const point_whole = @floatToInt(u32, @floor(point));
    const offset = (@rem(point, 1.0) - 0.5) / 10;
    std.debug.assert(offset >= -0.10);
    std.debug.assert(offset <= 0.10);
    const index_first = @intCast(u32, @max(0, @intCast(i64, point_whole) - 2));
    const index_last: u32 = @min((fft_bin_count / 2) - 1, point_whole + 2);
    const range: u32 = index_last - index_first;
    if (range < 4) {
        filter_map_buffer[0] = .{
            .index = @intCast(usize, point_whole),
            .weight = 1.0,
        };
        return filter_map_buffer[0..1];
    }
    filter_map_buffer.* = [5]FilterMap{
        .{ .index = point_whole - 2, .weight = 0.05 - offset },
        .{ .index = point_whole - 1, .weight = 0.20 - offset },
        .{ .index = point_whole, .weight = 0.50 },
        .{ .index = point_whole + 1, .weight = 0.20 + offset },
        .{ .index = point_whole + 2, .weight = 0.05 + offset },
    };
    return filter_map_buffer[0..5];
}

const reference_max_audio: f32 = 128.0 * 4.0;

pub fn powerSpectrumToVolumeDb(power_spectrum: [fft_bin_count / 8]zmath.F32x4) f32 {
    var accumulator: zmath.F32x4 = .{ 0, 0, 0, 0 };
    for(power_spectrum) |values| {
        accumulator += values;
    }
    const total_power = (accumulator[0] + accumulator[1] + accumulator[2] + accumulator[3]);
    const average_power = total_power / (@intToFloat(f32, power_spectrum.len) * 4);
    return std.math.log10(average_power / reference_max_audio);
}

pub fn powerSpectrumToMelScale(power_spectrum: [fft_bin_count / 8]zmath.F32x4, output_bin_count: u32) []f32 {

    const usable_bin_count = power_spectrum.len * 4;
    var mel_bins = [1]f32{ 0.00000000001} ** usable_bin_count;

    var i: usize = 1;
    while (i < usable_bin_count) : (i += 1) {
        const array_i = @divTrunc(i, 4);
        std.debug.assert(array_i <= 31);
        const sub_i = i % 4;
        std.debug.assert(power_spectrum[array_i][sub_i] >= 0.0);
        const power_value = power_spectrum[array_i][sub_i];
        const freq_to_mel = freq_to_mel_table[i];
        var filter_map_buffer: [5]FilterMap = undefined;
        for (triangleFilter(freq_to_mel, &filter_map_buffer)) |filter_map| {
            mel_bins[filter_map.index] += filter_map.weight * power_value;
        }
    }

    var merged_bins = mel_bin_buffer[0..output_bin_count];

    const audio_bin_compress_count = @divExact(@divExact(fft_bin_count, 2), output_bin_count);
    // var decibel_accumulator: f32 = 0;
    var mel_bin_index: usize = 0;
    i = 0;
    while (i < output_bin_count) : (i += 1) {
        var x: usize = 0;
        merged_bins[i] = 0;
        while (x < audio_bin_compress_count) : (x += 1) {
            merged_bins[i] += mel_bins[mel_bin_index + x];
        }
        merged_bins[i] /= @intToFloat(f32, audio_bin_compress_count);
        merged_bins[i] = std.math.log10(merged_bins[i] / reference_max_audio);
        // decibel_accumulator += merged_bins[i];
        mel_bin_index += audio_bin_compress_count;
    }

    return merged_bins;

    // decibel_accumulator /= @intToFloat(f32, output_bin_count);
}

const hamming_table = audio_input.calculateHammingWindowTable(fft_bin_count);

pub fn samplesToPowerSpectrum(pcm_buffer: []i16) [fft_bin_count / 8]zmath.F32x4 {
    // audio_power_table_mutex.lock();
    // defer audio_power_table_mutex.unlock();

    // const fft_buffer: [fft_bin_count / 2]f32 = undefined;

    const fft_overlap_samples = @divExact(fft_bin_count, 2);
    const fft_iteration_count = ((pcm_buffer.len / 2) / (fft_overlap_samples - 1)) - 1;

    var power_spectrum = [1]zmath.F32x4{zmath.f32x4(0.0, 0.0, 0.0, 0.0)} ** (fft_bin_count / 8);

    // if (stream_state == .record or stream_state == .record_preview)
    //     audio_sample_ring_buffer.push(pcm_buffer) catch unreachable;

    var i: usize = 0;
    while (i < fft_iteration_count) : (i += 1) {
        const vector_len: usize = @divExact(fft_bin_count, 4);
        var complex = [1]zmath.F32x4{zmath.f32x4s(0.0)} ** vector_len;

        var fft_window = blk: {
            // TODO: Don't hardcode channel count
            const channel_count = 2;
            var result = [1]zmath.F32x4{zmath.f32x4(0.0, 0.0, 0.0, 0.0)} ** (@divExact(fft_bin_count, 4));
            const sample_increment = fft_overlap_samples * channel_count;
            const start = sample_increment * i;
            const end = start + (fft_bin_count * channel_count);
            const pcm_window = pcm_buffer[start..end];
            std.debug.assert(pcm_window.len == (hamming_table.len * channel_count));
            std.debug.assert(pcm_window.len % 4 == 0);
            var k: usize = 0;
            var j: usize = 0;
            for (&result) |*sample| {
                const max = std.math.maxInt(i16);
                // TODO: The indexing here is dependent on the channel count
                sample.* = .{
                    ((@intToFloat(f32, pcm_window[j + 0])) / max) * hamming_table[k + 0],
                    ((@intToFloat(f32, pcm_window[j + 2])) / max) * hamming_table[k + 1],
                    ((@intToFloat(f32, pcm_window[j + 4])) / max) * hamming_table[k + 2],
                    ((@intToFloat(f32, pcm_window[j + 6])) / max) * hamming_table[k + 3],
                };
                j += 8;
                k += 4;
            }
            break :blk result;
        };

        zmath.fft(&fft_window, &complex, &unity_table);

        for (&power_spectrum, 0..) |*value, v| {
            const complex2 = complex[v] * complex[v];
            // const real2 = fft_window[v] * fft_window[v];
            // const magnitude = zmath.sqrt(complex2 + real2);
            const magnitude = zmath.sqrt(complex2);
            value.* += magnitude;
        }
    }
    for (&power_spectrum) |*value| {
        std.debug.assert(value.*[0] >= 0.0);
        std.debug.assert(value.*[1] >= 0.0);
        std.debug.assert(value.*[2] >= 0.0);
        std.debug.assert(value.*[3] >= 0.0);
        value.* /= zmath.f32x4s(@intToFloat(f32, fft_iteration_count));
        std.debug.assert(value.*[0] >= 0.0);
        std.debug.assert(value.*[1] >= 0.0);
        std.debug.assert(value.*[2] >= 0.0);
        std.debug.assert(value.*[3] >= 0.0);
    }

    return power_spectrum;
}