// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const assert = std.debug.assert;
const dbus = @import("../../bindings/dbus/dbus.zig");

const graphics = @import("../../graphics.zig");
const screencapture = @import("../../screencapture.zig");

// TODO: Remove
const c = @cImport({
    @cInclude("dbus/dbus.h");
    @cInclude("string.h");
    @cInclude("fcntl.h");
});

const pw = @cImport({
    @cInclude("spa/param/video/format-utils.h");
    @cInclude("spa/param/video/type-info.h");
    @cInclude("pipewire/pipewire.h");
});

//
// These functions come from pipewire_stream_extra.c
//
extern fn parseStreamFormat(params: [*c]const pw.spa_pod) callconv(.C) StreamFormat;
extern fn buildPipewireParams(builder: *pw.spa_pod_builder) callconv(.C) *pw.spa_pod;

const session_handle_chars_max = 256;
var session_handle_buffer: [session_handle_chars_max]u8 = undefined;

const bus_name = "org.freedesktop.portal.Desktop";
const object_path = "/org/freedesktop/portal/desktop";
const interface_name = "org.freedesktop.portal.ScreenCast";
const screenshot_interface_name = "org.freedesktop.portal.Screenshot";

pub const InitErrorSet = error{
    OutOfMemory,
    DBusOutOfMemory,
    CreateThreadFail,
};

const SourceTypeFlags = packed struct(u32) {
    monitor: bool = false,
    window: bool = false,
    virtual: bool = false,
    reserved: u29 = 0,
};

const PersistMode = enum(u32) {
    default,
    application,
    until_revoked,
};

const CursorModeFlags = packed struct(u32) {
    hidden: bool = false,
    embedded: bool = false,
    metadata: bool = false,
    reserved: u29 = 0,
};

const StartResponse = struct {
    pipewire_node_id: u32,
    id: [*:0]const u8,
    position: [2]i32,
    dimensions: [2]i32,
    source_type: u32,
    restore_token: ?[]const u8,
};

const SupportedPixelFormat = screencapture.SupportedPixelFormat;

const StreamFormat = extern struct {
    format: SupportedPixelFormat,
    width: u32,
    height: u32,
    padding: u32,
};

const stream_events = pw.pw_stream_events{
    .version = pw.PW_VERSION_STREAM_EVENTS,
    .state_changed = onStateChangedCallback,
    .param_changed = onParamChangedCallback,
    .process = onProcessCallback,
    .io_changed = null,
    .add_buffer = null,
    .remove_buffer = null,
    .drained = null,
    .command = null,
    .trigger_done = null,
    .destroy = null,
    .control_info = null,
};

const Stream = struct {
    const null_handle: screencapture.StreamHandle = std.math.maxInt(u16);

    handle: screencapture.StreamHandle,
    state: screencapture.StreamState,
    stream: *pw.pw_stream,
    thread_loop: *pw.pw_thread_loop,
    format: StreamFormat,

    pub fn deinit(self: *@This()) void {
        pw.pw_thread_loop_lock(self.thread_loop);
        _ = pw.pw_stream_disconnect(self.stream);
        pw.pw_stream_destroy(self.stream);
        pw.pw_thread_loop_unlock(self.thread_loop);
        pw.pw_thread_loop_stop(self.thread_loop);
        pw.pw_thread_loop_destroy(self.thread_loop);
        self.state = .uninitialized;
        self.handle = Stream.null_handle;
    }
};

const null_stream = Stream{
    .handle = Stream.null_handle,
    .state = .uninitialized,
    .stream = undefined,
    .thread_loop = undefined,
    .format = undefined,
};

const max_stream_count = 16;
var stream_buffer = [1]Stream{null_stream} ** max_stream_count;

var backend_stream: screencapture.State = .uninitialized;

pub var frameReadyCallback: *const screencapture.OnFrameReadyFn = undefined;

var stream_listener: pw.spa_hook = undefined;
var server_version_sync: i32 = undefined;

var request_count: u32 = 0;
var session_count: u32 = 0;

var next_stream_handle: u16 = 0;

pub fn newStream() *Stream {
    inline for (&stream_buffer) |*stream| {
        if (stream.handle == Stream.null_handle) {
            stream.*.handle = next_stream_handle;
            next_stream_handle += 1;
            return stream;
        }
    }
    unreachable;
}

pub inline fn streamFromHandle(stream_handle: u32) *Stream {
    inline for (&stream_buffer) |*stream| {
        if (stream.handle == stream_handle)
            return stream;
    }
    std.log.err("screencapture(pipewire): stream_handle {d} is not valid", .{stream_handle});
    unreachable;
}

var onStreamOpenSuccessCallback: *const screencapture.OpenStreamOnSuccessFn = undefined;

pub fn createInterface() screencapture.Interface {
    return .{
        .init = _init,
        .deinit = deinit,
        .openStream = openStream,
        .screenshot = screenshot,
        .queryStreams = queryStreams,
        .streamInfo = streamInfo,
        .streamPause = streamPause,
        .streamState = streamState,
        .streamClose = streamClose,
        .info = .{ .name = "pipewire", .query_streams = false },
    };
}

fn queryStreams(allocator: std.mem.Allocator) []StreamInfo {
    _ = allocator;
    assert(false);
    return &.{};
}

pub fn deinit() void {
    if (backend_stream == .active)
        teardownPipewire();
}

pub fn _init(successCallback: *const screencapture.InitOnSuccessFn, _: *const screencapture.InitOnErrorFn) void {
    successCallback();
}

const StreamHandle = screencapture.StreamHandle;
const StreamState = screencapture.StreamState;
const StreamInfo = screencapture.StreamInfo;

fn streamInfo(stream_handle: StreamHandle) StreamInfo {
    const stream_ptr: *const Stream = streamFromHandle(stream_handle);
    const stream_format = stream_ptr.format;
    return .{
        .name = "unknown",
        .dimensions = .{ .width = stream_format.width, .height = stream_format.height },
        .pixel_format = stream_format.format,
    };
}

fn streamPause(self: StreamHandle, is_paused: bool) void {
    _ = self;
    _ = is_paused;
}

fn streamState(stream_handle: StreamHandle) StreamState {
    return streamFromHandle(stream_handle).state;
}

fn streamClose(stream_handle: StreamHandle) void {
    streamFromHandle(stream_handle).deinit();
}

pub fn openStream(
    stream_index: ?u16,
    onFrameReadyCallback: *const screencapture.OnFrameReadyFn,
    successCallback: *const screencapture.OpenStreamOnSuccessFn,
    failCallback: *const screencapture.OpenStreamOnErrorFn,
    user_data: *anyopaque,
) void {
    _ = stream_index;
    frameReadyCallback = onFrameReadyCallback;
    onStreamOpenSuccessCallback = successCallback;
    init() catch failCallback(user_data);
}

pub fn detectSupport() bool {
    var err: dbus.Error = undefined;
    dbus.errorInit(&err);
    var connection: *dbus.Connection = dbus.busGet(dbus.BusType.session, &err);
    if (dbus.errorIsSet(&err) != 0) {
        return false;
    }
    const source_mode_flags = getProperty(u32, connection, "AvailableSourceTypes") catch return false;
    return (@bitCast(SourceTypeFlags, source_mode_flags).monitor == true);
}

