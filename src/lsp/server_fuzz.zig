const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const fuzz = @import("../testing/fuzz.zig");
const PRNG = scylla.testing.PRNG;

const Frame = enum {
    split,
    whole,
};

const event_count_default = 64;
const source_bytes_max = 4_096;
const source_names = [_][]const u8{ "a.go", "a.js", "a.odin", "a.py", "a.rs", "a.ts", "a.zig" };

const fragments = [_][]const u8{
    "fn",
    "def",
    "func",
    "proc",
    "const",
    "let",
    "if",
    "else",
    "for",
    "return",
    "assert",
    "struct",
    "import",
    "(",
    ")",
    "{",
    "}",
    "[",
    "]",
    ";",
    ",",
    ".",
    ":",
    "=",
    "==",
    "\"",
    "'",
    "`",
    "\\",
    "//",
    "#",
    "/*",
    "*/",
    "\n",
    "\r\n",
    "\r",
    " ",
    "    ",
    "\t",
    "\x00",
    "\x1f",
    "0",
    "value",
    "maxVal",
    "\u{e9}",
    "\u{1F600}",
    "\u{2028}",
    "# noqa",
    "// tigerstyle-ignore: TS001",
};

const initialize =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
;

const initialized =
    \\{"jsonrpc":"2.0","method":"initialized","params":{}}
;

const shutdown =
    \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
;

const exit =
    \\{"jsonrpc":"2.0","method":"exit"}
;

comptime {
    assert(source_names.len == 7);
    assert(fragments.len > 32);
}

pub fn main(gpa: std.mem.Allocator, io: std.Io, args: fuzz.FuzzArgs) !void {
    var prng = PRNG.init(args.seed);
    const events_max = args.events_max orelse event_count_default;
    var source_buffer: [source_bytes_max]u8 = undefined;

    for (0..events_max) |_| {
        const name = source_names[prng.index(source_names.len)];
        const source = fuzz.source_generate(&prng, &fragments, &source_buffer);

        try session_run(gpa, io, name, source);
    }
}

fn session_run(gpa: std.mem.Allocator, io: std.Io, name: []const u8, source: []const u8) !void {
    assert(name.len > 0);
    assert(std.unicode.utf8ValidateSlice(source));

    var child = try fuzz.binary_spawn(io, &.{ fuzz.binary_path, "server" });
    defer child.kill(io);

    const stdin = child.stdin.?;

    child.stdin = null;

    session_drive(gpa, io, stdin, name, source) catch |err| switch (err) {
        error.BrokenPipe => {},
        else => |failure| {
            stdin.close(io);

            return failure;
        },
    };

    stdin.close(io);

    try fuzz.binary_finish(gpa, io, &child);
}

fn session_drive(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdin: std.Io.File,
    name: []const u8,
    source: []const u8,
) !void {
    const uri = try gpa.print("file:///fuzz/{s}", .{name});
    defer gpa.free(uri);

    const opened = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{" ++
            "\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"plaintext\",\"version\":1," ++
            "\"text\":{f}}}}}}}",
        .{ uri, std.json.fmt(source, .{}) },
    );

    defer gpa.free(opened);

    const changed = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{" ++
            "\"textDocument\":{{\"uri\":\"{s}\",\"version\":2}}," ++
            "\"contentChanges\":[{{\"text\":{f}}}]}}}}",
        .{ uri, std.json.fmt(source, .{}) },
    );

    defer gpa.free(changed);

    const diagnosed = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/diagnostic\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}}}}}}",
        .{uri},
    );

    defer gpa.free(diagnosed);

    try framed(gpa, io, stdin, initialize, .whole);
    try framed(gpa, io, stdin, initialized, .whole);
    try framed(gpa, io, stdin, opened, .whole);
    try framed(gpa, io, stdin, changed, .split);
    try framed(gpa, io, stdin, diagnosed, .whole);
    try framed(gpa, io, stdin, shutdown, .whole);
    try framed(gpa, io, stdin, exit, .whole);
}

fn framed(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdin: std.Io.File,
    body: []const u8,
    frame: Frame,
) !void {
    assert(body.len > 0);

    const header = try gpa.print("Content-Length: {d}\r\n\r\n", .{body.len});
    defer gpa.free(header);

    const middle = switch (frame) {
        .split => @divFloor(body.len, 2),
        .whole => 0,
    };

    assert(middle <= body.len);

    try stdin.writeStreamingAll(io, header);
    try stdin.writeStreamingAll(io, body[0..middle]);
    try stdin.writeStreamingAll(io, body[middle..]);
}

test "server fuzz smoke" {
    try main(std.testing.allocator, std.testing.io, .{ .events_max = 4, .seed = 123 });
}
