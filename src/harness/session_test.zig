const std = @import("std");
const assert = std.debug.assert;
const Session = @import("session.zig");
const cli = @import("cli.zig");
const Characters = std.ArrayList(u32);

const Workspace = struct {
    root: []u8,
    uri: []u8,

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        options: struct { config: []const u8, name: []const u8 },
    ) !Workspace {
        assert(options.name.len > 0);
        assert(options.config.len > 0);

        var unique_bytes: [8]u8 = undefined;

        io.random(&unique_bytes);

        const unique = std.mem.readInt(u64, &unique_bytes, .little);
        const leaf = try gpa.print("tigerstyle-lsp-session-{s}-{x}", .{ options.name, unique });
        defer gpa.free(leaf);

        var temporary_bytes: [cli.temporary_bytes_max]u8 = undefined;
        const temporary = cli.temporary_root(&temporary_bytes);
        const root = try std.Io.Dir.path.join(gpa, &.{ temporary, leaf });
        errdefer gpa.free(root);

        const cwd = std.Io.Dir.cwd();

        tree_remove(io, root);

        try cwd.createDirPath(io, root);

        const config_path = try std.Io.Dir.path.join(gpa, &.{ root, "tigerstyle.toml" });
        defer gpa.free(config_path);

        try cwd.writeFile(io, .{ .sub_path = config_path, .data = options.config });

        const source = try std.Io.Dir.path.join(gpa, &.{ root, "a.rs" });
        defer gpa.free(source);

        try cwd.writeFile(io, .{ .sub_path = source, .data = "fn helper() {}\n" });

        const uri = try Session.uri_of(gpa, source);

        return .{ .root = root, .uri = uri };
    }

    fn deinit(workspace: *Workspace, gpa: std.mem.Allocator, io: std.Io) void {
        assert(workspace.root.len > 0);

        tree_remove(io, workspace.root);
        gpa.free(workspace.root);
        gpa.free(workspace.uri);
        workspace.* = undefined;
    }
};

const burst_change_count = 100;
const burst_filler: [110]u8 = @splat('x');
const burst_line = "    let value = 1; // " ++ burst_filler ++ "\\n";
const burst_line_count = 16;
const burst_published_bytes_min = 1 << 18;

const burst_text = text: {
    var text: []const u8 = "fn helper() {\\n";

    for (0..burst_line_count) |_| text = text ++ burst_line;

    break :text text ++ "}\\n";
};

const configuration_changed =
    \\{"jsonrpc":"2.0","method":"workspace/didChangeConfiguration","params":{"settings":{}}}
;

const exit = "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}";
const initialized = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
const named_text = "fn helper() {\\n    let valueMax = 1;\\n}\\n";
const python_star = "from os import *\\n";
const wide_text = "fn helper() {\\n    let s = \\\"\u{1f600}\\\"; let valueMax = 1;\\n}\\n";

fn tree_remove(io: std.Io, path: []const u8) void {
    assert(path.len > 0);

    std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
        std.debug.print("the workspace {s} was left behind: {s}\n", .{ path, @errorName(err) });
    };
}

fn expect_contains(options: struct { part: []const u8, text: []const u8 }) !void {
    assert(options.part.len > 0);

    if (Session.contains(.{ .part = options.part, .text = options.text })) return;

    std.debug.print("expected {s} in: {s}\n", .{ options.part, options.text });

    return error.TestUnexpectedResult;
}

fn expect_lacks(options: struct { part: []const u8, text: []const u8 }) !void {
    assert(options.part.len > 0);

    if (!Session.contains(.{ .part = options.part, .text = options.text })) return;

    std.debug.print("did not expect {s} in: {s}\n", .{ options.part, options.text });

    return error.TestUnexpectedResult;
}

fn expect_received(session: *Session, gpa: std.mem.Allocator, part: []const u8) !void {
    assert(part.len > 0);

    const message = try session.receive(gpa);
    defer gpa.free(message);

    try expect_contains(.{ .part = part, .text = message });
}

fn expect_finished(session: *Session, gpa: std.mem.Allocator, code: i32) !void {
    var finished = try session.finish(gpa);
    defer finished.deinit(gpa);

    if (finished.code != code) std.debug.print("{s}\n", .{finished.stderr});

    try std.testing.expectEqual(code, finished.code);
}

fn expect_logged(session: *Session, gpa: std.mem.Allocator, part: []const u8) !void {
    assert(part.len > 0);

    var finished = try session.finish(gpa);
    defer finished.deinit(gpa);

    try expect_contains(.{ .part = part, .text = finished.stderr });
}

fn discard(session: *Session, gpa: std.mem.Allocator) !void {
    const message = try session.receive(gpa);

    gpa.free(message);
}

fn initialize_discard(session: *Session, gpa: std.mem.Allocator) !void {
    const response = try Session.initialize(session, gpa);

    gpa.free(response);
}

fn open_discard(
    session: *Session,
    gpa: std.mem.Allocator,
    options: struct { text: []const u8, uri: []const u8 },
) !void {
    assert(options.uri.len > 0);

    const published = try Session.open(session, gpa, .{ .text = options.text, .uri = options.uri });

    gpa.free(published);
}

fn initialize_with(session: *Session, gpa: std.mem.Allocator, capabilities: []const u8) !void {
    assert(capabilities.len > 0);

    const body = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"," ++
            "\"params\":{{\"capabilities\":{s}}}}}",
        .{capabilities},
    );

    defer gpa.free(body);

    try session.send(body);
    try discard(session, gpa);
    try session.send(initialized);
    try discard(session, gpa);
}

