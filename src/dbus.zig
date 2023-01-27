// SPDX-License-Identifier: MIT
// Copyright (c) 2023 Keith Chambers

const dbus_bindings = @import("dbus_bindings.zig");

pub const Bus = dbus_bindings.dbus.Bus;
pub const Connection = dbus_bindings.dbus.Connection;
pub const Message = dbus_bindings.dbus.Message;
pub const MessageIter = dbus_bindings.dbus.MessageIter;
pub const BusType = dbus_bindings.dbus.BusType;
pub const Error = dbus_bindings.dbus.Error;

pub const busGet = dbus_bindings.dbus_bus_get;
pub const busGetUniqueName = dbus_bindings.dbus_bus_get_unique_name;
pub const busAddMatch = dbus_bindings.dbus_bus_add_match;
pub const busRemoveMatch = dbus_bindings.dbus_bus_remove_match;

pub const errorInit = dbus_bindings.dbus_error_init;
pub const errorIsSet = dbus_bindings.dbus_error_is_set;

pub const messageAppendArgs = dbus_bindings.dbus_message_append_args;

pub const messageUnref = dbus_bindings.dbus_message_unref;
pub const messageGetPath = dbus_bindings.dbus_message_get_path;
pub const messageGetSignature = dbus_bindings.dbus_message_get_signature;
pub const messageIsSignal = dbus_bindings.dbus_message_is_signal;
pub const messageNewMethodCall = dbus_bindings.dbus_message_new_method_call;

pub const messageIterInit = dbus_bindings.dbus_message_iter_init;
pub const messageIterGetArgType = dbus_bindings.dbus_message_iter_get_arg_type;
pub const messageIterRecurse = dbus_bindings.dbus_message_iter_recurse;
pub const messageIterGetBasic = dbus_bindings.dbus_message_iter_get_basic;
pub const messageIterInitAppend = dbus_bindings.dbus_message_iter_init_append;
pub const messageIterAppendBasic = dbus_bindings.dbus_message_iter_append_basic;
pub const messageIterCloseContainer = dbus_bindings.dbus_message_iter_close_container;
pub const messageIterNext = dbus_bindings.dbus_message_iter_next;
pub const messageIterGetSignature = dbus_bindings.dbus_message_iter_get_signature;
pub const messageIterHasNext = dbus_bindings.dbus_message_iter_has_next;
pub const messageIterOpenContainer = dbus_bindings.dbus_message_iter_open_container;

pub const connectionFlush = dbus_bindings.dbus_connection_flush;
pub const connectionReadWrite = dbus_bindings.dbus_connection_read_write;
pub const connectionPopMessage = dbus_bindings.dbus_connection_pop_message;
pub const connectionSendWithReplyAndBlock = dbus_bindings.dbus_connection_send_with_reply_and_block;
