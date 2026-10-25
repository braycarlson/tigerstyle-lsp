const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const scylla = @import("scylla");
const Envelope = scylla.transport.rpc.Envelope;
const Reader = scylla.transport.Reader;
const log = scylla.log;
const rpc = scylla.transport.rpc;
const Editor = @import("editor.zig");
const Limits = @import("../limits.zig");
const Options = @import("../cli.zig").Options;
const Sender = @import("sender.zig");
const Session = @import("session.zig");
const actions = @import("actions.zig");
const cli = @import("../cli.zig");
const notifications = @import("notifications.zig");
const requests = @import("requests.zig");

parsed: json.Document,
session: Session,
stdin: std.Io.File.Reader,
storage: json.Storage,
transport: Reader,

const Server = @This();

const Method = enum {
    code_action,
    code_action_resolve,
    command,
    configuration,
    configuration_changed,
    diagnostic,
    diagnostic_workspace,
    did_change,
    did_close,
    did_open,
    did_save,
    hover,
    ignored,
    initialize,
    initialized,
    shutdown,
    unknown,
};

const Refusal = enum {
    method_not_found,
    not_initialized,
    shutting_down,

    fn code(refusal: Refusal) rpc.Code {
        const result: rpc.Code = switch (refusal) {
            .method_not_found => .method_not_found,
            .not_initialized => .server_not_initialized,
            .shutting_down => .invalid_request,
        };

        assert(@backingInt(result) < 0);

        return result;
    }

    fn text(refusal: Refusal) []const u8 {
        const result: []const u8 = switch (refusal) {
            .method_not_found => "the method is not served",
            .not_initialized => "the server has not been initialized",
            .shutting_down => "the request is not valid in this state",
        };

        assert(std.mem.startsWith(u8, result, "the "));

        return result;
    }
};

const message_count_max: u64 = 1 << 48;
const node_bytes_divisor: u32 = 16;
const stdin_buffer_bytes: u32 = 1 << 16;

const methods = std.StaticStringMap(Method).initComptime(.{
    .{ "$/cancelRequest", .ignored },
    .{ "$/setTrace", .ignored },
    .{ "codeAction/resolve", .code_action_resolve },
    .{ "initialize", .initialize },
    .{ "initialized", .initialized },
    .{ "shutdown", .shutdown },
    .{ "textDocument/codeAction", .code_action },
    .{ "textDocument/diagnostic", .diagnostic },
    .{ "textDocument/didChange", .did_change },
    .{ "textDocument/didClose", .did_close },
    .{ "textDocument/didOpen", .did_open },
    .{ "textDocument/didSave", .did_save },
    .{ "textDocument/hover", .hover },
    .{ "workspace/diagnostic", .diagnostic_workspace },
    .{ "workspace/didChangeConfiguration", .configuration_changed },
    .{ "workspace/didChangeWatchedFiles", .configuration },
    .{ "workspace/executeCommand", .command },
});

pub fn init(
    server: *Server,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    limits: *const Limits,
) std.mem.Allocator.Error!void {
    assert(options.mode == .server);
    assert(limits.message_bytes_max > limits.file_bytes_max);

    const node_count_max = @max(limits.message_bytes_max / node_bytes_divisor, 1);
    const buffer = try gpa.alloc(u8, stdin_buffer_bytes);

    server.storage = try .init(gpa, .{
        .node_count_max = node_count_max,
        .text_bytes_max = limits.message_bytes_max,
    });

    server.transport = try .init(gpa, limits.message_bytes_max);
    server.stdin = std.Io.File.stdin().readerStreaming(io, buffer);

    try server.session.init(gpa, io, options, limits);

    assert(server.transport.capacity() == limits.message_bytes_max);
    assert(server.session.state == .uninitialized);
}

pub fn run(server: *Server) u8 {
    assert(server.session.state == .uninitialized);

    for (0..message_count_max) |_| {
        const received = server.transport.read(&server.stdin.interface);

        const handled = if (received) |message|
            server.message_handle(message)
        else |err| switch (err) {
            error.Closed => return server.closed(),
            error.ReadFailed => return read_failed("Failed"),
            error.Malformed => return read_failed("Malformed"),
            error.TooLarge => server.oversized(),
        };

        handled catch |err| switch (err) {
            error.WriteFailed => {
                const name = server.session.sender.failure_name();

                log.line("the transport failed to write: {s}", .{name});

                return cli.exit_failure;
            },
        };

        if (server.session.state == .exited) return server.session.exit_code;
    } else unreachable;
}

fn read_failed(name: []const u8) u8 {
    assert(name.len > 0);

    log.line("the transport failed to read: {s}", .{name});

    return cli.exit_failure;
}