fn configuration_answer(session: *Session, gpa: std.mem.Allocator, settings: []const u8) !void {
    assert(settings.len > 0);

    try session.send(configuration_changed);
    try discard(session, gpa);

    const body = try gpa.print("{{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":[{s}]}}", .{settings});
    defer gpa.free(body);

    try session.send(body);
}

fn named_session(
    session: *Session,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: struct { text: []const u8, uri: []const u8 },
) !void {
    assert(options.uri.len > 0);

    try session.start(gpa, io);
    errdefer session.deinit();

    try initialize_discard(session, gpa);
    try open_discard(session, gpa, .{ .text = options.text, .uri = options.uri });
    try session.send(configuration_changed);
    try expect_received(session, gpa, "workspace/configuration");
    try session.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":[{\"extendSelect\":[\"TS032\"]}]}");
    try expect_received(session, gpa, "publishDiagnostics");
}

fn change_ranged(
    session: *Session,
    gpa: std.mem.Allocator,
    options: struct { changes: []const u8, uri: []const u8 },
    version: u32,
) !void {
    assert(options.uri.len > 0);
    assert(version > 0);

    const body = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":" ++
            "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":{d}}}," ++
            "\"contentChanges\":[{s}]}}}}",
        .{ options.uri, version, options.changes },
    );

    defer gpa.free(body);

    try session.send(body);
}

fn diagnostic_request(session: *Session, gpa: std.mem.Allocator, id: u32, uri: []const u8) !void {
    assert(id > 0);
    assert(uri.len > 0);

    const body = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/diagnostic\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}}}}}}",
        .{ id, uri },
    );

    defer gpa.free(body);

    try session.send(body);
}

fn characters_of(gpa: std.mem.Allocator, published: []const u8) !Characters {
    assert(published.len > 0);

    const marker = "\"character\":";
    var characters: Characters = .empty;
    errdefer characters.deinit(gpa);

    var rest = published;

    for (0..published.len + 1) |_| {
        const index = std.mem.find(u8, rest, marker) orelse break;

        rest = rest[index + marker.len ..];

        const end = std.mem.findNone(u8, rest, "0123456789") orelse rest.len;

        try characters.append(gpa, try std.fmt.parseInt(u32, rest[0..end], 10));
        rest = rest[end..];
    }

    return characters;
}

fn expect_characters(gpa: std.mem.Allocator, published: []const u8, expected: []const u32) !void {
    assert(published.len > 0);

    var characters = try characters_of(gpa, published);
    defer characters.deinit(gpa);

    if (!std.mem.eql(u32, expected, characters.items)) std.debug.print("{s}\n", .{published});

    try std.testing.expectEqualSlices(u32, expected, characters.items);
}

test "a handshake completes and shuts down" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    const response = try Session.initialize(&session, gpa);
    defer gpa.free(response);

    try expect_contains(.{ .part = "\"id\":1", .text = response });
    try expect_contains(.{ .part = "textDocumentSync", .text = response });
    try expect_contains(.{ .part = "\"name\":\"tigerstyle-lsp\"", .text = response });
    try session.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}");
    try expect_received(&session, gpa, "\"result\":null");
    try session.send(exit);
    try expect_finished(&session, gpa, 0);
}

test "the advertised capabilities name only what the server answers" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    const response = try Session.initialize(&session, gpa);
    defer gpa.free(response);

    try expect_contains(.{ .part = "\"workspaceDiagnostics\":true", .text = response });

    try expect_contains(.{
        .part = "\"commands\":[\"tigerstyle.suppressFile\",\"tigerstyle.suppressAll\"," ++
            "\"tigerstyle.printDebugInformation\"]",
        .text = response,
    });

    try expect_contains(.{ .part = "\"resolveProvider\":false", .text = response });

    session.close();
}

test "a resolving client is told the server resolves" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try session.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize",
    ++
        \\"params":{"capabilities":{"textDocument":{"codeAction":{"resolveSupport":
    ++
        \\{"properties":["edit"]}}}}}}
    );

    try expect_received(&session, gpa, "\"resolveProvider\":true");

    session.close();
}

test "a request before initialize is refused" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try session.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"shutdown\"}");
    try expect_received(&session, gpa, "-32002");
    try expect_finished(&session, gpa, 1);
}

test "an unknown request is refused" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{}}
    );

    const response = try session.receive(gpa);
    defer gpa.free(response);

    try expect_contains(.{ .part = "-32601", .text = response });
    try expect_contains(.{ .part = "\"id\":2", .text = response });
    try expect_logged(&session, gpa, "frozen: ");
}

test "an unknown notification is ignored" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try session.send("{\"jsonrpc\":\"2.0\",\"method\":\"telemetry/event\",\"params\":{}}");
    try session.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}");
    try expect_received(&session, gpa, "\"id\":3");
    try session.send(exit);
    try expect_finished(&session, gpa, 0);
}

test "a text identifier is echoed" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":"call-7","method":"textDocument/definition"}
    );

    try expect_received(&session, gpa, "\"id\":\"call-7\"");

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "a malformed message is answered with a parse error" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try session.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":}");
    try expect_received(&session, gpa, "-32700");

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "an oversized message is refused and the session survives" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const body = try gpa.alloc(u8, 5 * 1024 * 1024);
    defer gpa.free(body);

    @memset(body, ' ');

    const header = try gpa.print("Content-Length: {d}\r\n\r\n", .{body.len});
    defer gpa.free(header);

    try session.send_raw(.{ .body = body, .header = header });
    try expect_received(&session, gpa, "-32600");
    try session.send("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"shutdown\"}");
    try expect_received(&session, gpa, "\"id\":5");
    try session.send(exit);
    try expect_finished(&session, gpa, 0);
}