//
// See: https://flatpak.github.io/xdg-desktop-portal/#gdbus-org.freedesktop.portal.Screenshot
//
pub fn screenshot(onSuccess: *const screencapture.OnScreenshotReadyFn, onFail: *const screencapture.OnScreenshotFailFn) void {
    const file_path = takeScreenshotPipewire() catch |err| {
        std.log.err("Failed to take screenshot. Error: {}", .{err});
        onFail("Unknown");
        return;
    };

    onSuccess(.{ .file_path_c = file_path });
}

fn takeScreenshotPipewire() ![*:0]const u8 {
    std.log.info("pipewire: Taking screenshot", .{});

    var err: dbus.Error = undefined;
    dbus.errorInit(&err);

    var connection: *dbus.Connection = dbus.busGet(dbus.BusType.session, &err);

    const connection_name_max_size = 16;
    const connection_name: []const u8 = blk: {
        const raw_name = dbus.busGetUniqueName(connection);
        const raw_name_len = std.mem.len(raw_name);
        if (raw_name_len == 0) {
            std.log.err("dbus_client: Connection name is empty", .{});
            return error.InvalidConnectionName;
        }
        if (raw_name[0] != ':') {
            std.log.err("dbus_client: Connection name not in expected format ':num.num'. Given: {s}", .{
                raw_name,
            });
            return error.InvalidConnectionName;
        }
        break :blk raw_name[1..raw_name_len];
    };
    if (connection_name.len >= connection_name_max_size) {
        std.log.err("dbus_client: Connection name '{s}' exceeds maximum size of {d}", .{
            connection_name,
            connection_name_max_size,
        });
        return error.ConnectionNameTooLarge;
    }

    var portal_connection_name_buffer: [connection_name_max_size]u8 = undefined;
    const portal_connection_name: []const u8 = blk: {
        var i: usize = 0;
        while (i < connection_name.len) : (i += 1) {
            if (connection_name[i] == '.') {
                portal_connection_name_buffer[i] = '_';
                continue;
            }
            portal_connection_name_buffer[i] = connection_name[i];
        }
        portal_connection_name_buffer[connection_name.len] = '0';
        break :blk portal_connection_name_buffer[0..connection_name.len];
    };

    var request_suffix_buffer: [64]u8 = undefined;
    const screenshot_request_suffix = try generateRequestToken(&request_suffix_buffer);

    const handle_token_option_label: [*:0]const u8 = "handle_token";
    var match_buffer: [128]u8 = undefined;

    var screenshot_match_rule: [*:0]const u8 = undefined;
    {
        screenshot_match_rule = try std.fmt.bufPrintZ(
            &match_buffer,
            "type='signal',interface='org.freedesktop.portal.Request',path='/org/freedesktop/portal/desktop/request/{s}/{s}'",
            .{
                portal_connection_name,
                screenshot_request_suffix,
            },
        );
        dbus.busAddMatch(connection, screenshot_match_rule, null);
        dbus.connectionFlush(connection);
    }

    var request: *dbus.Message = dbus.messageNewMethodCall(
        bus_name,
        object_path,
        screenshot_interface_name,
        "Screenshot",
    ) orelse {
        std.log.err("dbus_client: dbus_message_new_method_call failed. (DBus out of memory)", .{});
        return error.DBusOutOfMemory;
    };

    //
    // Since we're not a wayland or X11 window, pass an empty string and the parent
    // window ID will be used.
    // src: https://flatpak.github.io/xdg-desktop-portal/#parent_window
    //
    const parent_window: [*:0]const u8 = "";

    if (dbus.messageAppendArgs(
        request,
        c.DBUS_TYPE_STRING,
        &parent_window,
        c.DBUS_TYPE_INVALID,
    ) != 1)
        return error.WriteRequestFail;

    var root_iter: dbus.MessageIter = undefined;
    dbus.messageIterInitAppend(request, &root_iter);

    const signature = [4:0]u8{
        c.DBUS_DICT_ENTRY_BEGIN_CHAR,
        c.DBUS_TYPE_STRING,
        c.DBUS_TYPE_VARIANT,
        c.DBUS_DICT_ENTRY_END_CHAR,
    };
    var array_iter: dbus.MessageIter = undefined;
    if (dbus.messageIterOpenContainer(&root_iter, c.DBUS_TYPE_ARRAY, &signature, &array_iter) != 1)
        return error.WriteDictFail;

    var request_buffer: [64]u8 = undefined;
    const request_id = try generateRequestToken(request_buffer[0..]);

    //
    // Open Dict Entry [0] - handle_token s
    //
    {
        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &handle_token_option_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "s", &dict_variant_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &request_id)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Open Dict Entry [1] - modal b
    //
    {
        const option_types_label: [*:0]const u8 = "modal";

        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &option_types_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "b", &dict_variant_iter) != 1)
            return error.WriteDictFail;

        const display_model: u32 = 0;
        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_BOOLEAN, @ptrCast(*const void, &display_model)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Open Dict Entry [2] - interactive b
    //
    {
        const option_types_label: [*:0]const u8 = "interactive";

        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &option_types_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "b", &dict_variant_iter) != 1)
            return error.WriteDictFail;

        const display_interactive: u32 = 0;
        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_BOOLEAN, @ptrCast(*const void, &display_interactive)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Close Array
    //
    if (dbus.messageIterCloseContainer(&root_iter, &array_iter) != 1)
        return error.CloseContainerFail;

    //
    // Send over the Bus and block on response
    //
    var response_handle: *dbus.Message = dbus.connectionSendWithReplyAndBlock(
        connection,
        request,
        std.time.ms_per_s * 1,
        &err,
    ) orelse {
        const error_message = if (dbus.errorIsSet(&err) != 0) err.message else "unknown";
        std.log.err("dbus_client: dbus.connectionSendWithReplyAndBlock( failed. Error: {s}", .{
            error_message,
        });
        return error.SendAndAwaitMessageFail;
    };
    defer dbus.messageUnref(response_handle);

    var reply_iter: dbus.MessageIter = undefined;
    _ = dbus.messageIterInit(response_handle, &reply_iter);

    if (dbus.messageIterGetArgType(&reply_iter) != c.DBUS_TYPE_OBJECT_PATH) {
        return error.ReplyInvalidType;
    }

    var response_uri: [*:0]const u8 = undefined;
    dbus.messageIterGetBasic(&reply_iter, @ptrCast(*void, &response_uri));

    const screenshot_response: *dbus.Message = blk: {
        const timeout_duration_seconds = 60;
        const iterations_max: u32 = 1000 * timeout_duration_seconds;
        const timeout_ms = 10;
        var i: u32 = 0;
        while (i < iterations_max) : (i += 1) {
            if (dbus.connectionReadWrite(connection, timeout_ms) != 1)
                continue;

            const response = dbus.connectionPopMessage(connection) orelse continue;
            const is_match = (1 == dbus.messageIsSignal(
                response,
                "org.freedesktop.portal.Request",
                "Response",
            ));

            if (is_match)
                break :blk response;

            //
            // Only unref if we haven't matched. If we do match we want to return from block
            // and unref after we've processed the response payload
            //
            dbus.messageUnref(response);
        }

        std.log.err("dbus_client: Failed to poll response to Screenshot message", .{});
        return error.PollResponseFail;
    };

    dbus.busRemoveMatch(connection, screenshot_match_rule, null);

    var file_uri: [*:0]const u8 = "";
    {
        var screenshot_response_iter: dbus.MessageIter = undefined;
        _ = dbus.messageIterInit(screenshot_response, &screenshot_response_iter);

        if (dbus.messageIterGetArgType(&screenshot_response_iter) != c.DBUS_TYPE_UINT32) {
            return error.ReplyInvalidType;
        }
        var success_code: u32 = std.math.maxInt(u32);
        dbus.messageIterGetBasic(&screenshot_response_iter, @ptrCast(*void, &success_code));

        if (success_code != 0) {
            std.log.err("dbus_client: SelectSources response message returned error code {d}", .{
                success_code,
            });
            return error.SelectSourcesFail;
        }

        if (dbus.messageIterNext(&screenshot_response_iter) != 1) {
            return error.InvalidResponse;
        }

        var next_type: i32 = dbus.messageIterGetArgType(&screenshot_response_iter);
        assert(next_type == c.DBUS_TYPE_ARRAY);

        var root_array_iter: dbus.MessageIter = undefined;
        dbus.messageIterRecurse(&screenshot_response_iter, &root_array_iter);

        next_type = dbus.messageIterGetArgType(&root_array_iter);
        assert(next_type == c.DBUS_TYPE_DICT_ENTRY);

        var root_dict_iter: dbus.MessageIter = undefined;
        dbus.messageIterRecurse(&root_array_iter, &root_dict_iter);

        next_type = dbus.messageIterGetArgType(&root_dict_iter);
        assert(next_type == c.DBUS_TYPE_STRING);

        var arg_label: [*:0]const u8 = undefined;
        dbus.messageIterGetBasic(&root_dict_iter, @ptrCast(*void, &arg_label));

        const expected_label = "uri";
        for (expected_label, 0..) |char, char_i| {
            if (char != arg_label[char_i])
                return error.InvalidResponse;
        }

        _ = dbus.messageIterNext(&root_dict_iter);
        next_type = dbus.messageIterGetArgType(&root_dict_iter);
        assert(next_type == c.DBUS_TYPE_VARIANT);

        var variant_iter: dbus.MessageIter = undefined;
        dbus.messageIterRecurse(&root_dict_iter, &variant_iter);
        next_type = dbus.messageIterGetArgType(&variant_iter);

        assert(next_type == c.DBUS_TYPE_STRING);

        dbus.messageIterGetBasic(&variant_iter, @ptrCast(*void, &file_uri));
    }

    // TODO: Do I have to deinit the message?

    return file_uri;
}

