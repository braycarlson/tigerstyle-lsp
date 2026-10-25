const std = @import("std");
const assert = std.debug.assert;
const Session = @import("testing/session.zig");
const cli = @import("testing/cli.zig");

const Lines = std.ArrayList([]const u8);

const Transcript = struct {
    gpa: std.mem.Allocator,
    lines: Lines,
    release: []u8,
    root: [:0]u8,
    root_uri: []u8,

    fn init(gpa: std.mem.Allocator, io: std.Io) !Transcript {
        const release = try version(gpa, io);
        errdefer gpa.free(release);

        const root = try cli.root(gpa, io);
        errdefer gpa.free(root);

        const root_uri = try Session.uri_of(gpa, root);

        assert(release.len > 0);
        assert(root.len > 0);

        return .{
            .gpa = gpa,
            .lines = .empty,
            .release = release,
            .root = root,
            .root_uri = root_uri,
        };
    }

    fn deinit(transcript: *Transcript) void {
        const gpa = transcript.gpa;

        assert(transcript.root.len > 0);

        cli.lines_free(gpa, &transcript.lines);
        gpa.free(transcript.release);
        gpa.free(transcript.root);
        gpa.free(transcript.root_uri);
        transcript.* = undefined;
    }

    fn sent(transcript: *Transcript, session: *Session, body: []const u8) !void {
        try transcript.record("client", body);
        try session.send(body);
    }

    fn received(transcript: *Transcript, session: *Session) ![]u8 {
        const body = try session.receive(transcript.gpa);
        errdefer transcript.gpa.free(body);

        try transcript.record("server", body);

        return body;
    }

    fn received_discard(transcript: *Transcript, session: *Session) !void {
        const body = try transcript.received(session);

        transcript.gpa.free(body);
    }

    fn record(transcript: *Transcript, from: []const u8, body: []const u8) !void {
        const gpa = transcript.gpa;
        const trimmed = std.mem.trimEnd(u8, body, &std.ascii.whitespace);

        const located = try std.mem.replaceOwned(
            u8,
            gpa,
            trimmed,
            transcript.root_uri,
            "file://<root>",
        );

        defer gpa.free(located);

        const rooted = try std.mem.replaceOwned(u8, gpa, located, transcript.root, "<root>");
        defer gpa.free(rooted);

        const stable = try std.mem.replaceOwned(u8, gpa, rooted, transcript.release, "<version>");
        defer gpa.free(stable);

        const line = try gpa.print("{{\"from\":\"{s}\",\"body\":{s}}}", .{ from, stable });
        errdefer gpa.free(line);

        try transcript.lines.append(gpa, line);
    }

    fn text(transcript: *const Transcript) ![]u8 {
        return cli.joined(transcript.gpa, transcript.lines.items);
    }
};

const bless = "TIGERSTYLE_GOLDEN=1 cargo test --test golden_server";
const hex_digits = "0123456789abcdef";
const sample_bytes_max = 1 << 20;
const session_count = 5;

const samples = [_]struct { []const u8, []const u8 }{
    .{ "sample.go", "go" },
    .{ "sample.py", "python" },
    .{ "sample.rs", "rust" },
    .{ "sample.zig", "zig" },
};

fn version(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var command = try cli.command(gpa, io);
    defer command.deinit(gpa);

    try command.argument(gpa, "version");

    var output = try command.output(gpa, io);
    defer output.deinit(gpa);

    try std.testing.expect(output.success());

    return gpa.dupe(u8, std.mem.trim(u8, output.stdout, &std.ascii.whitespace));
}

fn escaped(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    for (text) |byte| {
        switch (byte) {
            '"' => try out.writer.writeAll("\\\""),
            '\\' => try out.writer.writeAll("\\\\"),
            '\n' => try out.writer.writeAll("\\n"),
            '\r' => try out.writer.writeAll("\\r"),
            '\t' => try out.writer.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const code = [_]u8{ hex_digits[byte >> 4], hex_digits[byte & 0x0f] };

                try out.writer.writeAll("\\u00");
                try out.writer.writeAll(&code);
            },
            else => try out.writer.writeByte(byte),
        }
    }

    return out.toOwnedSlice();
}

fn capture(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var transcript: Transcript = try .init(gpa, io);
    defer transcript.deinit();

    const fixtures = try cli.rooted(gpa, io, "tests/fixtures/lint");
    defer gpa.free(fixtures);

    const root = try Session.uri_of(gpa, fixtures);
    defer gpa.free(root);

    var session: Session = undefined;

    try session.start(gpa, io);
    defer session.deinit();

    const initialize = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"," ++
            "\"params\":{{\"processId\":null," ++
            "\"rootUri\":\"{s}\",\"capabilities\":{{}}}}}}",
        .{root},
    );

    defer gpa.free(initialize);

    try transcript.sent(&session, initialize);
    try transcript.received_discard(&session);
    try transcript.sent(&session, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    const registration = try transcript.received(&session);
    defer gpa.free(registration);

    try std.testing.expect(Session.contains(registration, "client/registerCapability"));

    for (samples) |sample| try sample_open(gpa, io, &transcript, &session, fixtures, sample);

    try transcript.sent(&session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}");

    const shutdown = try transcript.received(&session);
    defer gpa.free(shutdown);

    try std.testing.expect(Session.contains(shutdown, "\"result\":null"));
    try transcript.sent(&session, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var finished = try session.finish(gpa);
    defer finished.deinit(gpa);

    if (finished.code != 0) std.debug.print("{s}\n", .{finished.stderr});

    try std.testing.expectEqual(@as(i32, 0), finished.code);

    return transcript.text();
}

fn sample_open(
    gpa: std.mem.Allocator,
    io: std.Io,
    transcript: *Transcript,
    session: *Session,
    fixtures: []const u8,
    sample: struct { []const u8, []const u8 },
) !void {
    const path = try std.Io.Dir.path.join(gpa, &.{ fixtures, sample[0] });
    defer gpa.free(path);

    const uri = try Session.uri_of(gpa, path);
    defer gpa.free(uri);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(sample_bytes_max));
    defer gpa.free(source);

    const text = try escaped(gpa, source);
    defer gpa.free(text);

    const body = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"{s}\"," ++
            "\"version\":1,\"text\":\"{s}\"}}}}}}",
        .{ uri, sample[1], text },
    );

    defer gpa.free(body);

    try transcript.sent(session, body);
    try transcript.received_discard(session);
}

fn golden(gpa: std.mem.Allocator, io: std.Io, name: []const u8, actual: []const u8) !void {
    assert(name.len > 0);

    const directory = try cli.rooted(gpa, io, "tests/fixtures/golden-server");
    defer gpa.free(directory);

    try cli.golden(gpa, io, directory, name, actual, bless);
}

test "the transcript matches its golden" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const transcript = try capture(gpa, io);
    defer gpa.free(transcript);

    try golden(gpa, io, "transcript.jsonl", transcript);

    const directory = try cli.rooted(gpa, io, "tests/fixtures/golden-server");
    defer gpa.free(directory);

    const manifest = try cli.manifest(gpa, io, directory);
    defer gpa.free(manifest);

    try golden(gpa, io, "MANIFEST.txt", manifest);
}

test "five consecutive sessions agree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    if (cli.blessing()) return;

    const first = try capture(gpa, io);
    defer gpa.free(first);

    for (1..session_count) |round| {
        const again = try capture(gpa, io);
        defer gpa.free(again);

        if (!std.mem.eql(u8, first, again)) {
            std.debug.print("session {d} differs from the first\n", .{round});
        }

        try std.testing.expectEqualStrings(first, again);
    }
}