test "a configuration carrying a selection reloads after freeze" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, .{
        .config = "select = [\"TS032\"]\n",
        .name = "selection",
    });

    defer workspace.deinit(gpa, io);

    var session: Session = undefined;

    try session.start(gpa, io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const notification = try Session.open(&session, gpa, .{
        .text = "fn helper() {\\n    let valueMax = 1;\\n}\\n",
        .uri = workspace.uri,
    });

    defer gpa.free(notification);

    try expect_contains(.{ .part = "TS032", .text = notification });

    var finished = try session.finish(gpa);
    defer finished.deinit(gpa);

    try expect_lacks(.{ .part = "allocation guard tripped", .text = finished.stderr });
}

test "a configuration change pulls the editor settings" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try session.send(configuration_changed);

    const pull = try session.receive(gpa);
    defer gpa.free(pull);

    try expect_contains(.{ .part = "workspace/configuration", .text = pull });
    try expect_contains(.{ .part = "\"section\":\"tigerstyle\"", .text = pull });
    try session.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":[{}]}");
    try session.send("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"shutdown\"}");
    try expect_received(&session, gpa, "\"id\":6");
    try session.send(exit);
    try expect_finished(&session, gpa, 0);
}

test "editor settings reach the open documents" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    try open_discard(&session, gpa, .{
        .text = "fn helper() {\\n    let valueMax = 1;\\n}\\n",
        .uri = "file:///a.rs",
    });

    try configuration_answer(&session, gpa, "{\"extendSelect\":[\"TS032\"]}");
    try expect_received(&session, gpa, "TS032");

    session.close();
}

test "a file uri that names no path is linted without a configuration search" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const published = try Session.open(&session, gpa, .{
        .text = "fn helper() {\\n    let valueMax = 1;\\n}\\n",
        .uri = "file://",
    });

    defer gpa.free(published);

    try std.testing.expect(std.mem.indexOf(u8, published, "\"uri\":\"file://\"") != null);

    session.close();
}

test "a change whose tail is malformed leaves the document alone" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const published = try Session.open(&session, gpa, .{
        .text = "fn walk(depth: u32) {\\n    walk(depth - 1);\\n}\\n",
        .uri = "file:///a.rs",
    });

    defer gpa.free(published);

    try expect_contains(.{ .part = "TS001", .text = published });

    try session.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange",
    ++
        \\"params":{"textDocument":{"uri":"file:///a.rs","version":2},
    ++
        \\"contentChanges":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,
    ++
        \\"character":20}},"text":"    let value = 1;"} {"text":"z"}]}}
    );

    try expect_received(&session, gpa, "-32700");

    try session.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange",
    ++
        \\"params":{"textDocument":{"uri":"file:///a.rs","version":3},
    ++
        \\"contentChanges":[]}}
    );

    try expect_received(&session, gpa, "TS001");
    try expect_logged(&session, gpa, "dropping a message that failed to parse");
}

test "a backward range after an applied one takes the document out of step" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    try open_discard(&session, gpa, .{
        .text = "fn walk(depth: u32) {\\n    walk(depth - 1);\\n}\\n",
        .uri = "file:///a.rs",
    });

    try session.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange",
    ++
        \\"params":{"textDocument":{"uri":"file:///a.rs","version":2},
    ++
        \\"contentChanges":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,
    ++
        \\"character":20}},"text":"    let value = 1;"},{"range":{"start":{"line":2,
    ++
        \\"character":0},"end":{"line":0,"character":0}},"text":"x"}]}}
    );

    try session.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange",
    ++
        \\"params":{"textDocument":{"uri":"file:///a.rs","version":3},
    ++
        \\"contentChanges":[]}}
    );

    var finished = try session.finish(gpa);
    defer finished.deinit(gpa);

    try expect_contains(.{
        .part = "marking a document out of step with its client",
        .text = finished.stderr,
    });

    try expect_contains(.{
        .part = "dropping a change for a document that is out of step",
        .text = finished.stderr,
    });
}

test "editor only never reads the file chain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, .{
        .config = "extend_select = [\"TS032\"]\n",
        .name = "editor-only",
    });

    defer workspace.deinit(gpa, io);

    var session: Session = undefined;

    try session.start(gpa, io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const published = try Session.open(&session, gpa, .{
        .text = "fn helper() {\\n    let valueMax = 1;\\n}\\n",
        .uri = workspace.uri,
    });

    defer gpa.free(published);

    try expect_contains(.{ .part = "TS032", .text = published });
    try configuration_answer(&session, gpa, "{\"configurationPreference\":\"editorOnly\"}");

    const republished = try session.receive(gpa);
    defer gpa.free(republished);

    try expect_lacks(.{ .part = "TS032", .text = republished });

    session.close();
}

test "a change reuses the file chain until a watched file or a save refreshes it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, .{
        .config = chain_selected,
        .name = "chain-cache",
    });

    defer workspace.deinit(gpa, io);

    var session: Session = undefined;

    try session.start(gpa, io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const opened = try Session.open(&session, gpa, .{ .text = named_text, .uri = workspace.uri });
    defer gpa.free(opened);

    try expect_contains(.{ .part = "TS032", .text = opened });
    try chain_write(gpa, io, &workspace, "extend_select = []\n");

    const kept = try notified(&session, gpa, chain_changed, .{ workspace.uri, named_text });
    defer gpa.free(kept);

    try expect_contains(.{ .part = "TS032", .text = kept });

    const refreshed = try notified(&session, gpa, chain_watched, .{workspace.uri});
    defer gpa.free(refreshed);

    try expect_lacks(.{ .part = "TS032", .text = refreshed });
    try chain_write(gpa, io, &workspace, chain_selected);

    const saved = try notified(&session, gpa, chain_saved, .{workspace.uri});
    defer gpa.free(saved);

    try expect_contains(.{ .part = "TS032", .text = saved });

    session.close();
}

