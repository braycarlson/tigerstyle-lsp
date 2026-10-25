const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const cli = @import("cli.zig");

child: std.process.Child,
drain: Drain,
drain_thread: ?std.Thread,
finished: bool,
gpa: std.mem.Allocator,
io: std.Io,
messages: std.Io.Queue([]u8),
messages_buffer: [message_count_max][]u8,
pump_failure: ?Failure,
pump_thread: ?std.Thread,
stdin_buffer: [pipe_buffer_bytes]u8,
stdin_writer: std.Io.File.Writer,
stdout_buffer: [pipe_buffer_bytes]u8,
stdout_reader: std.Io.File.Reader,

const Session = @This();

const Failure = error{
    EndOfStream,
    InvalidCharacter,
    OutOfMemory,
    Overflow,
    ReadFailed,
    StreamTooLong,
    TestUnexpectedResult,
};

const Finished = struct {
    code: i32,
    stderr: []u8,

    pub fn deinit(finished: *Finished, gpa: std.mem.Allocator) void {
        assert(finished.code >= -1);

        gpa.free(finished.stderr);
        finished.* = undefined;
    }
};

const Drain = struct {
    failed: bool,
    file: std.Io.File,
    gpa: std.mem.Allocator,
    io: std.Io,
    text: std.ArrayList(u8),

    fn run(drain: *Drain) void {
        var buffer: [drain_buffer_bytes]u8 = undefined;
        var reader = drain.file.readerStreaming(drain.io, &buffer);

        reader.interface.appendRemainingUnlimited(drain.gpa, &drain.text) catch |err| switch (err) {
            error.OutOfMemory, error.ReadFailed => drain.failed = true,
        };

        assert(drain.text.items.len <= drain.text.capacity);
    }
};

const barrier_message_count_max = 256;
const content_length = "Content-Length: ";
const drain_buffer_bytes = 1 << 12;
const header_count_max = 32;
const message_count_max = 1 << 10;
const pipe_buffer_bytes = 1 << 16;
const pump_message_count_max = 1 << 20;
pub const resident_measured = builtin.target.os.tag == .linux;
const status_bytes_max = 1 << 16;