pub fn state() screencapture.State {
    return backend_stream;
}

//
// Private Interface
//

fn generateRequestToken(buffer: []u8) ![*:0]const u8 {
    defer request_count += 1;
    return try std.fmt.bufPrintZ(buffer, "reel{d}", .{request_count});
}

fn generateSessionToken(buffer: []u8) ![*:0]const u8 {
    defer session_count += 1;
    return try std.fmt.bufPrintZ(buffer, "reel{d}", .{session_count});
}

pub fn getProperty(
    comptime T: type,
    connection: *dbus.Connection,
    property_name: [*:0]const u8,
) !T {
    var err: dbus.Error = undefined;
    dbus.errorInit(&err);

    var query_message: *dbus.Message = dbus.messageNewMethodCall(
        bus_name,
        object_path,
        "org.freedesktop.DBus.Properties",
        "Get",
    ) orelse {
        std.log.err("dbus_client: dbus_message_new_method_call failed. (DBus out of memory)", .{});
        return error.DBusOutOfMemory;
    };

    _ = dbus.messageAppendArgs(
        query_message,
        c.DBUS_TYPE_STRING,
        &interface_name,
        c.DBUS_TYPE_STRING,
        &property_name,
        c.DBUS_TYPE_INVALID,
    );
    var reply_message: *dbus.Message = dbus.connectionSendWithReplyAndBlock(
        connection,
        query_message,
        std.time.ms_per_s * 1,
        &err,
    ) orelse {
        const error_message = if (dbus.errorIsSet(&err) != 0) err.message else "unknown";
        std.log.err("dbus_client: dbus.connectionSendWithReplyAndBlock failed. Error: {s}", .{
            error_message,
        });
        return error.SendAndAwaitMessageFail;
    };
    dbus.messageUnref(query_message);

    //
    // Extract value from variant
    //

    var iter: dbus.MessageIter = undefined;
    var sub: dbus.MessageIter = undefined;

    _ = dbus.messageIterInit(reply_message, &iter);

    if (dbus.messageIterGetArgType(&iter) != c.DBUS_TYPE_VARIANT) {
        return error.NotAVariant;
    }

    dbus.messageIterRecurse(&iter, &sub);
    if (dbus.messageIterGetArgType(&sub) != c.DBUS_TYPE_UINT32) {
        return error.TypeNotUint32;
    }

    var result: T = undefined;
    dbus.messageIterGetBasic(&sub, @ptrCast(*void, &result));
    dbus.messageUnref(reply_message);

    return result;
}

fn addSignalMatch(
    connection: *dbus.Connection,
) void {
    //
    // NOTE: Passing in null for the error, means we have to flush the connection to make sure
    //       the rule is applied
    //
    dbus.busAddMatch(connection, "type='signal',interface='org.freedesktop.portal.Request'", null);
    //
    // TODO: Move this somewhere else
    //
    dbus.connectionFlush(connection);
}

fn pollForResponse(
    connection: *dbus.Connection,
) ![*:0]const u8 {
    const iterations_max: u32 = 1000;
    var i: u32 = 0;
    while (i < iterations_max) : (i += 1) {
        if (dbus.connectionReadWrite(connection, 10) != 1)
            return error.ConnectionReadWriteFail;

        const message = dbus.connectionPopMessage(connection) orelse continue;

        defer dbus.messageUnref(message);

        const is_match = 1 == dbus.messageIsSignal(
            message,
            "org.freedesktop.portal.Request",
            "Response",
        );

        if (!is_match)
            continue;

        //
        // Read the response
        //
        var reply_iter: dbus.MessageIter = undefined;
        _ = dbus.messageIterInit(message, &reply_iter);

        if (dbus.messageIterGetArgType(&reply_iter) != c.DBUS_TYPE_UINT32) {
            return error.ReplyInvalidType;
        }

        var response: u32 = std.math.maxInt(u32);
        dbus.messageIterGetBasic(&reply_iter, @ptrCast(*void, &response));

        if (dbus.messageIterNext(&reply_iter) != 1)
            return error.InvalidResponse;
        if (dbus.messageIterGetArgType(&reply_iter) != c.DBUS_TYPE_ARRAY) {
            return error.ReplyInvalidType;
        }

        var array_iter: dbus.MessageIter = undefined;
        dbus.messageIterRecurse(&reply_iter, &array_iter);
        if (dbus.messageIterGetArgType(&array_iter) != c.DBUS_TYPE_DICT_ENTRY) {
            return error.InvalidResponse;
        }

        var dict_entry_iter: dbus.MessageIter = undefined;
        dbus.messageIterRecurse(&array_iter, &dict_entry_iter);
        if (dbus.messageIterGetArgType(&dict_entry_iter) != c.DBUS_TYPE_STRING) {
            return error.InvalidResponse;
        }

        var session_handle_label: [*:0]const u8 = undefined;
        dbus.messageIterGetBasic(&dict_entry_iter, @ptrCast(*void, &session_handle_label));

        const equal = blk: {
            var k: usize = 0;
            const expected: [*:0]const u8 = "session_handle";
            while (k < comptime std.mem.len(expected)) : (k += 1) {
                if (expected[k] != session_handle_label[k])
                    break :blk false;
            }
            break :blk true;
        };

        if (!equal)
            return error.InvalidKey;

        if (dbus.messageIterNext(&dict_entry_iter) != 1)
            return error.InvalidResponse;
        if (dbus.messageIterGetArgType(&dict_entry_iter) != c.DBUS_TYPE_VARIANT) {
            return error.ReplyInvalidType;
        }

        var variant_iter: dbus.MessageIter = undefined;
        dbus.messageIterRecurse(&dict_entry_iter, &variant_iter);
        if (dbus.messageIterGetArgType(&variant_iter) != c.DBUS_TYPE_STRING) {
            return error.InvalidResponse;
        }

        var session_handle: [*:0]const u8 = undefined;
        dbus.messageIterGetBasic(&variant_iter, @ptrCast(*void, &session_handle));

        //
        // TODO: You probably need to dupe the strings
        //
        return session_handle;
    }
    return error.TimedOut;
}