const chain_selected = "extend_select = [\"TS032\"]\n";

const chain_changed =
    "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":" ++
    "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":2}}," ++
    "\"contentChanges\":[{{\"text\":\"{s}\"}}]}}}}";

const chain_saved =
    "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\"," ++
    "\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}}}}}}";

const chain_watched =
    "{{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\"," ++
    "\"params\":{{\"changes\":[{{\"uri\":\"{s}\",\"type\":2}}]}}}}";

fn chain_write(
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace: *const Workspace,
    config: []const u8,
) !void {
    assert(workspace.root.len > 0);
    assert(config.len > 0);

    const path = try std.Io.Dir.path.join(gpa, &.{ workspace.root, "tigerstyle.toml" });
    defer gpa.free(path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = config });
}

fn notified(
    session: *Session,
    gpa: std.mem.Allocator,
    comptime format: []const u8,
    arguments: anytype,
) ![]u8 {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    const body = try gpa.print(format, arguments);
    defer gpa.free(body);

    try session.send(body);

    return session.receive(gpa);
}

test "editor first wins over the file chain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, .{
        .config = "line_length_max = 200\n",
        .name = "editor-first",
    });

    defer workspace.deinit(gpa, io);

    var session: Session = undefined;

    try session.start(gpa, io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);

    try long.appendSlice(gpa, "fn helper() {\\n    let value = 1; // ");

    for (0..25) |_| try long.appendSlice(gpa, "word ");

    try long.appendSlice(gpa, "\\n}\\n");
    try open_discard(&session, gpa, .{ .text = long.items, .uri = workspace.uri });

    try configuration_answer(
        &session,
        gpa,
        "{\"configurationPreference\":\"editorFirst\",\"lineLengthMax\":80}",
    );

    try expect_received(&session, gpa, "TS012");

    session.close();
}

test "a bad editor selector is reported by name" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try configuration_answer(&session, gpa, "{\"extendSelect\":[\"nonsense\"]}");

    const message = try session.receive(gpa);
    defer gpa.free(message);

    try expect_contains(.{ .part = "window/showMessage", .text = message });

    try expect_contains(.{
        .part = "tigerstyle.extendSelect: the selector names no rule",
        .text = message,
    });

    try expect_contains(.{ .part = "(named by the editor settings)", .text = message });

    session.close();
}

test "an open publishes diagnostics" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const notification = try Session.open(&session, gpa, .{
        .text = "fn main() {}",
        .uri = "file:///a.rs",
    });

    defer gpa.free(notification);

    try expect_contains(.{ .part = "textDocument/publishDiagnostics", .text = notification });
    try expect_contains(.{ .part = "\"uri\":\"file:///a.rs\"", .text = notification });
    try expect_contains(.{ .part = "\"diagnostics\":[]", .text = notification });

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "a change republishes for the new version" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try open_discard(&session, gpa, .{ .text = "fn main() {}", .uri = "file:///a.rs" });

    try session.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange",
    ++
        \\"params":{"textDocument":{"uri":"file:///a.rs","version":2},
    ++
        \\"contentChanges":[{"text":"fn main() {\n}\n"}]}}
    );

    try expect_received(&session, gpa, "\"version\":2");

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "a burst of changes past a pipe's capacity is answered in order" {
    const gpa = std.testing.allocator;
    const change = "{\"text\":\"" ++ burst_text ++ "\"}";
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try open_discard(&session, gpa, .{ .text = named_text, .uri = "file:///a.rs" });

    for (0..burst_change_count) |index| {
        try change_ranged(
            &session,
            gpa,
            .{
                .changes = change,
                .uri = "file:///a.rs",
            },
            @intCast(index + 2),
        );
    }

    const marker_format = "\"version\":{d},\"diagnostics\"";
    var marker_bytes: [64]u8 = undefined;
    var published_bytes: u64 = 0;

    for (0..burst_change_count) |index| {
        const marker = try std.mem.print(&marker_bytes, marker_format, .{index + 2});
        const message = try session.receive(gpa);
        defer gpa.free(message);

        try expect_contains(.{ .part = "textDocument/publishDiagnostics", .text = message });
        try expect_contains(.{ .part = marker, .text = message });

        published_bytes += message.len;
    }

    try std.testing.expect(published_bytes > burst_published_bytes_min);

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "a close clears the diagnostics" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try open_discard(&session, gpa, .{ .text = "fn main() {}", .uri = "file:///a.rs" });

    try session.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didClose",
    ++
        \\"params":{"textDocument":{"uri":"file:///a.rs"}}}
    );

    try expect_received(&session, gpa, "\"diagnostics\":[]");
    try session.send("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"shutdown\"}");
    try expect_received(&session, gpa, "\"id\":9");

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "an oversized file is rejected with a diagnostic" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const text = try gpa.alloc(u8, 2 * 1024 * 1024);
    defer gpa.free(text);

    @memset(text, 'x');

    const notification = try Session.open(&session, gpa, .{
        .text = text,
        .uri = "file:///big.rs",
    });

    defer gpa.free(notification);

    try expect_contains(.{ .part = "larger than tigerstyle-lsp analyzes", .text = notification });

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "opens past the document count are refused" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    for (0..64) |index| {
        const uri = try gpa.print("file:///{d}.rs", .{index});
        defer gpa.free(uri);

        try open_discard(&session, gpa, .{ .text = "fn main() {}", .uri = uri });
    }

    try Session.send_open(&session, gpa, .{ .text = "fn main() {}", .uri = "file:///overflow.rs" });
    try session.send("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"shutdown\"}");
    try expect_received(&session, gpa, "\"id\":9");
    try expect_logged(&session, gpa, "refusing an open past 64 documents");
}