fn closed(server: *const Server) u8 {
    assert(server.session.state != .exited);

    if (server.session.state == .shutting_down) return cli.exit_success;

    log.line("the client closed the connection without a shutdown request", .{});

    return cli.exit_failure;
}

fn message_handle(server: *Server, message: []const u8) Sender.Error!void {
    assert(message.len <= server.transport.capacity());

    const parsed = if (server.parsed.parse(server.storage, message)) true else |err| switch (err) {
        error.DepthExceeded, error.Malformed, error.NodesExhausted, error.TextExhausted => false,
    };

    try server.dispatch(message, parsed);
}

fn dispatch(server: *Server, message: []const u8, parsed: bool) Sender.Error!void {
    const session = &server.session;
    const document = &server.parsed;

    assert(session.state != .exited);

    const envelope = envelope_of(document, parsed) orelse {
        log.line("dropping a message that failed to parse", .{});

        return session.sender.respond_error(
            .absent,
            .parse,
            "the message is not a valid JSON-RPC object",
        );
    };

    const method = envelope.method orelse return server.response_handle(&envelope);
    const name = document.text_of(method) orelse "";
    if (std.mem.eql(u8, name, "exit")) return server.exit();

    if (session.state == .uninitialized) {
        if (!std.mem.eql(u8, name, "initialize")) {
            return server.reject(&envelope, .not_initialized);
        }
    }

    if (session.state == .shutting_down) return server.reject(&envelope, .shutting_down);

    try server.route(message, &envelope, name);
}

fn envelope_of(document: *const json.Document, parsed: bool) ?Envelope {
    if (!parsed) return null;

    const root = document.root();
    const envelope = Envelope.of(document, root) orelse return null;

    assert(document.kind_of(root) == .object);

    return envelope;
}

fn response_handle(server: *Server, envelope: *const Envelope) Sender.Error!void {
    const session = &server.session;

    assert(envelope.method == null);

    if (!envelope.id.equals(Session.configuration_request)) return;

    const listed = envelope.result orelse return;
    const document = &server.parsed;
    if (document.kind_of(listed) != .array) return;

    var items = document.items(listed);

    for (0..Editor.editor_count) |position| {
        const settings = items.next() orelse break;
        const index: u32 = @intCast(position);
        const slot = if (index == session.folders.count()) Editor.folder_count_max else index;

        try session.editor_read(slot, document, settings);
    }

    try session.reload();
}

fn exit(server: *Server) void {
    const session = &server.session;

    assert(session.state != .exited);

    if (session.state == .shutting_down) {
        session.exit_code = cli.exit_success;
    } else {
        log.line("exiting without a shutdown request", .{});

        session.exit_code = cli.exit_failure;
    }

    session.state = .exited;
}

fn oversized(server: *Server) Sender.Error!void {
    assert(server.session.state != .exited);

    log.line("dropping an inbound message larger than the transport buffer", .{});

    try server.session.sender.respond_error(
        .absent,
        .invalid_request,
        "the message is larger than the transport buffer",
    );
}

fn reject(server: *Server, envelope: *const Envelope, refusal: Refusal) Sender.Error!void {
    assert(envelope.method != null);

    if (!envelope.id.is_request()) return;

    try server.session.sender.respond_error(envelope.id, refusal.code(), refusal.text());
}

fn route(
    server: *Server,
    message: []const u8,
    envelope: *const Envelope,
    name: []const u8,
) Sender.Error!void {
    const session = &server.session;

    assert(session.state != .exited);
    assert(session.state != .shutting_down);

    const document = &server.parsed;

    assert(message.len > 0);

    try switch (methods.get(name) orelse .unknown) {
        .code_action => actions.code_action(session, document, envelope),
        .code_action_resolve => actions.code_action_resolve(session, document, envelope),
        .command => requests.command(session, document, envelope),
        .configuration => session.reload(),
        .configuration_changed => notifications.did_change_configuration(session),
        .diagnostic => requests.diagnostic(session, document, envelope),
        .diagnostic_workspace => requests.workspace_diagnostic(session, document, envelope),
        .did_change => notifications.did_change(session, document, envelope),
        .did_close => notifications.did_close(session, document, envelope),
        .did_open => notifications.did_open(session, document, envelope),
        .did_save => notifications.did_save(session, document, envelope),
        .hover => requests.hover(session, document, envelope),
        .ignored => {},
        .initialize => requests.initialize(session, document, envelope),
        .initialized => session.watchers_register(),
        .shutdown => requests.shutdown(session, envelope),
        .unknown => server.reject(envelope, .method_not_found),
    };
}