fn createSession(
    connection: *dbus.Connection,
) ![*:0]const u8 {
    var err: dbus.Error = undefined;
    dbus.errorInit(&err);

    var query_message: *dbus.Message = dbus.messageNewMethodCall(
        bus_name,
        object_path,
        interface_name,
        "CreateSession",
    ) orelse {
        std.log.err("dbus_client: dbus_message_new_method_call failed. (DBus out of memory)", .{});
        return error.DBusOutOfMemory;
    };

    defer dbus.messageUnref(query_message);

    var request_buffer: [64]u8 = undefined;
    var session_buffer: [64]u8 = undefined;
    const request_id = try generateRequestToken(request_buffer[0..]);
    const session_id = try generateSessionToken(session_buffer[0..]);

    var root_iter: dbus.MessageIter = undefined;
    dbus.messageIterInitAppend(query_message, &root_iter);

    const signature = [4:0]u8{
        c.DBUS_DICT_ENTRY_BEGIN_CHAR,
        c.DBUS_TYPE_STRING,
        c.DBUS_TYPE_VARIANT,
        c.DBUS_DICT_ENTRY_END_CHAR,
    };
    assert(signature[4] == 0);
    var array_iter: dbus.MessageIter = undefined;
    if (dbus.messageIterOpenContainer(&root_iter, c.DBUS_TYPE_ARRAY, &signature, &array_iter) != 1)
        return error.WriteDictFail;

    const handle_token_option_label: [*:0]const u8 = "handle_token";
    const session_handle_token_option_label: [*:0]const u8 = "session_handle_token";

    //
    // Open Dict Entry [0] - handle_token s
    //
    {
        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &handle_token_option_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "s", &dict_variant_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &request_id)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Open Dict Entry [1] - session_handle_token s
    //
    {
        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.OpenContainerFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &session_handle_token_option_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "s", &dict_variant_iter) != 1)
            return error.OpenContainerFail;

        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &session_id)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Close Array
    //
    if (dbus.messageIterCloseContainer(&root_iter, &array_iter) != 1)
        return error.CloseContainerFail;

    //
    // Send over the Bus and block on response
    //
    var reply_message: *dbus.Message = dbus.connectionSendWithReplyAndBlock(
        connection,
        query_message,
        std.time.ms_per_s * 1,
        &err,
    ) orelse {
        const error_message = if (dbus.errorIsSet(&err) != 0) err.message else "unknown";
        std.log.err("dbus_client: dbus.connectionSendWithReplyAndBlock( failed. Error: {s}", .{
            error_message,
        });
        return error.SendAndAwaitMessageFail;
    };
    defer dbus.messageUnref(reply_message);

    //
    // Extract request handle from Reply
    //

    var reply_iter: dbus.MessageIter = undefined;
    _ = dbus.messageIterInit(reply_message, &reply_iter);

    if (dbus.messageIterGetArgType(&reply_iter) != c.DBUS_TYPE_OBJECT_PATH) {
        return error.ReplyInvalidType;
    }
    var create_session_request_path: [*:0]const u8 = undefined;
    dbus.messageIterGetBasic(&reply_iter, @ptrCast(*void, &create_session_request_path));

    return create_session_request_path;
}

fn closeSession(
    connection: *dbus.Connection,
    session: [*:0]const u8,
) !void {
    var err: dbus.Error = undefined;
    dbus.errorInit(&err);

    var query_message: *dbus.Message = dbus.messageNewMethodCall(
        bus_name,
        session,
        "org.freedesktop.portal.Request",
        "Close",
    ) orelse {
        std.log.err("dbus_client: dbus_message_new_method_call failed. (DBus out of memory)", .{});
        return error.DBusOutOfMemory;
    };

    defer dbus.messageUnref(query_message);

    //
    // Return is null
    //
    _ = dbus.connectionSendWithReplyAndBlock(
        connection,
        query_message,
        std.time.ms_per_s * 1,
        &err,
    );

    if (dbus.errorIsSet(&err) != 0) {
        std.log.err("CloseSession failed. Error: {s}", .{err.message});
        return error.CloseSessionFail;
    }
}

fn setSource(
    connection: *dbus.Connection,
    session_handle: [*:0]const u8,
    request_suffix: [*:0]const u8,
) ![*:0]const u8 {
    var err: dbus.Error = undefined;
    dbus.errorInit(&err);

    var request: *dbus.Message = dbus.messageNewMethodCall(
        bus_name,
        object_path,
        interface_name,
        "SelectSources",
    ) orelse {
        std.log.err("dbus_client: dbus_message_new_method_call failed. (DBus out of memory)", .{});
        return error.DBusOutOfMemory;
    };

    //
    // Write parameters
    //

    if (dbus.messageAppendArgs(
        request,
        c.DBUS_TYPE_OBJECT_PATH,
        &session_handle,
        c.DBUS_TYPE_INVALID,
    ) != 1)
        return error.WriteRequestFail;

    var root_iter: dbus.MessageIter = undefined;
    dbus.messageIterInitAppend(request, &root_iter);

    const signature = [4:0]u8{
        c.DBUS_DICT_ENTRY_BEGIN_CHAR,
        c.DBUS_TYPE_STRING,
        c.DBUS_TYPE_VARIANT,
        c.DBUS_DICT_ENTRY_END_CHAR,
    };
    assert(signature[4] == 0);
    var array_iter: dbus.MessageIter = undefined;
    if (dbus.messageIterOpenContainer(&root_iter, c.DBUS_TYPE_ARRAY, &signature, &array_iter) != 1)
        return error.WriteDictFail;

    //
    // Open Dict Entry [0] - handle_token s
    //
    {
        const option_handle_token_label: [*:0]const u8 = "handle_token";

        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &option_handle_token_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "s", &dict_variant_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &request_suffix)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Open Dict Entry [1] - types u
    //
    {
        const option_types_label: [*:0]const u8 = "types";

        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &option_types_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "u", &dict_variant_iter) != 1)
            return error.WriteDictFail;

        const content_types = @bitCast(u32, SourceTypeFlags{ .monitor = true });
        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_UINT32, @ptrCast(*const void, &content_types)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Open Dict Entry [2] - persist_mode u
    //
    {
        const option_types_label: [*:0]const u8 = "persist_mode";

        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &option_types_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "u", &dict_variant_iter) != 1)
            return error.WriteDictFail;

        const persist_mode: u32 = @intFromEnum(PersistMode.until_revoked);
        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_UINT32, @ptrCast(*const void, &persist_mode)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Open Dict Entry [3] - cursor_mode u
    //
    {
        const option_types_label: [*:0]const u8 = "cursor_mode";

        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &option_types_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "u", &dict_variant_iter) != 1)
            return error.WriteDictFail;

        const cursor_flags: u32 = @bitCast(u32, CursorModeFlags{ .embedded = true });
        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_UINT32, @ptrCast(*const void, &cursor_flags)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Open Dict Entry [4] - multiple b
    //
    {
        const option_types_label: [*:0]const u8 = "multiple";

        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &option_types_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "b", &dict_variant_iter) != 1)
            return error.WriteDictFail;

        const allow_multiple: bool = false;
        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_BOOLEAN, @ptrCast(*const void, &allow_multiple)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Close Array
    //
    if (dbus.messageIterCloseContainer(&root_iter, &array_iter) != 1)
        return error.CloseContainerFail;

    //
    // Send over the Bus and block on response
    //
    var response: *dbus.Message = dbus.connectionSendWithReplyAndBlock(
        connection,
        request,
        std.time.ms_per_s * 1,
        &err,
    ) orelse {
        const error_message = if (dbus.errorIsSet(&err) != 0) err.message else "unknown";
        std.log.err("dbus_client: dbus.connectionSendWithReplyAndBlock( failed. Error: {s}", .{
            error_message,
        });
        return error.SendAndAwaitMessageFail;
    };
    defer dbus.messageUnref(response);

    var reply_iter: dbus.MessageIter = undefined;
    _ = dbus.messageIterInit(response, &reply_iter);

    if (dbus.messageIterGetArgType(&reply_iter) != c.DBUS_TYPE_OBJECT_PATH) {
        return error.ReplyInvalidType;
    }
    var request_handle: [*:0]const u8 = undefined;
    dbus.messageIterGetBasic(&reply_iter, @ptrCast(*void, &request_handle));

    return request_handle;
}