test "an open publishes rule findings" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const notification = try Session.open(&session, gpa, .{
        .text = "fn main() {\\n   let value = 1;\\n}\\n",
        .uri = "file:///a.rs",
    });

    defer gpa.free(notification);

    try expect_contains(.{ .part = "TS029", .text = notification });
    try expect_contains(.{ .part = "\"source\":\"tigerstyle-lsp\"", .text = notification });
    try expect_contains(.{ .part = "3 columns", .text = notification });

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "a suppressed finding is not published" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const notification = try Session.open(&session, gpa, .{
        .text = "fn main() {\\n    // tigerstyle-ignore: TS029\\n   let value = 1;\\n}\\n",
        .uri = "file:///a.rs",
    });

    defer gpa.free(notification);

    try expect_contains(.{ .part = "\"diagnostics\":[]", .text = notification });

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "a file of an unknown language carries no findings" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const notification = try Session.open(&session, gpa, .{
        .text = "   not code at all\\n",
        .uri = "file:///notes.txt",
    });

    defer gpa.free(notification);

    try expect_contains(.{ .part = "\"diagnostics\":[]", .text = notification });

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "a hover over a finding explains the rule" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    try open_discard(&session, gpa, .{
        .text = "fn main() {\\n   let value = 1;\\n}\\n",
        .uri = "file:///a.rs",
    });

    try session.send(
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/hover",
    ++
        \\"params":{"textDocument":{"uri":"file:///a.rs"},"position":{"line":1,
    ++
        \\"character":0}}}
    );

    const response = try session.receive(gpa);
    defer gpa.free(response);

    try expect_contains(.{ .part = "four-space-indent", .text = response });
    try expect_contains(.{ .part = "markdown", .text = response });

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "a hover away from a finding returns nothing" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try open_discard(&session, gpa, .{ .text = "fn main() {}\\n", .uri = "file:///a.rs" });

    try session.send(
        \\{"jsonrpc":"2.0","id":8,"method":"textDocument/hover",
    ++
        \\"params":{"textDocument":{"uri":"file:///a.rs"},"position":{"line":0,
    ++
        \\"character":3}}}
    );

    try expect_received(&session, gpa, "\"result\":null");

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "an incremental change splices the document" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    try Session.send_open(&session, gpa, .{
        .text = "fn helper() {\\n    let value = 1;\\n}\\n",
        .uri = "file:///tmp/a.rs",
    });

    try discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange",
    ++
        \\"params":{"textDocument":{"uri":"file:///tmp/a.rs","version":2},
    ++
        \\"contentChanges":[{"range":{"start":{"line":1,"character":8},"end":{"line":1,
    ++
        \\"character":13}},"text":"valueMax"}]}}
    );

    try expect_received(&session, gpa, "publishDiagnostics");

    try session.send(
        \\{"jsonrpc":"2.0","id":9,"method":"textDocument/hover",
    ++
        \\"params":{"textDocument":{"uri":"file:///tmp/a.rs"},"position":{"line":1,
    ++
        \\"character":9}}}
    );

    try expect_received(&session, gpa, "\"id\":9");

    session.close();
}

test "a utf eight client gets utf eight columns" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try session.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize",
    ++
        \\"params":{"capabilities":{"general":{"positionEncodings":["utf-8",
    ++
        \\"utf-16"]}}}}
    );

    try expect_received(&session, gpa, "\"positionEncoding\":\"utf-8\"");

    session.close();
}

test "a pull client gets a report rather than a publish" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try session.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize",
    ++
        \\"params":{"capabilities":{"textDocument":{"diagnostic":{"dynamicRegistration":
    ++
        \\false}}}}}
    );

    try expect_received(&session, gpa, "diagnosticProvider");
    try Session.send_open(&session, gpa, .{ .text = python_star, .uri = "file:///tmp/a.py" });
    try diagnostic_request(&session, gpa, 2, "file:///tmp/a.py");

    const report = try session.receive(gpa);
    defer gpa.free(report);

    try expect_contains(.{ .part = "\"kind\":\"full\"", .text = report });
    try expect_contains(.{ .part = "TS011", .text = report });

    session.close();
}

test "a code action offers a suppression" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try Session.send_open(&session, gpa, .{ .text = python_star, .uri = "file:///tmp/a.py" });
    try discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/codeAction",
    ++
        \\"params":{"textDocument":{"uri":"file:///tmp/a.py"},
    ++
        \\"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},
    ++
        \\"context":{"diagnostics":[]}}}
    );

    const actions = try session.receive(gpa);
    defer gpa.free(actions);

    try expect_contains(.{ .part = "tigerstyle-ignore:", .text = actions });
    try expect_contains(.{ .part = "tigerstyle-file-ignore:", .text = actions });

    session.close();
}

test "the debug command answers" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":4,"method":"workspace/executeCommand",
    ++
        \\"params":{"command":"tigerstyle.printDebugInformation","arguments":[]}}
    );

    try expect_received(&session, gpa, "\"id\":4");

    session.close();
}

