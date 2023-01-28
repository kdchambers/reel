// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const std = @import("std");
const dbus = @import("../../dbus.zig");
// const dbus = @import("../../dbus-bindings.zig");

const graphics = @import("../../graphics.zig");
const screencast = @import("../../screencast.zig");

// TODO: Remove
const c = @cImport({
    @cInclude("dbus/dbus.h");
    @cInclude("string.h");
    @cInclude("fcntl.h");
});

const pw = @cImport({
    @cInclude("spa/param/video/format-utils.h");
    @cInclude("spa/debug/types.h");
    @cInclude("spa/param/video/type-info.h");
    @cInclude("pipewire/pipewire.h");
});

//
// These functions come from pipewire_screencast_extra.c
//
extern fn parseStreamFormat(params: [*c]const pw.spa_pod) callconv(.C) StreamFormat;
extern fn buildPipewireParams(builder: *pw.spa_pod_builder) callconv(.C) *pw.spa_pod;

const SourceTypeFlags = packed struct(u32) {
    monitor: bool = false,
    window: bool = false,
    virtual: bool = false,
    reserved: u29 = 0,
};

const StartResponse = struct {
    pipewire_node_id: u32,
    id: [*:0]const u8,
    position: [2]i32,
    dimensions: [2]i32,
    source_type: u32,
};