fn startStream(
    connection: *dbus.Connection,
    session_handle: [*:0]const u8,
    request_suffix: [*:0]const u8,
) ![*:0]const u8 {
    var err: dbus.Error = undefined;
    dbus.errorInit(&err);

    var request: *dbus.Message = dbus.messageNewMethodCall(
        bus_name,
        object_path,
        interface_name,
        "Start",
    ) orelse {
        std.log.err("dbus_client: dbus_message_new_method_call failed. (DBus out of memory)", .{});
        return error.DBusOutOfMemory;
    };

    //
    // Since we're not a wayland or X11 window, pass an empty string and the parent
    // window ID will be used.
    // src: https://flatpak.github.io/xdg-desktop-portal/#parent_window
    //
    const parent_window: [*:0]const u8 = "";

    //
    // Write parameters
    //

    if (dbus.messageAppendArgs(
        request,
        c.DBUS_TYPE_OBJECT_PATH,
        &session_handle,
        c.DBUS_TYPE_STRING,
        &parent_window,
        c.DBUS_TYPE_INVALID,
    ) != 1)
        return error.WriteRequestFail;

    var root_iter: dbus.MessageIter = undefined;
    dbus.messageIterInitAppend(request, &root_iter);

    const signature = [4:0]u8{
        c.DBUS_DICT_ENTRY_BEGIN_CHAR,
        c.DBUS_TYPE_STRING,
        c.DBUS_TYPE_VARIANT,
        c.DBUS_DICT_ENTRY_END_CHAR,
    };
    var array_iter: dbus.MessageIter = undefined;
    if (dbus.messageIterOpenContainer(&root_iter, c.DBUS_TYPE_ARRAY, &signature, &array_iter) != 1)
        return error.WriteDictFail;

    //
    // Open Dict Entry [0] - handle_token s
    //
    {
        const option_handle_token_label: [*:0]const u8 = "handle_token";

        var dict_entry_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&array_iter, c.DBUS_TYPE_DICT_ENTRY, null, &dict_entry_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_entry_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &option_handle_token_label)) != 1)
            return error.AppendBasicFail;

        //
        // Because entry in Dict is a variant, we can't use append_basic and instead have to open yet another
        // container
        //
        var dict_variant_iter: dbus.MessageIter = undefined;
        if (dbus.messageIterOpenContainer(&dict_entry_iter, c.DBUS_TYPE_VARIANT, "s", &dict_variant_iter) != 1)
            return error.WriteDictFail;

        if (dbus.messageIterAppendBasic(&dict_variant_iter, c.DBUS_TYPE_STRING, @ptrCast(*const void, &request_suffix)) != 1)
            return error.AppendBasicFail;

        if (dbus.messageIterCloseContainer(&dict_entry_iter, &dict_variant_iter) != 1)
            return error.CloseContainerFail;

        //
        // Close Dict Entry
        //
        if (dbus.messageIterCloseContainer(&array_iter, &dict_entry_iter) != 1)
            return error.CloseContainerFail;
    }

    //
    // Close Array
    //
    if (dbus.messageIterCloseContainer(&root_iter, &array_iter) != 1)
        return error.CloseContainerFail;

    //
    // Send over the Bus and block on response
    //
    var response: *dbus.Message = dbus.connectionSendWithReplyAndBlock(
        connection,
        request,
        std.time.ms_per_s * 1,
        &err,
    ) orelse {
        const error_message = if (dbus.errorIsSet(&err) != 0) err.message else "unknown";
        std.log.err("dbus_client: dbus.connectionSendWithReplyAndBlock( failed. Error: {s}", .{
            error_message,
        });
        return error.SendAndAwaitMessageFail;
    };
    defer dbus.messageUnref(response);

    var reply_iter: dbus.MessageIter = undefined;
    _ = dbus.messageIterInit(response, &reply_iter);

    if (dbus.messageIterGetArgType(&reply_iter) != c.DBUS_TYPE_OBJECT_PATH) {
        return error.ReplyInvalidType;
    }

    var request_handle: [*:0]const u8 = undefined;
    dbus.messageIterGetBasic(&reply_iter, @ptrCast(*void, &request_handle));

    return request_handle;
}

fn openPipewireRemote(
    connection: *dbus.Connection,
    session_handle: [*:0]const u8,
) !i32 {
    var err: dbus.Error = undefined;
    dbus.errorInit(&err);

    var request: *dbus.Message = dbus.messageNewMethodCall(
        bus_name,
        object_path,
        interface_name,
        "OpenPipeWireRemote",
    ) orelse {
        std.log.err("dbus_client: dbus_message_new_method_call failed. (DBus out of memory)", .{});
        return error.DBusOutOfMemory;
    };

    //
    // Write parameters
    //

    if (dbus.messageAppendArgs(request, c.DBUS_TYPE_OBJECT_PATH, &session_handle, c.DBUS_TYPE_INVALID) != 1)
        return error.WriteRequestFail;

    //
    // There are no defined options to set, but we have to match the signature
    //
    var root_iter: dbus.MessageIter = undefined;
    dbus.messageIterInitAppend(request, &root_iter);

    const signature = [4:0]u8{
        c.DBUS_DICT_ENTRY_BEGIN_CHAR,
        c.DBUS_TYPE_STRING,
        c.DBUS_TYPE_VARIANT,
        c.DBUS_DICT_ENTRY_END_CHAR,
    };
    var array_iter: dbus.MessageIter = undefined;
    if (dbus.messageIterOpenContainer(&root_iter, c.DBUS_TYPE_ARRAY, &signature, &array_iter) != 1)
        return error.WriteDictFail;

    if (dbus.messageIterCloseContainer(&root_iter, &array_iter) != 1)
        return error.CloseContainerFail;

    //
    // Send over the Bus and block on response
    //
    var response: *dbus.Message = dbus.connectionSendWithReplyAndBlock(
        connection,
        request,
        std.time.ms_per_s * 1,
        &err,
    ) orelse {
        const error_message = if (dbus.errorIsSet(&err) != 0) err.message else "unknown";
        std.log.err("dbus_client: dbus.connectionSendWithReplyAndBlock( failed. Error: {s}", .{
            error_message,
        });
        return error.SendAndAwaitMessageFail;
    };
    defer dbus.messageUnref(response);

    var reply_iter: dbus.MessageIter = undefined;
    _ = dbus.messageIterInit(response, &reply_iter);

    if (dbus.messageIterGetArgType(&reply_iter) != c.DBUS_TYPE_UNIX_FD) {
        return error.ReplyInvalidType;
    }

    var pipewire_fd: i32 = undefined;
    dbus.messageIterGetBasic(&reply_iter, @ptrCast(*void, &pipewire_fd));

    return pipewire_fd;
}