test "a workspace diagnostic reports every open document" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try Session.send_open(&session, gpa, .{ .text = python_star, .uri = "file:///a.py" });
    try discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/diagnostic",
    ++
        \\"params":{"previousResultIds":[]}}
    );

    const report = try session.receive(gpa);
    defer gpa.free(report);

    try expect_contains(.{ .part = "\"kind\":\"full\"", .text = report });
    try expect_contains(.{ .part = "TS011", .text = report });
    try expect_contains(.{ .part = "\"uri\":\"file:///a.py\"", .text = report });

    session.close();
}

test "a matching previous result id reports unchanged" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try Session.send_open(&session, gpa, .{ .text = python_star, .uri = "file:///a.py" });
    try discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/diagnostic",
    ++
        \\"params":{"previousResultIds":[]}}
    );

    const report = try session.receive(gpa);
    defer gpa.free(report);

    const marker = "\"resultId\":";
    const found = std.mem.find(u8, report, marker) orelse return error.TestUnexpectedResult;
    const start = found + marker.len;
    const end = std.mem.findNonePos(u8, report, start, "0123456789") orelse report.len;

    const body = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/diagnostic\"," ++
            "\"params\":{{\"previousResultIds\":[{{\"uri\":\"file:///a.py\"," ++
            "\"value\":{s}}}]}}}}",
        .{report[start..end]},
    );

    defer gpa.free(body);

    try session.send(body);

    const second = try session.receive(gpa);
    defer gpa.free(second);

    try expect_contains(.{ .part = "\"kind\":\"unchanged\"", .text = second });
    try expect_lacks(.{ .part = "TS011", .text = second });

    session.close();
}

test "a short workspace sweep emits no progress" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try Session.send_open(&session, gpa, .{ .text = python_star, .uri = "file:///a.py" });
    try discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/diagnostic",
    ++
        \\"params":{"workDoneToken":"tigerstyle-lsp-1"}}
    );

    const report = try session.receive(gpa);
    defer gpa.free(report);

    try expect_contains(.{ .part = "\"id\":2", .text = report });
    try expect_lacks(.{ .part = "$/progress", .text = report });

    session.close();
}

test "a resolving client gets a suppression action without an edit" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_with(
        &session,
        gpa,
        "{\"textDocument\":{\"codeAction\":{\"resolveSupport\":{\"properties\":[\"edit\"]}}}}",
    );

    try Session.send_open(&session, gpa, .{ .text = python_star, .uri = "file:///a.py" });
    try discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction",
    ++
        \\"params":{"textDocument":{"uri":"file:///a.py"},"range":{"start":{"line":0,
    ++
        \\"character":0},"end":{"line":0,"character":0}},"context":{"diagnostics":[]}}}
    );

    const actions = try session.receive(gpa);
    defer gpa.free(actions);

    try expect_contains(.{ .part = "\"kind\":\"suppressLine\"", .text = actions });
    try expect_contains(.{ .part = "\"kind\":\"suppressFile\"", .text = actions });
    try expect_contains(.{ .part = "\"rule\":\"TS011\"", .text = actions });

    try session.send(
        \\{"jsonrpc":"2.0","id":3,"method":"codeAction/resolve",
    ++
        \\"params":{"title":"Suppress this finding on its line","kind":"quickfix",
    ++
        \\"data":{"kind":"suppressLine","line":0,"rule":"TS011","uri":"file:///a.py"}}}
    );

    const resolved = try session.receive(gpa);
    defer gpa.free(resolved);

    try expect_contains(.{ .part = "tigerstyle-ignore: TS011", .text = resolved });
    try expect_contains(.{ .part = "\"changes\"", .text = resolved });

    session.close();
}

test "a stale resolve payload returns the action untouched" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":2,"method":"codeAction/resolve",
    ++
        \\"params":{"title":"Suppress this finding on its line","kind":"quickfix",
    ++
        \\"data":{"kind":"suppressLine","line":0,"rule":"TS011",
    ++
        \\"uri":"file:///gone.py"}}}
    );

    const resolved = try session.receive(gpa);
    defer gpa.free(resolved);

    try expect_contains(.{ .part = "\"title\":\"Suppress", .text = resolved });
    try expect_lacks(.{ .part = "\"edit\"", .text = resolved });

    session.close();
}

test "the suppress all command applies one edit" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_with(&session, gpa, "{\"workspace\":{\"applyEdit\":true}}");
    try Session.send_open(&session, gpa, .{ .text = python_star, .uri = "file:///a.py" });
    try discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/executeCommand",
    ++
        \\"params":{"command":"tigerstyle.suppressAll","arguments":["file:///a.py"]}}
    );

    const edit = try session.receive(gpa);
    defer gpa.free(edit);

    try expect_contains(.{ .part = "workspace/applyEdit", .text = edit });
    try expect_contains(.{ .part = "tigerstyle-file-ignore: TS011", .text = edit });

    session.close();
}

test "the suppress file command lands after a shebang" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_with(&session, gpa, "{\"workspace\":{\"applyEdit\":true}}");

    try Session.send_open(&session, gpa, .{
        .text = "#!/usr/bin/env python3\\nfrom os import *\\n",
        .uri = "file:///a.py",
    });

    try discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/executeCommand",
    ++
        \\"params":{"command":"tigerstyle.suppressFile","arguments":["file:///a.py"]}}
    );

    const edit = try session.receive(gpa);
    defer gpa.free(edit);

    try expect_contains(.{ .part = "tigerstyle-file-ignore: *", .text = edit });
    try expect_contains(.{ .part = "\"line\":1", .text = edit });

    session.close();
}

