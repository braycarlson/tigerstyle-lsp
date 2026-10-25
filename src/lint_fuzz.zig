const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const fuzz = @import("testing/fuzz.zig");
const PRNG = scylla.testing.PRNG;

const Mode = enum {
    check,
    config,
    fix,
    suppress,
};

const argument_count_max = 10;
const event_count_default = 256;
const source_bytes_max = 4_096;
const source_names = [_][]const u8{ "a.go", "a.js", "a.odin", "a.py", "a.rs", "a.ts", "a.zig" };

const code_fragments = [_][]const u8{
    "fn",
    "def",
    "func",
    "proc",
    "const",
    "let",
    "var",
    "if",
    "else",
    "for",
    "while",
    "return",
    "assert",
    "try",
    "except",
    "struct",
    "import",
    "package",
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
    "!=",
    "&&",
    "or",
    "+",
    "-",
    "*",
    "\"",
    "'",
    "`",
    "//",
    "#",
    "/*",
    "*/",
    "\n",
    " ",
    "    ",
    "\t",
    "\r\n",
    "0",
    "1.5",
    "value",
    "maxVal",
    "x",
    "\u{e9}",
    "# noqa",
    "// tigerstyle-ignore: TS001",
    "unsafe",
    "panic(",
    "TODO",
};

const config_fragments = [_][]const u8{
    "[lint]",
    "[format]",
    "select",
    "ignore",
    "extend-select",
    "per-file-ignores",
    "preview",
    "fix",
    "unfixable",
    "line-length",
    " = ",
    "\"TS001\"",
    "\"ALL\"",
    "[",
    "]",
    ",",
    "true",
    "false",
    "100",
    "-1",
    "\n",
    "#",
    "\"",
    "{",
    "}",
    "'",
    "\u{e9}",
    " ",
};

comptime {
    assert(argument_count_max >= 8);
    assert(source_names.len == 7);
}

pub fn main(gpa: std.mem.Allocator, io: std.Io, args: fuzz.FuzzArgs) !void {
    var prng = PRNG.init(args.seed);
    const events_max = args.events_max orelse event_count_default;
    var source_buffer: [source_bytes_max]u8 = undefined;

    for (0..events_max) |_| {
        const mode = prng.enum_uniform(Mode);
        const name = source_names[prng.index(source_names.len)];

        const fragments: []const []const u8 = switch (mode) {
            .config => &config_fragments,
            .check, .fix, .suppress => &code_fragments,
        };

        const source = fuzz.source_generate(&prng, fragments, &source_buffer);

        try run(gpa, io, mode, name, source);
    }
}

fn run(gpa: std.mem.Allocator, io: std.Io, mode: Mode, name: []const u8, source: []const u8) !void {
    assert(name.len > 0);
    assert(std.unicode.utf8ValidateSlice(source));

    var arguments: [argument_count_max][]const u8 = undefined;
    const argv = arguments_of(mode, name, &arguments);

    var child = try fuzz.binary_spawn(io, argv);
    defer child.kill(io);

    const stdin = child.stdin.?;

    child.stdin = null;

    stdin.writeStreamingAll(io, source) catch |err| switch (err) {
        error.BrokenPipe => {},
        else => |failure| {
            stdin.close(io);

            return failure;
        },
    };

    stdin.close(io);

    try fuzz.binary_finish(gpa, io, &child);
}

fn arguments_of(
    mode: Mode,
    name: []const u8,
    arguments: *[argument_count_max][]const u8,
) []const []const u8 {
    const head = [_][]const u8{ fuzz.binary_path, "check", "--isolated", "--stdin-filename" };

    const tail: []const []const u8 = switch (mode) {
        .check => &.{ name, "--extend-select", "ALL", "-" },
        .config => &.{ "a.toml", "--show-settings", "-" },
        .fix => &.{ name, "--fix-only", "--extend-select", "ALL", "-" },
        .suppress => &.{ name, "--add-suppressions", "--extend-select", "ALL", "-" },
    };

    assert(head.len + tail.len <= argument_count_max);

    @memcpy(arguments[0..head.len], &head);
    @memcpy(arguments[head.len..][0..tail.len], tail);

    const count = head.len + tail.len;

    assert(std.mem.eql(u8, arguments[count - 1], "-"));

    return arguments[0..count];
}

test "lint fuzz smoke" {
    try main(std.testing.allocator, std.testing.io, .{ .events_max = 16, .seed = 123 });
}