pub fn init() !void {
    comptime {
        assert(c.DBUS_BUS_SESSION == @intFromEnum(dbus.BusType.session));
        assert(c.DBUS_BUS_SYSTEM == @intFromEnum(dbus.BusType.system));
        assert(c.DBUS_BUS_STARTER == @intFromEnum(dbus.BusType.starter));
    }

    const property_name = "AvailableCursorModes";
    _ = property_name;

    var err: dbus.Error = undefined;
    dbus.errorInit(&err);

    var connection: *dbus.Connection = dbus.busGet(dbus.BusType.session, &err);

    const connection_name_max_size = 16;
    const connection_name: []const u8 = blk: {
        const raw_name = dbus.busGetUniqueName(connection);
        const raw_name_len = std.mem.len(raw_name);
        if (raw_name_len == 0) {
            std.log.err("dbus_client: Connection name is empty", .{});
            return error.InvalidConnectionName;
        }
        if (raw_name[0] != ':') {
            std.log.err("dbus_client: Connection name not in expected format ':num.num'. Given: {s}", .{
                raw_name,
            });
            return error.InvalidConnectionName;
        }
        break :blk raw_name[1..raw_name_len];
    };
    if (connection_name.len >= connection_name_max_size) {
        std.log.err("dbus_client: Connection name '{s}' exceeds maximum size of {d}", .{
            connection_name,
            connection_name_max_size,
        });
        return error.ConnectionNameTooLarge;
    }

    var portal_connection_name_buffer: [connection_name_max_size]u8 = undefined;
    const portal_connection_name: []const u8 = blk: {
        var i: usize = 0;
        while (i < connection_name.len) : (i += 1) {
            if (connection_name[i] == '.') {
                portal_connection_name_buffer[i] = '_';
                continue;
            }
            portal_connection_name_buffer[i] = connection_name[i];
        }
        portal_connection_name_buffer[connection_name.len] = '0';
        break :blk portal_connection_name_buffer[0..connection_name.len];
    };

    //
    // Check support
    //
    // const cursor_flags = try getProperty(u32, connection, bus_name, object_path, interface_name, property_name);
    // _ = cursor_flags;
    // const source_mode_flags = try getProperty(u32, connection, bus_name, object_path, interface_name, "AvailableSourceTypes");
    // _ = source_mode_flags;

    addSignalMatch(connection);

    const create_session_request_path = try createSession(connection);
    _ = create_session_request_path;

    const session_handle_ref = try pollForResponse(connection);
    const session_handle_len = std.mem.indexOfSentinel(u8, 0, session_handle_ref);

    if (session_handle_len >= session_handle_chars_max) {
        std.log.err("Session handle '{s}' is too large. Maximum supported length {d} but value is {d}.", .{
            session_handle_ref,
            session_handle_chars_max,
            session_handle_len,
        });
        return error.SessionHandleExceedsBuffer;
    }

    @memcpy(
        session_handle_buffer[0..session_handle_len],
        session_handle_ref[0..session_handle_len],
    );
    const session_handle: [*:0]const u8 = session_handle_buffer[0..session_handle_len :0];
    assert(std.mem.indexOfSentinel(u8, 0, session_handle) == session_handle_len);

    var request_suffix_buffer: [64]u8 = undefined;
    const select_source_request_suffix = try generateRequestToken(&request_suffix_buffer);

    var match_buffer: [128]u8 = undefined;

    //
    // Before invoking SelectSource, we have to create a match for the signal that will be emitted once
    // the response is ready. Doing so afterwards means there will be a race condition to subscribe to
    // the signal before it's emitted
    //
    var select_source_match_rule: [*:0]const u8 = undefined;
    {
        select_source_match_rule = try std.fmt.bufPrintZ(
            &match_buffer,
            "type='signal',interface='org.freedesktop.portal.Request',path='/org/freedesktop/portal/desktop/request/{s}/{s}'",
            .{
                portal_connection_name,
                select_source_request_suffix,
            },
        );
        dbus.busAddMatch(connection, select_source_match_rule, null);
        dbus.connectionFlush(connection);
    }

    const select_source_request = try setSource(
        connection,
        session_handle,
        select_source_request_suffix,
    );

    //
    // Assert the returned Request path matches that we generated beforehand
    // If they don't match, our poll will be useless as DBus won't match the signal
    // TODO: Should this be a hard assert?
    //
    {
        const select_source_real_len = std.mem.len(select_source_request);
        var expected_buffer: [128]u8 = undefined;
        const select_source_expected = try std.fmt.bufPrintZ(
            &expected_buffer,
            "/org/freedesktop/portal/desktop/request/{s}/{s}",
            .{
                portal_connection_name,
                select_source_request_suffix,
            },
        );
        const select_source_expected_len = std.mem.len(select_source_request);
        assert(select_source_real_len == select_source_expected_len);
        const is_equal = blk: {
            var i: usize = 0;
            while (i < select_source_real_len) : (i += 1) {
                if (select_source_request[i] != select_source_expected[i])
                    break :blk false;
            }
            break :blk true;
        };
        assert(is_equal);
    }

    //
    // Poll response to SelectSources
    //
    const select_sources_response: *dbus.Message = blk: {
        const timeout_duration_seconds = 60;
        const iterations_max: u32 = 1000 * timeout_duration_seconds;
        const timeout_ms = 10;
        var i: u32 = 0;
        while (i < iterations_max) : (i += 1) {
            if (dbus.connectionReadWrite(connection, timeout_ms) != 1)
                continue;

            const response = dbus.connectionPopMessage(connection) orelse continue;
            const is_match = (1 == dbus.messageIsSignal(
                response,
                "org.freedesktop.portal.Request",
                "Response",
            ));

            if (is_match)
                break :blk response;

            //
            // Only unref if we haven't matched. If we do match we want to return from block
            // and unref after we've processed the response payload
            //
            dbus.messageUnref(response);
        }

        std.log.err("dbus_client: Failed to poll response to SelectSource message", .{});
        return error.PollResponseFail;
    };

    dbus.busRemoveMatch(connection, select_source_match_rule, null);

    //
    // Extract payload from SelectSources Response
    //
    {
        var select_sources_response_iter: dbus.MessageIter = undefined;
        _ = dbus.messageIterInit(select_sources_response, &select_sources_response_iter);
        if (dbus.messageIterGetArgType(&select_sources_response_iter) != c.DBUS_TYPE_UINT32) {
            return error.ReplyInvalidType;
        }
        var success_code: u32 = std.math.maxInt(u32);
        dbus.messageIterGetBasic(&select_sources_response_iter, @ptrCast(*void, &success_code));

        if (success_code != 0) {
            std.log.err("dbus_client: SelectSources response message returned error code {d}", .{
                success_code,
            });
            return error.SelectSourcesFail;
        }
    }

    //
    // Add match rule for following StartStream method call
    //
    const start_stream_request_suffix = try generateRequestToken(&request_suffix_buffer);
    var start_stream_match_rule: [*:0]const u8 = undefined;
    {
        start_stream_match_rule = try std.fmt.bufPrintZ(
            &match_buffer,
            "type='signal',interface='org.freedesktop.portal.Request',path='/org/freedesktop/portal/desktop/request/{s}/{s}'",
            .{
                portal_connection_name,
                start_stream_request_suffix,
            },
        );
        dbus.busAddMatch(connection, start_stream_match_rule, null);
        dbus.connectionFlush(connection);
    }

    //
    // Start the stream
    //
    const start_stream_request = try startStream(
        connection,
        session_handle,
        start_stream_request_suffix,
    );
    _ = start_stream_request;

    //
    // Poll response to SelectSources
    //
    const start_stream_response: *dbus.Message = blk: {
        const timeout_duration_seconds = 60;
        const iterations_max: u32 = 1000 * timeout_duration_seconds;
        const timeout_ms = 10;
        var i: u32 = 0;
        while (i < iterations_max) : (i += 1) {
            if (dbus.connectionReadWrite(connection, timeout_ms) != 1)
                continue;

            const response = dbus.connectionPopMessage(connection) orelse continue;

            // const response_path = dbus.messageGetPath(response);
            // _ = response_path;

            const is_match = (1 == dbus.messageIsSignal(
                response,
                "org.freedesktop.portal.Request",
                "Response",
            ));

            if (is_match)
                break :blk response;

            //
            // Only unref if we haven't matched. If we do match we want to return from block
            // and unref after we've processed the response payload
            //
            dbus.messageUnref(response);
        }

        std.log.err("dbus_client: Failed to poll response to Start message", .{});
        return error.PollResponseFail;
    };

    dbus.busRemoveMatch(connection, start_stream_match_rule, null);

    // const start_response_signature = dbus.messageGetSignature(start_stream_response);
    // _ = start_response_signature;
    const start_responses = try extractMessageStart(start_stream_response);

    const pipewire_fd = try openPipewireRemote(
        connection,
        session_handle,
    );

    //
    // Welcome to Pipewire land. Connect and get the stream setup
    //

    var argc: i32 = 1;
    var argv = [_][*:0]const u8{"reel"};

    var stream_ptr: *Stream = newStream();

    pw.pw_init(@ptrCast([*]i32, &argc), @ptrCast([*c][*c][*c]u8, &argv));

    stream_ptr.thread_loop = pw.pw_thread_loop_new("Pipewire screencast thread loop", null) orelse return error.CreateThreadLoopFail;
    var context = pw.pw_context_new(
        pw.pw_thread_loop_get_loop(stream_ptr.thread_loop),
        null,
        0,
    );
    if (pw.pw_thread_loop_start(stream_ptr.thread_loop) < 0) {
        std.log.err("Failed to start pw thread loop", .{});
    }

    pw.pw_thread_loop_lock(stream_ptr.thread_loop);
    var core = pw.pw_context_connect_fd(
        context,
        c.fcntl(pipewire_fd, c.F_DUPFD_CLOEXEC, @as(i32, 5)),
        null,
        0,
    ) orelse {
        std.log.err("Failed to create pipewire core object with fd", .{});
        pw.pw_thread_loop_unlock(stream_ptr.thread_loop);
        return;
    };

    const stream_properties = pw.pw_properties_new(
        pw.PW_KEY_MEDIA_TYPE,
        "Video",
        pw.PW_KEY_MEDIA_CATEGORY,
        "Capture",
        pw.PW_KEY_MEDIA_ROLE,
        "Screen",
        c.NULL,
    );
    stream_ptr.stream = pw.pw_stream_new(
        core,
        "reel-screencapture",
        stream_properties,
    ) orelse return error.CreateNewStreamFail;

    pw.pw_stream_add_listener(
        stream_ptr.stream,
        &stream_listener,
        &stream_events,
        stream_ptr,
    );

    var params: [1]*pw.spa_pod = undefined;
    var params_buffer: [2048]u8 = undefined;
    var pod_builder = pw.spa_pod_builder{
        .data = @ptrCast(*void, &params_buffer),
        .size = 2048,
        ._padding = 0,
        .state = .{
            .offset = 0,
            .flags = 0,
            .frame = null,
        },
        .callbacks = .{
            .funcs = null,
            .data = null,
        },
    };

    params[0] = buildPipewireParams(&pod_builder);

    _ = pw.pw_stream_connect(
        stream_ptr.stream,
        pw.PW_DIRECTION_INPUT,
        start_responses.pipewire_node_id,
        pw.PW_STREAM_FLAG_AUTOCONNECT | pw.PW_STREAM_FLAG_MAP_BUFFERS,
        @ptrCast([*c][*c]pw.spa_pod, &params),
        1,
    );

    pw.pw_thread_loop_unlock(stream_ptr.thread_loop);
}