test "a command without apply edit support is dropped" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try Session.send_open(&session, gpa, .{ .text = python_star, .uri = "file:///a.py" });
    try discard(&session, gpa);

    try session.send(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/executeCommand",
    ++
        \\"params":{"command":"tigerstyle.suppressAll","arguments":["file:///a.py"]}}
    );

    const response = try session.receive(gpa);
    defer gpa.free(response);

    try expect_contains(.{ .part = "\"result\":null", .text = response });
    try expect_lacks(.{ .part = "applyEdit", .text = response });

    session.close();
}

test "fix on save applies the safe fixes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, .{
        .config = "extend_select = [\"TS031\"]\n",
        .name = "fix-on-save",
    });

    defer workspace.deinit(gpa, io);

    var session: Session = undefined;

    try session.start(gpa, io);
    defer session.deinit();

    try initialize_with(&session, gpa, "{\"workspace\":{\"applyEdit\":true}}");
    try configuration_answer(&session, gpa, "{\"fixOnSave\":true}");

    try Session.send_open(&session, gpa, .{
        .text = "// a note about the work\\nfn helper() {}\\n",
        .uri = workspace.uri,
    });

    try discard(&session, gpa);

    const saved = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}}}}}}",
        .{workspace.uri},
    );

    defer gpa.free(saved);

    try session.send(saved);

    const edit = try session.receive(gpa);
    defer gpa.free(edit);

    try expect_contains(.{ .part = "TigerStyle: Fix all on save", .text = edit });
    try expect_contains(.{ .part = "workspace/applyEdit", .text = edit });
    try expect_received(&session, gpa, "publishDiagnostics");

    var finished = try session.finish(gpa);
    defer finished.deinit(gpa);

    try expect_lacks(.{ .part = "allocation guard tripped", .text = finished.stderr });
}

test "a diagnostic tag rides on the unnecessary rules" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);

    const notification = try Session.open(&session, gpa, .{
        .text = python_star,
        .uri = "file:///a.py",
    });

    defer gpa.free(notification);

    try expect_contains(.{ .part = "\"tags\":[1]", .text = notification });

    const quiet = try Session.open(&session, gpa, .{
        .text = "def f(a, b, c, d, e, g, h, i):\\n    pass\\n",
        .uri = "file:///b.py",
    });

    defer gpa.free(quiet);

    try expect_lacks(.{ .part = "\"tags\"", .text = quiet });

    session.close();
}

test "a root uri initialize survives the freeze" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    const response = try Session.initialize_rooted(
        &session,
        gpa,
        "\"rootUri\":\"file:///workspace\"",
    );

    defer gpa.free(response);

    try expect_contains(.{ .part = "\"id\":1", .text = response });
    try expect_contains(.{ .part = "textDocumentSync", .text = response });

    session.close();
}

test "a workspace folders initialize survives the freeze" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    const response = try Session.initialize_rooted(
        &session,
        gpa,
        \\"workspaceFolders":[{"uri":"file:///workspace","name":"workspace"}]
        ,
    );

    defer gpa.free(response);

    try expect_contains(.{ .part = "\"id\":1", .text = response });
    try expect_contains(.{ .part = "textDocumentSync", .text = response });

    session.close();
}

test "a root uri and workspace folders initialize survives the freeze" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    const response = try Session.initialize_rooted(
        &session,
        gpa,
        \\"rootUri":"file:///workspace",
        ++
            \\"workspaceFolders":[{"uri":"file:///workspace/one","name":"one"},
        ++
            \\{"uri":"file:///workspace/two","name":"two"}]
        ,
    );

    defer gpa.free(response);

    try expect_contains(.{ .part = "\"id\":1", .text = response });
    try expect_contains(.{ .part = "textDocumentSync", .text = response });

    session.close();
}

test "a code action filters by the requested kind" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try initialize_discard(&session, gpa);
    try Session.send_open(&session, gpa, .{ .text = python_star, .uri = "file:///tmp/a.py" });
    try discard(&session, gpa);
    try action_request(&session, gpa, 3, "[\"source.fixAll\"]");

    const fix_all = try session.receive(gpa);
    defer gpa.free(fix_all);

    try expect_lacks(.{ .part = "tigerstyle-ignore:", .text = fix_all });
    try action_request(&session, gpa, 4, "[\"quickfix\"]");

    const quickfix = try session.receive(gpa);
    defer gpa.free(quickfix);

    try expect_contains(.{ .part = "tigerstyle-ignore:", .text = quickfix });
    try expect_lacks(.{ .part = "source.fixAll.tigerstyle", .text = quickfix });
    try action_request(&session, gpa, 5, "[\"refactor\"]");
    try expect_received(&session, gpa, "\"result\":[]");

    session.close();
}

fn action_request(session: *Session, gpa: std.mem.Allocator, id: u32, only: []const u8) !void {
    assert(id > 0);
    assert(only.len > 0);

    const body = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/codeAction\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"file:///tmp/a.py\"}}," ++
            "\"range\":{{\"start\":{{\"line\":0,\"character\":0}}," ++
            "\"end\":{{\"line\":0,\"character\":0}}}}," ++
            "\"context\":{{\"diagnostics\":[],\"only\":{s}}}}}}}",
        .{ id, only },
    );

    defer gpa.free(body);

    try session.send(body);
}

