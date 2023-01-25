// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

extern fn dbus_bus_get(bus_type: dbus.BusType, err: *dbus.Error) *dbus.Connection;
extern fn dbus_bus_add_match(connection: *dbus.Connection, rule: [*:0]const u8, err: ?*dbus.Error) void;
extern fn dbus_bus_remove_match(connection: *dbus.Connection, rule: [*:0]const u8, err: ?*dbus.Error) void;

extern fn dbus_error_init(err: *dbus.Error) void;
extern fn dbus_error_is_set(err: *const dbus.Error) i32;

extern fn dbus_message_append_args(message: *dbus.Message, first_arg_type: i32, ...) i32;
extern fn dbus_message_unref(message: *dbus.Message) void;
extern fn dbus_message_get_path(message: *dbus.Message) [*:0]const u8;
extern fn dbus_message_get_signature(message: *dbus.Message) [*:0]const u8;
extern fn dbus_message_is_signal(message: *dbus.Message, interface: [*:0]const u8, signal_name: [*:0]const u8) dbus.bool_t;
extern fn dbus_message_new_method_call(
    destination: [*:0]const u8,
    path: [*:0]const u8,
    interface: [*:0]const u8,
    method: [*:0]const u8,
) *dbus.Message;

extern fn dbus_message_iter_init(message: *dbus.Message, iter: *dbus.MessageIter) i32;
extern fn dbus_message_iter_get_arg_type(iter: *dbus.MessageIter) i32;
extern fn dbus_message_iter_recurse(iter: *dbus.MessageIter, sub_iter: *dbus.MessageIter) void;
extern fn dbus_message_iter_get_basic(iter: *dbus.MessageIter, value: *void) void;
extern fn dbus_message_iter_init_append(query_message: *dbus.Message, iter: *dbus.MessageIter) void;
extern fn dbus_message_iter_append_basic(iter: *dbus.MessageIter, value_type: i32, value: *const void) dbus.bool_t;
extern fn dbus_message_iter_close_container(parent_iter: *dbus.MessageIter, iter: *dbus.MessageIter) dbus.bool_t;
extern fn dbus_message_iter_next(iter: *dbus.MessageIter) dbus.bool_t;
extern fn dbus_message_iter_get_signature(iter: *dbus.MessageIter) [*:0]const u8;
extern fn dbus_message_iter_has_next(iter: *dbus.MessageIter) dbus.bool_t;
extern fn dbus_message_iter_open_container(
    iter: *dbus.MessageIter,
    container_type: i32,
    signature: ?[*:0]const u8,
    sub_iter: *dbus.MessageIter,
) dbus.bool_t;

extern fn dbus_connection_flush(connection: *dbus.Connection) void;
extern fn dbus_connection_read_write(connection: *dbus.Connection, timeout_ms: i32) dbus.bool_t;
extern fn dbus_connection_pop_message(connection: *dbus.Connection) ?*dbus.Message;
extern fn dbus_connection_send_with_reply_and_block(
    connection: *dbus.Connection,
    message: *dbus.Message,
    timeout_ms: i32,
    err: *dbus.Error,
) *dbus.Message;

const dbus = struct {
    const Error = extern struct {
        name: [*:0]const u8,
        message: [*:0]const u8,

        dummy_1: u32,
        dummy_2: u32,
        dummy_3: u32,
        dummy_4: u32,
        dummy_5: u32,

        padding1: *void,
    };

    const MessageIter = extern struct {
        dummy1: *void,
        dummy2: *void,
        dummy3: u32,
        dummy4: i32,
        dummy5: i32,
        dummy6: i32,
        dummy7: i32,
        dummy8: i32,
        dummy9: i32,
        dummy10: i32,
        dummy11: i32,
        pad1: i32,
        pad2: *void,
        pad3: *void,
    };

    const Connection = opaque {};
    const Message = opaque {};

    const BusType = enum(i32) {
        session = 0,
        system = 1,
        starter = 2,
        _,
    };
};