const StreamFormat = extern struct {
    format: pw.spa_video_format,
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

pub var stream_format: StreamFormat = undefined;
pub var stream_state: screencast.State = .uninitialized;
pub var pixel_buffer: []graphics.RGBA(u8) = undefined;
pub var buffer_size: usize = 0;

var stream_listener: pw.spa_hook = undefined;
var stream: *pw.pw_stream = undefined;
var thread_loop: *pw.pw_thread_loop = undefined;
var server_version_sync: i32 = undefined;

// TODO: Doesn't need to be a buffer
var start_response_buffer: [16]StartResponse = undefined;

const allocator = std.heap.c_allocator;
var request_count: u32 = 0;
var session_count: u32 = 0;

var onOpenSuccessCallback: *const screencast.OpenOnSuccessFn = undefined;
var onOpenErrorCallback: *const screencast.OpenOnErrorFn = undefined;

var init_thread: std.Thread = undefined;
var once: bool = true;

pub inline fn open(
    on_success_cb: *const screencast.OpenOnSuccessFn,
    on_error_cb: *const screencast.OpenOnErrorFn,
) !void {
    onOpenSuccessCallback = on_success_cb;
    onOpenErrorCallback = on_error_cb;

    std.debug.assert(once);
    once = false;

    init_thread = std.Thread.spawn(.{}, init, .{}) catch |err| {
        onOpenErrorCallback();
        std.log.err("Failed to create thread to open pipewire screencast. Error: {}", .{
            err,
        });
        return error.CreateThreadFailed;
    };
}

pub inline fn close() void {
    teardownPipewire();
    stream_state = .closed;
}

pub inline fn pause() void {
    std.debug.assert(stream_state == .open);
    // TODO: Handle return
    _ = pw.pw_stream_set_active(stream, false);
    stream_state = .paused;
}

pub inline fn unpause() void {
    std.debug.assert(stream_state == .paused);
    // TODO: Handle return
    _ = pw.pw_stream_set_active(stream, true);
    stream_state = .open;
}

pub inline fn nextFrameImage() ?screencast.FrameImage {
    return screencast.FrameImage{
        .pixels = pixel_buffer.ptr,
        .width = @intCast(u16, stream_format.width),
        .height = @intCast(u16, stream_format.height),
    };
}

pub inline fn state() screencast.State {
    return stream_state;
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
    bus_name: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
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
        std.log.err("dbus_client: dbus.connectionSendWithReplyAndBlock( failed. Error: {s}", .{
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
    bus_name: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
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
    std.debug.assert(signature[4] == 0);
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
    bus_name: [*:0]const u8,
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
    bus_name: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
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
    std.debug.assert(signature[4] == 0);
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
    bus_name: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
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
    bus_name: [*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
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
        std.debug.assert(c.DBUS_BUS_SESSION == @enumToInt(dbus.BusType.session));
        std.debug.assert(c.DBUS_BUS_SYSTEM == @enumToInt(dbus.BusType.system));
        std.debug.assert(c.DBUS_BUS_STARTER == @enumToInt(dbus.BusType.starter));
    }

    const bus_name = "org.freedesktop.portal.Desktop";
    const object_path = "/org/freedesktop/portal/desktop";
    const interface_name = "org.freedesktop.portal.ScreenCast";
    const property_name = "AvailableCursorModes";
    _ = property_name;

    var err: dbus.Error = undefined;
    dbus.errorInit(&err);

    var connection: *dbus.Connection = dbus.busGet(dbus.BusType.session, &err);

    // orelse {
    //     std.log.err("dbus_client: dbus_bus_get failed. Error: {s}", .{
    //         err.message,
    //     });
    //     return error.CreateDBusConnectionFail;
    // };

    const connection_name_max_size = 16;
    const connection_name = blk: {
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
    const connection_name_len = std.mem.len(connection_name);

    if (connection_name_len >= connection_name_max_size) {
        std.log.err("dbus_client: Connection name '{s}' exceeds maximum size of {d}", .{
            connection_name,
            connection_name_max_size,
        });
        return error.ConnectionNameTooLarge;
    }

    var portal_connection_name_buffer: [connection_name_max_size]u8 = undefined;
    const portal_connection_name = blk: {
        var i: usize = 0;
        while (i < connection_name_len) : (i += 1) {
            if (connection_name[i] == '.') {
                portal_connection_name_buffer[i] = '_';
                continue;
            }
            portal_connection_name_buffer[i] = connection_name[i];
        }
        portal_connection_name_buffer[connection_name_len] = '0';
        break :blk portal_connection_name_buffer[0..connection_name_len];
    };
    std.debug.assert(std.mem.len(portal_connection_name) == connection_name_len);

    //
    // Check support
    //
    // const cursor_flags = try getProperty(u32, connection, bus_name, object_path, interface_name, property_name);
    // _ = cursor_flags;
    // const source_mode_flags = try getProperty(u32, connection, bus_name, object_path, interface_name, "AvailableSourceTypes");
    // _ = source_mode_flags;

    addSignalMatch(connection);

    const create_session_request_path = try createSession(connection, bus_name, object_path, interface_name);
    _ = create_session_request_path;

    const session_handle_ref = try pollForResponse(connection);
    const session_handle = try allocator.dupeZ(u8, std.mem.span(session_handle_ref));

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
        bus_name,
        object_path,
        interface_name,
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
        std.debug.assert(select_source_real_len == select_source_expected_len);
        const is_equal = blk: {
            var i: usize = 0;
            while (i < select_source_real_len) : (i += 1) {
                if (select_source_request[i] != select_source_expected[i])
                    break :blk false;
            }
            break :blk true;
        };
        std.debug.assert(is_equal);
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
        bus_name,
        object_path,
        interface_name,
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

            const response_path = dbus.messageGetPath(response);
            _ = response_path;

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

    const start_response_signature = dbus.messageGetSignature(start_stream_response);
    _ = start_response_signature;
    const start_responses = try extractMessageStart(connection, start_stream_response);

    const pipewire_fd = try openPipewireRemote(
        connection,
        bus_name,
        object_path,
        interface_name,
        session_handle,
    );

    //
    // Welcome to Pipewire land. Connect and get the stream setup
    //

    var argc: i32 = 1;
    var argv = [_][*:0]const u8{"reel"};

    pw.pw_init(@ptrCast([*]i32, &argc), @ptrCast([*c][*c][*c]u8, &argv));

    thread_loop = pw.pw_thread_loop_new("Pipewire thread loop", null) orelse return error.CreateThreadLoopFail;
    var context = pw.pw_context_new(
        pw.pw_thread_loop_get_loop(thread_loop),
        null,
        0,
    );
    if (pw.pw_thread_loop_start(thread_loop) < 0) {
        std.log.err("Failed to start pw thread loop", .{});
    }

    pw.pw_thread_loop_lock(thread_loop);
    var core = pw.pw_context_connect_fd(
        context,
        c.fcntl(pipewire_fd, c.F_DUPFD_CLOEXEC, @as(i32, 5)),
        null,
        0,
    ) orelse {
        std.log.err("Failed to create pipewire core object with fd", .{});
        pw.pw_thread_loop_unlock(thread_loop);
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
    stream = pw.pw_stream_new(
        core,
        "Reel",
        stream_properties,
    ) orelse return error.CreateNewStreamFail;

    pw.pw_stream_add_listener(
        stream,
        &stream_listener,
        &stream_events,
        null,
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
        stream,
        pw.PW_DIRECTION_INPUT,
        start_responses.pipewire_node_id,
        pw.PW_STREAM_FLAG_AUTOCONNECT | pw.PW_STREAM_FLAG_MAP_BUFFERS,
        @ptrCast([*c][*c]pw.spa_pod, &params),
        1,
    );

    stream_state = .init_pending;

    pw.pw_thread_loop_unlock(thread_loop);
}

fn onProcessCallback(_: ?*anyopaque) callconv(.C) void {
    const buffer = pw.pw_stream_dequeue_buffer(stream);
    std.debug.assert(stream_state == .open);
    @memcpy(
        @ptrCast([*]u8, pixel_buffer.ptr),
        @ptrCast([*]const u8, buffer.*.buffer.*.datas[0].data.?),
        buffer_size,
    );
    _ = pw.pw_stream_queue_buffer(stream, buffer);
}

fn onParamChangedCallback(_: ?*anyopaque, id: u32, params: [*c]const pw.spa_pod) callconv(.C) void {
    if (stream_state == .closed)
        return;

    if (id == pw.SPA_PARAM_Format) {
        stream_state = .init_failed;
        stream_format = parseStreamFormat(params);
        const pixel_count = @intCast(usize, stream_format.width) * stream_format.height;
        buffer_size = pixel_count * @sizeOf(screencast.PixelType);
        pixel_buffer = allocator.alloc(screencast.PixelType, @sizeOf(screencast.PixelType) * pixel_count) catch {
            std.log.err("screencast_pipewire: Failed to allocator pixel buffer", .{});
            onOpenErrorCallback();
            return;
        };
        stream_state = .open;
        onOpenSuccessCallback(stream_format.width, stream_format.height);
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
        pw.pw_thread_loop_signal(thread_loop, false);
    }
}

fn teardownPipewire() void {
    stream_state = .closed;
    // TODO: Handle return
    _ = pw.pw_stream_disconnect(stream);
    pw.pw_stream_destroy(stream);

    pw.pw_thread_loop_stop(thread_loop);
    pw.pw_thread_loop_destroy(thread_loop);
    std.log.info("Disconnecting from stream", .{});
}

fn extractMessageStart(
    connection: *dbus.Connection,
    start_stream_response: *dbus.Message,
) !StartResponse {
    _ = connection;
    var start_stream_response_iter: dbus.MessageIter = undefined;
    _ = dbus.messageIterInit(start_stream_response, &start_stream_response_iter);

    var entry = &start_response_buffer[0];

    if (dbus.messageIterGetArgType(&start_stream_response_iter) != c.DBUS_TYPE_UINT32) {
        return error.InvalidResponse;
    }

    dbus.messageIterGetBasic(&start_stream_response_iter, @ptrCast(*void, &entry.pipewire_node_id));
    _ = dbus.messageIterNext(&start_stream_response_iter);

    var next_type: i32 = dbus.messageIterGetArgType(&start_stream_response_iter);
    std.debug.assert(next_type == c.DBUS_TYPE_ARRAY);

    var root_array_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&start_stream_response_iter, &root_array_iter);

    next_type = dbus.messageIterGetArgType(&root_array_iter);
    std.debug.assert(next_type == c.DBUS_TYPE_DICT_ENTRY);

    var root_dict_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&root_array_iter, &root_dict_iter);

    next_type = dbus.messageIterGetArgType(&root_dict_iter);
    std.debug.assert(next_type == c.DBUS_TYPE_STRING);

    var option_label: [*:0]const u8 = undefined;
    dbus.messageIterGetBasic(&root_dict_iter, @ptrCast(*void, &option_label));

    _ = dbus.messageIterNext(&root_dict_iter);
    next_type = dbus.messageIterGetArgType(&root_dict_iter);
    std.debug.assert(next_type == c.DBUS_TYPE_VARIANT);

    var variant_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&root_dict_iter, &variant_iter);
    next_type = dbus.messageIterGetArgType(&variant_iter);

    std.debug.assert(next_type == c.DBUS_TYPE_ARRAY);

    var variant_array_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&variant_iter, &variant_array_iter);
    next_type = dbus.messageIterGetArgType(&variant_array_iter);

    std.debug.assert(next_type == c.DBUS_TYPE_STRUCT);

    var struct_iter: dbus.MessageIter = undefined;
    dbus.messageIterRecurse(&variant_array_iter, &struct_iter);
    next_type = dbus.messageIterGetArgType(&struct_iter);

    std.debug.assert(next_type == c.DBUS_TYPE_UINT32);

    dbus.messageIterGetBasic(&struct_iter, @ptrCast(*void, &entry.pipewire_node_id));
    _ = dbus.messageIterNext(&struct_iter);
    next_type = dbus.messageIterGetArgType(&struct_iter);

    std.debug.assert(next_type == c.DBUS_TYPE_ARRAY);

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
                    if (c.strncmp("size", option_label, 4) == 0) {
                        _ = dbus.messageIterNext(&array_dict_entry_iter);
                        next_type = dbus.messageIterGetArgType(&array_dict_entry_iter);
                        std.debug.assert(next_type == c.DBUS_TYPE_VARIANT);

                        var size_variant_iter: dbus.MessageIter = undefined;
                        dbus.messageIterRecurse(&array_dict_entry_iter, &size_variant_iter);
                        next_type = dbus.messageIterGetArgType(&size_variant_iter);
                        std.debug.assert(next_type == c.DBUS_TYPE_STRUCT);

                        var size_struct_iter: dbus.MessageIter = undefined;
                        dbus.messageIterRecurse(&size_variant_iter, &size_struct_iter);
                        next_type = dbus.messageIterGetArgType(&size_struct_iter);
                        std.debug.assert(next_type == c.DBUS_TYPE_INT32);

                        dbus.messageIterGetBasic(&size_struct_iter, @ptrCast(*void, &entry.dimensions[0]));
                        _ = dbus.messageIterNext(&size_struct_iter);

                        next_type = dbus.messageIterGetArgType(&size_struct_iter);
                        std.debug.assert(next_type == c.DBUS_TYPE_INT32);

                        dbus.messageIterGetBasic(&size_struct_iter, @ptrCast(*void, &entry.dimensions[1]));
                    }
                    if (c.strncmp("id", option_label, 2) == 0) {
                        _ = dbus.messageIterNext(&array_dict_entry_iter);
                        next_type = dbus.messageIterGetArgType(&array_dict_entry_iter);
                        std.debug.assert(next_type == c.DBUS_TYPE_VARIANT);

                        var id_variant_iter: dbus.MessageIter = undefined;
                        dbus.messageIterRecurse(&array_dict_entry_iter, &id_variant_iter);
                        next_type = dbus.messageIterGetArgType(&id_variant_iter);
                        std.debug.assert(next_type == c.DBUS_TYPE_STRING);

                        dbus.messageIterGetBasic(&id_variant_iter, @ptrCast(*void, &entry.id));
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

    return start_response_buffer[0];
}