test "the initialize result carries the editor capabilities" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    const response = try Session.initialize(&session, gpa);
    defer gpa.free(response);

    try expect_contains(.{ .part = "\"identifier\":\"tigerstyle-lsp\"", .text = response });
    try expect_contains(.{ .part = "\"source.fixAll\"", .text = response });
    try expect_contains(.{ .part = "\"workspaceFolders\"", .text = response });
    try expect_contains(.{ .part = "\"changeNotifications\":true", .text = response });

    session.close();
}

test "two changes in one message apply in order" {
    const gpa = std.testing.allocator;
    const uri = "file:///tmp/ordered.rs";
    var session: Session = undefined;

    try named_session(&session, gpa, std.testing.io, .{
        .text = "fn helper() {\\n    let a = 1; let b = 2;\\n}\\n",
        .uri = uri,
    });

    defer session.deinit();

    try change_ranged(
        &session,
        gpa,
        .{
            .changes =
            \\{"range":{"start":{"line":1,"character":8},"end":{"line":1,"character":9}},
            ++
                \\"text":"alphaName"},
            ++
                "\n           " ++
                \\{"range":{"start":{"line":1,"character":27},"end":{"line":1,"character":28}},
            ++
                \\"text":"betaName"}
            ,
            .uri = uri,
        },
        2,
    );

    const published = try session.receive(gpa);
    defer gpa.free(published);

    try expect_contains(.{ .part = "TS032", .text = published });
    try expect_characters(gpa, published, &.{ 8, 17, 27, 35 });

    session.close();
}

test "a non bmp character shifts the columns a utf sixteen client reads" {
    const gpa = std.testing.allocator;
    const uri = "file:///tmp/wide.rs";
    var session: Session = undefined;

    try named_session(&session, gpa, std.testing.io, .{ .text = wide_text, .uri = uri });
    defer session.deinit();

    try diagnostic_request(&session, gpa, 7, uri);

    const report = try session.receive(gpa);
    defer gpa.free(report);

    try expect_contains(.{ .part = "TS032", .text = report });
    try expect_characters(gpa, report, &.{ 22, 30 });

    session.close();
}

test "a non bmp character shifts them further for a utf eight client" {
    const gpa = std.testing.allocator;
    const uri = "file:///tmp/wide.rs";
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    try session.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,
    ++
        \\"rootUri":null,"capabilities":{"general":{"positionEncodings":["utf-8",
    ++
        \\"utf-16"]}}}}
    );

    try expect_received(&session, gpa, "\"positionEncoding\":\"utf-8\"");
    try session.send(initialized);
    try expect_received(&session, gpa, "client/registerCapability");
    try open_discard(&session, gpa, .{ .text = wide_text, .uri = uri });
    try configuration_answer(&session, gpa, "{\"extendSelect\":[\"TS032\"]}");

    const published = try session.receive(gpa);
    defer gpa.free(published);

    try expect_contains(.{ .part = "TS032", .text = published });
    try expect_characters(gpa, published, &.{ 24, 32 });

    session.close();
}

test "a backward range is refused and the document stands" {
    const gpa = std.testing.allocator;
    const uri = "file:///tmp/backward.rs";
    var session: Session = undefined;

    try named_session(&session, gpa, std.testing.io, .{ .text = named_text, .uri = uri });
    defer session.deinit();

    try change_ranged(
        &session,
        gpa,
        .{
            .changes =
            \\{"range":{"start":{"line":1,"character":13},"end":{"line":1,"character":8}},
            ++
                \\"text":"x"}
            ,
            .uri = uri,
        },
        2,
    );

    const published = try session.receive(gpa);
    defer gpa.free(published);

    try expect_contains(.{ .part = "TS032", .text = published });
    try expect_characters(gpa, published, &.{ 8, 16 });
    try diagnostic_request(&session, gpa, 8, uri);

    const report = try session.receive(gpa);
    defer gpa.free(report);

    try expect_contains(.{ .part = "\"id\":8", .text = report });
    try expect_characters(gpa, report, &.{ 8, 16 });

    session.close();
}

test "a range past the end is refused and the document stands" {
    const gpa = std.testing.allocator;
    const uri = "file:///tmp/beyond.rs";
    var session: Session = undefined;

    try named_session(&session, gpa, std.testing.io, .{ .text = named_text, .uri = uri });
    defer session.deinit();

    try change_ranged(
        &session,
        gpa,
        .{
            .changes =
            \\{"range":{"start":{"line":99,"character":0},"end":{"line":99,"character":4}},
            ++
                \\"text":"x"}
            ,
            .uri = uri,
        },
        2,
    );

    const published = try session.receive(gpa);
    defer gpa.free(published);

    try expect_characters(gpa, published, &.{ 8, 16 });
    try diagnostic_request(&session, gpa, 8, uri);
    try expect_received(&session, gpa, "\"id\":8");

    session.close();
}

test "an edit that removes the violation publishes nothing" {
    const gpa = std.testing.allocator;
    const uri = "file:///tmp/healed.rs";
    var session: Session = undefined;

    try named_session(&session, gpa, std.testing.io, .{ .text = named_text, .uri = uri });
    defer session.deinit();

    try change_ranged(
        &session,
        gpa,
        .{
            .changes =
            \\{"range":{"start":{"line":1,"character":8},"end":{"line":1,"character":16}},
            ++
                \\"text":"value"}
            ,
            .uri = uri,
        },
        2,
    );

    const published = try session.receive(gpa);
    defer gpa.free(published);

    try expect_contains(.{ .part = "publishDiagnostics", .text = published });
    try expect_contains(.{ .part = "\"diagnostics\":[]", .text = published });

    session.close();
}
