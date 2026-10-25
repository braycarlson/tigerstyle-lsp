const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const scylla = @import("scylla");
const Id = scylla.transport.rpc.Id;
const log = scylla.log;
const rpc = scylla.transport.rpc;
const transport = scylla.transport;

inner: transport.Sender,
stdout: std.Io.File.Writer,

const Sender = @This();

pub const Capacity = struct {
    body_bytes_max: u32,
};

pub const Error = transport.Sender.WriteError;

const stdout_buffer_bytes: u32 = 1 << 16;

pub fn init(
    sender: *Sender,
    gpa: std.mem.Allocator,
    io: std.Io,
    capacity: Capacity,
) std.mem.Allocator.Error!void {
    assert(capacity.body_bytes_max >= transport.Sender.body_bytes_min);

    const buffer = try gpa.alloc(u8, stdout_buffer_bytes);

    sender.stdout = std.Io.File.stdout().writerStreaming(io, buffer);

    sender.inner = try .init(gpa, &sender.stdout.interface, .{
        .body_bytes_max = capacity.body_bytes_max,
    }, .{});

    assert(sender.inner.capacity() == capacity.body_bytes_max);
    assert(sender.stdout.interface.buffer.len == stdout_buffer_bytes);
}

pub fn notify_open(sender: *Sender, method: []const u8) ?*json.Writer {
    assert(method.len > 0);

    return sender.inner.notify_open(method) catch |err| return sender.dropped(err);
}

pub fn request_open(sender: *Sender, id: i64, method: []const u8) ?*json.Writer {
    assert(id > 0);
    assert(method.len > 0);

    return sender.inner.request_open(id, method) catch |err| return sender.dropped(err);
}

pub fn respond_open(sender: *Sender, id: Id) ?*json.Writer {
    assert(id.is_request());

    return sender.inner.respond_open(id) catch |err| return sender.dropped(err);
}

pub fn sent(sender: *Sender, written: json.Writer.Error!void) Error!void {
    assert(sender.inner.capacity() >= transport.Sender.body_bytes_min);

    written catch |err| {
        sender.inner.failed(err) catch |failure| return sender.refused(failure);

        return;
    };

    sender.inner.finish() catch |failure| return sender.refused(failure);
}

pub fn respond_null(sender: *Sender, id: Id) Error!void {
    assert(id.is_request());

    sender.inner.respond_null(id) catch |failure| return sender.refused(failure);
}

pub fn respond_error(sender: *Sender, id: Id, code: rpc.Code, message: []const u8) Error!void {
    assert(message.len > 0);

    sender.inner.respond_error(id, code, message) catch |failure| return sender.refused(failure);
}

pub fn failure_name(sender: *const Sender) []const u8 {
    const failure = sender.stdout.err orelse return "WriteFailed";
    const name = @errorName(failure);

    assert(name.len > 0);

    return name;
}

fn dropped(sender: *const Sender, err: transport.Sender.Error) ?*json.Writer {
    sender.dropped_log(err);

    return null;
}

fn dropped_log(sender: *const Sender, err: transport.Sender.Error) void {
    assert(sender.inner.capacity() >= transport.Sender.body_bytes_min);

    switch (err) {
        error.DepthExceeded, error.MessageTooLarge, error.WriteFailed => {
            log.line("dropping an outbound message past {d} bytes", .{sender.inner.capacity()});
        },
        error.EnumerationUnrecognized,
        error.FloatNonFinite,
        error.RawMalformed,
        => |value_error| {
            log.line("dropping an outbound message: {s}", .{json.message(value_error)});
        },
    }
}

fn refused(sender: *const Sender, err: transport.Sender.Error) Error!void {
    switch (err) {
        error.WriteFailed => return error.WriteFailed,
        error.DepthExceeded,
        error.EnumerationUnrecognized,
        error.FloatNonFinite,
        error.MessageTooLarge,
        error.RawMalformed,
        => sender.dropped_log(err),
    }
}