fn onProcessCallback(userdata_opt: ?*anyopaque) callconv(.C) void {
    if (userdata_opt) |userdata| {
        const stream_ptr = @ptrCast(*const Stream, @alignCast(@alignOf(Stream), userdata));
        const buffer = pw.pw_stream_dequeue_buffer(stream_ptr.stream);
        const buffer_bytes = buffer.*.buffer.*.datas[0].data.?;
        const alignment = @alignOf(screencapture.PixelType);
        const buffer_pixels = @ptrCast([*]const screencapture.PixelType, @alignCast(alignment, buffer_bytes));

        frameReadyCallback(
            stream_ptr.handle,
            stream_ptr.format.width,
            stream_ptr.format.height,
            buffer_pixels,
        );
        _ = pw.pw_stream_queue_buffer(stream_ptr.stream, buffer);
    } else {
        std.log.err("screencapture(pipewire): userdata pointer null in onProcessCallback", .{});
        assert(false);
    }
}

fn onParamChangedCallback(userdata_opt: ?*anyopaque, id: u32, params: ?*const pw.spa_pod) callconv(.C) void {
    if (params == null)
        return;
    if (userdata_opt) |userdata| {
        if (id == pw.SPA_PARAM_Format) {
            var stream_ptr = @ptrCast(*Stream, @alignCast(@alignOf(Stream), userdata));
            stream_ptr.format = parseStreamFormat(params);
            std.log.info("Pipewire stream opened. {d} x {d} {s}", .{
                stream_ptr.format.width,
                stream_ptr.format.height,
                @tagName(stream_ptr.format.format),
            });
            onStreamOpenSuccessCallback(stream_ptr.handle, &.{});
        }
    } else {
        std.log.err("screencapture(pipewire): userdata pointer null in onParamChangedCallback", .{});
        assert(false);
    }
}