pub fn start(session: *Session, gpa: std.mem.Allocator, io: std.Io) !void {
    const binary = try cli.rooted(gpa, io, cli.binary_path);
    defer gpa.free(binary);

    session.child = try std.process.spawn(io, .{
        .argv = &.{ binary, "server", "--verbose" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    session.drain = .{
        .failed = false,
        .file = session.child.stderr.?,
        .gpa = gpa,
        .io = io,
        .text = .empty,
    };

    session.drain_thread = null;
    session.finished = false;
    session.gpa = gpa;
    session.io = io;
    session.messages = .init(&session.messages_buffer);
    session.pump_failure = null;
    session.pump_thread = null;
    session.stdin_writer = session.child.stdin.?.writerStreaming(io, &session.stdin_buffer);
    session.stdout_reader = session.child.stdout.?.readerStreaming(io, &session.stdout_buffer);

    session.drain_thread = std.Thread.spawn(.{}, Drain.run, .{&session.drain}) catch |err| {
        session.child.kill(io);

        return err;
    };

    session.pump_thread = std.Thread.spawn(.{}, pump_run, .{session}) catch |err| {
        session.pump_failure = error.TestUnexpectedResult;

        session.messages.close(io);
        session.deinit();

        return err;
    };

    assert(session.child.id != null);
    assert(session.child.stderr != null);
}

pub fn deinit(session: *Session) void {
    if (session.finished) return;

    session.close();
    session.threads_joined();
    session.messages_discarded();

    if (session.child.stdout) |stdout| stdout.close(session.io);
    if (session.child.stderr) |stderr| stderr.close(session.io);

    session.child.stdout = null;
    session.child.stderr = null;

    _ = session.child.wait(session.io) catch |err| switch (err) {
        error.AccessDenied, error.Canceled, error.Unexpected => {},
    };

    session.drain.text.deinit(session.gpa);
    session.finished = true;

    assert(session.child.id == null);
}

pub fn close(session: *Session) void {
    const stdin = session.child.stdin orelse return;

    stdin.close(session.io);
    session.child.stdin = null;

    assert(session.child.stdin == null);
}

pub fn finish(session: *Session, gpa: std.mem.Allocator) !Finished {
    assert(!session.finished);
    assert(gpa.ptr == session.gpa.ptr);

    session.close();
    session.threads_joined();
    session.messages_discarded();

    const term = try session.child.wait(session.io);

    session.finished = true;
    defer session.drain.text.deinit(gpa);

    switch (session.pump_failure.?) {
        error.EndOfStream => {},
        else => |failure| return failure,
    }

    if (session.drain.failed) return error.TestUnexpectedResult;

    const stderr = try session.drain.text.toOwnedSlice(gpa);
    errdefer gpa.free(stderr);

    if (std.mem.find(u8, stderr, "allocation guard tripped") != null) {
        std.debug.print("the guard tripped: {s}\n", .{stderr});

        return error.TestUnexpectedResult;
    }

    const code: i32 = switch (term) {
        .exited => |value| value,
        .signal, .stopped, .unknown => -1,
    };

    return .{ .code = code, .stderr = stderr };
}

fn threads_joined(session: *Session) void {
    assert(session.child.stdin == null);

    if (session.pump_thread) |thread| thread.join();
    if (session.drain_thread) |thread| thread.join();

    session.pump_thread = null;
    session.drain_thread = null;

    assert(session.pump_failure != null);
}

fn messages_discarded(session: *Session) void {
    assert(session.pump_thread == null);
    assert(session.pump_failure != null);

    for (0..message_count_max + 1) |_| {
        const body = session.messages.getOneUncancelable(session.io) catch |err| switch (err) {
            error.Closed => return,
        };

        session.gpa.free(body);
    } else unreachable;
}

fn pump_run(session: *Session) void {
    assert(session.pump_failure == null);

    for (0..pump_message_count_max) |_| {
        const body = message_read(session) catch |err| {
            session.pump_failure = err;

            break;
        };

        const count = session.messages.putUncancelable(session.io, &.{body}, 0) catch unreachable;

        if (count == 0) {
            std.debug.print("the session holds {d} unread messages\n", .{message_count_max});
            session.gpa.free(body);
            session.pump_failure = error.TestUnexpectedResult;

            break;
        }
    } else {
        std.debug.print("the session carries more than {d} messages\n", .{pump_message_count_max});
        session.pump_failure = error.TestUnexpectedResult;
    }

    assert(session.pump_failure != null);

    session.messages.close(session.io);
}

fn message_read(session: *Session) Failure![]u8 {
    const reader = &session.stdout_reader.interface;
    var length: usize = 0;

    for (0..header_count_max) |_| {
        const line = try reader.takeDelimiterInclusive('\n');
        const trimmed = std.mem.trimEnd(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) break;

        if (std.mem.startsWith(u8, trimmed, content_length)) {
            length = try std.fmt.parseInt(usize, trimmed[content_length.len..], 10);
        }
    }

    if (length == 0) return error.TestUnexpectedResult;

    const body = try session.gpa.alloc(u8, length);
    errdefer session.gpa.free(body);

    try reader.readSliceAll(body);

    if (!std.unicode.utf8ValidateSlice(body)) return error.TestUnexpectedResult;
    return body;
}

pub fn identifier(session: *const Session) std.process.Child.Id {
    const held = session.child.id.?;

    assert(held > 0);

    return held;
}

pub fn receive(session: *Session, gpa: std.mem.Allocator) Failure![]u8 {
    assert(gpa.ptr == session.gpa.ptr);
    assert(!session.finished);

    const body = session.messages.getOneUncancelable(session.io) catch |err| switch (err) {
        error.Closed => return session.pump_failure.?,
    };

    assert(body.len > 0);

    return body;
}

pub fn send(session: *Session, body: []const u8) !void {
    const writer = &session.stdin_writer.interface;

    assert(session.child.stdin != null);

    try writer.print(content_length ++ "{d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

pub fn send_raw(session: *Session, header: []const u8, body: []const u8) !void {
    const writer = &session.stdin_writer.interface;

    assert(header.len > 0);

    writer.writeAll(header) catch return session.hang_up_check();
    writer.writeAll(body) catch return session.hang_up_check();
    writer.flush() catch return session.hang_up_check();
}

fn hang_up_check(session: *const Session) !void {
    const failure = session.stdin_writer.err orelse return error.WriteFailed;

    switch (failure) {
        error.BrokenPipe => return,
        else => {
            std.debug.print("the write fails for a reason other than a hang up: {t}\n", .{failure});

            return failure;
        },
    }
}

pub fn barrier(session: *Session, gpa: std.mem.Allocator, request: u32) !void {
    const body = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/hover\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"file:///barrier.rs\"}}," ++
            "\"position\":{{\"line\":0,\"character\":0}}}}}}",
        .{request},
    );

    defer gpa.free(body);

    try session.send(body);

    const marker = try gpa.print("\"id\":{d}", .{request});
    defer gpa.free(marker);

    for (0..barrier_message_count_max) |_| {
        const message = try session.receive(gpa);
        defer gpa.free(message);

        if (std.mem.find(u8, message, marker) != null) return;
    }

    std.debug.print("the barrier response never arrived\n", .{});

    return error.TestUnexpectedResult;
}

pub fn initialize(session: *Session, gpa: std.mem.Allocator) ![]u8 {
    return initialize_rooted(session, gpa, "\"rootUri\":null");
}

pub fn initialize_rooted(session: *Session, gpa: std.mem.Allocator, roots: []const u8) ![]u8 {
    assert(roots.len > 0);

    const body = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":" ++
            "{{\"processId\":null,{s},\"capabilities\":{{}}}}}}",
        .{roots},
    );

    defer gpa.free(body);

    try session.send(body);

    const response = try session.receive(gpa);
    errdefer gpa.free(response);

    try session.send("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    const registration = try session.receive(gpa);
    defer gpa.free(registration);

    if (std.mem.find(u8, registration, "client/registerCapability") == null) {
        std.debug.print("{s}\n", .{registration});

        return error.TestUnexpectedResult;
    }

    return response;
}

pub fn uri_of(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    assert(path.len > 0);

    const slashed = try gpa.dupe(u8, path);
    defer gpa.free(slashed);

    std.mem.replaceScalar(u8, slashed, '\\', '/');

    const trimmed = if (std.mem.startsWith(u8, slashed, "/")) slashed[1..] else slashed;
    const escaped = try std.mem.replaceOwned(u8, gpa, trimmed, ":", "%3A");
    defer gpa.free(escaped);

    return gpa.print("file:///{s}", .{escaped});
}

pub fn open(session: *Session, gpa: std.mem.Allocator, uri: []const u8, text: []const u8) ![]u8 {
    try send_open(session, gpa, uri, text);

    return session.receive(gpa);
}

pub fn send_open(
    session: *Session,
    gpa: std.mem.Allocator,
    uri: []const u8,
    text: []const u8,
) !void {
    assert(uri.len > 0);

    const body = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"," ++
            "\"languageId\":\"rust\",\"version\":1," ++
            "\"text\":\"{s}\"}}}}}}",
        .{ uri, text },
    );

    defer gpa.free(body);

    try session.send(body);
}

pub fn resident_bytes(
    gpa: std.mem.Allocator,
    io: std.Io,
    process: std.process.Child.Id,
) !u64 {
    comptime assert(resident_measured);

    const path = try gpa.print("/proc/{d}/status", .{process});
    defer gpa.free(path);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buffer: [drain_buffer_bytes]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);

    const status = try reader.interface.allocRemaining(gpa, .limited(status_bytes_max));
    defer gpa.free(status);

    var lines: cli.Lines = .init(status);

    for (0..status.len + 1) |_| {
        const line = lines.next() orelse break;
        if (!std.mem.startsWith(u8, line, "VmRSS:")) continue;

        const value = std.mem.trim(u8, line["VmRSS:".len..], &std.ascii.whitespace);
        const digits = if (std.mem.endsWith(u8, value, " kB")) value[0 .. value.len - 3] else value;
        const kilobytes = try std.fmt.parseInt(u64, digits, 10);

        return kilobytes * 1024;
    }

    std.debug.print("the status file carries no VmRSS\n", .{});

    return error.TestUnexpectedResult;
}

pub fn contains(text: []const u8, part: []const u8) bool {
    assert(part.len > 0);

    return std.mem.find(u8, text, part) != null;
}