fn onStateChangedCallback(_: ?*anyopaque, old: pw.pw_stream_state, new: pw.pw_stream_state, error_message: [*c]const u8) callconv(.C) void {
    _ = old;
    const error_string: [*c]const u8 = error_message orelse "none";
    std.log.warn("pipewire state changed. \"{s}\". Error: {s}", .{ pw.pw_stream_state_as_string(new), error_string });
}

fn onCoreInfoCallback(_: ?*anyopaque, info: [*c]const pw.pw_core_info) callconv(.C) void {
    std.log.info("info callback:", .{});
    std.log.info("  id:      {d}", .{info[0].id});
    std.log.info("  user:    {s}", .{info[0].user_name});
    std.log.info("  host:    {s}", .{info[0].host_name});
    std.log.info("  version: {s}", .{info[0].version});
}

fn onCoreErrorCallback(_: ?*anyopaque, id: u32, seq: i32, res: i32, message: [*c]const u8) callconv(.C) void {
    std.log.err("pw: {s}. id {d} seq {d} res {d}", .{ message, id, seq, res });
}

fn onCoreDoneCallback(_: ?*anyopaque, id: u32, seq: i32) callconv(.C) void {
    if (id == pw.PW_ID_CORE and server_version_sync == seq) {
        for (stream_buffer) |stream| {
            if (stream.handle != Stream.null_handle)
                pw.pw_thread_loop_signal(stream.thread_loop, false);
        }
    }
}

fn teardownPipewire() void {
    for (&stream_buffer) |*stream| {
        if (stream.handle != Stream.null_handle and stream.state != .uninitialized) {
            stream.deinit();
        }
    }
}

fn extractMessageStart(
    start_stream_response: *dbus.Message,
) !StartResponse {

    // const message_signature = dbus.messageGetSignature(start_stream_response);
    // std.log.info("Signature: {s}", .{message_signature});

    var start_stream_response_iter: dbus.MessageIter = undefined;
    _ = dbus.messageIterInit(start_stream_response, &start_stream_response_iter);

    var result: StartResponse = undefined;
    if (dbus.messageIterGetArgType(&start_stream_response_iter) != c.DBUS_TYPE_UINT32) {
        return error.InvalidResponse;
    }

    dbus.messageIterGetBasic(&start_stream_response_iter, @ptrCast(*void, &result.pipewire_node_id));
    _ = dbus.messageIterNext(&start_stream_response_iter);

    var next_type: i32 = dbus.messageIterGetArgType(&start_stream_response_iter);
    assert(next_type == c.DBUS_TYPE_ARRAY);

    var root_array_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&start_stream_response_iter, &root_array_iter);

    next_type = dbus.messageIterGetArgType(&root_array_iter);
    assert(next_type == c.DBUS_TYPE_DICT_ENTRY);

    var root_dict_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&root_array_iter, &root_dict_iter);

    next_type = dbus.messageIterGetArgType(&root_dict_iter);
    assert(next_type == c.DBUS_TYPE_STRING);

    var option_label: [*:0]const u8 = undefined;
    dbus.messageIterGetBasic(&root_dict_iter, @ptrCast(*void, &option_label));

    _ = dbus.messageIterNext(&root_dict_iter);
    next_type = dbus.messageIterGetArgType(&root_dict_iter);
    assert(next_type == c.DBUS_TYPE_VARIANT);

    var variant_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&root_dict_iter, &variant_iter);
    next_type = dbus.messageIterGetArgType(&variant_iter);

    assert(next_type == c.DBUS_TYPE_ARRAY);

    var variant_array_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&variant_iter, &variant_array_iter);
    next_type = dbus.messageIterGetArgType(&variant_array_iter);

    assert(next_type == c.DBUS_TYPE_STRUCT);

    var struct_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&variant_array_iter, &struct_iter);
    next_type = dbus.messageIterGetArgType(&struct_iter);

    assert(next_type == c.DBUS_TYPE_UINT32);

    dbus.messageIterGetBasic(&struct_iter, @ptrCast(*void, &result.pipewire_node_id));
    _ = dbus.messageIterNext(&struct_iter);
    next_type = dbus.messageIterGetArgType(&struct_iter);

    assert(next_type == c.DBUS_TYPE_ARRAY);

    var array_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&struct_iter, &array_iter);

    while (true) {
        next_type = dbus.messageIterGetArgType(&array_iter);

        var has_next: bool = false;

        if (next_type == c.DBUS_TYPE_DICT_ENTRY) {
            var array_dict_entry_iter: dbus.MessageIter = undefined;
            dbus.messageIterRecurse(&array_iter, &array_dict_entry_iter);
            while (true) {
                next_type = dbus.messageIterGetArgType(&array_dict_entry_iter);
                if (next_type == c.DBUS_TYPE_STRING) {
                    dbus.messageIterGetBasic(&array_dict_entry_iter, @ptrCast(*void, &option_label));
                    std.log.info("Ret label: {s}", .{option_label});
                    if (c.strncmp("size", option_label, 4) == 0) {
                        _ = dbus.messageIterNext(&array_dict_entry_iter);
                        next_type = dbus.messageIterGetArgType(&array_dict_entry_iter);
                        assert(next_type == c.DBUS_TYPE_VARIANT);

                        var size_variant_iter: dbus.MessageIter = undefined;
                        dbus.messageIterRecurse(&array_dict_entry_iter, &size_variant_iter);
                        next_type = dbus.messageIterGetArgType(&size_variant_iter);
                        assert(next_type == c.DBUS_TYPE_STRUCT);

                        var size_struct_iter: dbus.MessageIter = undefined;
                        dbus.messageIterRecurse(&size_variant_iter, &size_struct_iter);
                        next_type = dbus.messageIterGetArgType(&size_struct_iter);
                        assert(next_type == c.DBUS_TYPE_INT32);

                        dbus.messageIterGetBasic(&size_struct_iter, @ptrCast(*void, &result.dimensions[0]));
                        _ = dbus.messageIterNext(&size_struct_iter);

                        next_type = dbus.messageIterGetArgType(&size_struct_iter);
                        assert(next_type == c.DBUS_TYPE_INT32);

                        dbus.messageIterGetBasic(&size_struct_iter, @ptrCast(*void, &result.dimensions[1]));
                    }
                    if (c.strncmp("id", option_label, 2) == 0) {
                        _ = dbus.messageIterNext(&array_dict_entry_iter);
                        next_type = dbus.messageIterGetArgType(&array_dict_entry_iter);
                        assert(next_type == c.DBUS_TYPE_VARIANT);

                        var id_variant_iter: dbus.MessageIter = undefined;
                        dbus.messageIterRecurse(&array_dict_entry_iter, &id_variant_iter);
                        next_type = dbus.messageIterGetArgType(&id_variant_iter);
                        assert(next_type == c.DBUS_TYPE_STRING);

                        dbus.messageIterGetBasic(&id_variant_iter, @ptrCast(*void, &result.id));
                    }
                }

                has_next = !(dbus.messageIterHasNext(&array_dict_entry_iter) == 0);
                if (!has_next)
                    break;
                _ = dbus.messageIterNext(&array_dict_entry_iter);
            }
        }

        has_next = !(dbus.messageIterHasNext(&array_iter) == 0);
        if (!has_next)
            break;
        _ = dbus.messageIterNext(&array_iter);
    }
    dbus.messageUnref(start_stream_response);

    return result;
}
