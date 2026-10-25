const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");
const Workspace = @import("testing/workspace.zig");

const Body = struct {
    extension: []const u8,
    language: []const u8,
    template: []const u8,
};

const bodies = [_]Body{
    .{
        .extension = "go",
        .language = "go",
        .template = "func helper_%d(value int) int {\n\tif value > 0 {\n" ++
            "\t\treturn value\n\t}\n\n\treturn 0\n}\n",
    },
    .{
        .extension = "js",
        .language = "javascript",
        .template = "function helper_%d(value) {\n    if (value > 0) {\n        return value;\n" ++
            "    }\n\n    return 0;\n}\n",
    },
    .{
        .extension = "odin",
        .language = "odin",
        .template = "helper_%d :: proc(value: int) -> int {\n    if value > 0 {\n" ++
            "        return value\n    }\n\n    return 0\n}\n",
    },
    .{
        .extension = "py",
        .language = "python",
        .template = "def helper_%d(value):\n    if value > 0:\n        return value\n\n" ++
            "    return 0\n",
    },
    .{
        .extension = "rs",
        .language = "rust",
        .template = "fn helper_%d(value: u32) -> u32 {\n    if value > 0 {\n" ++
            "        return value;\n    }\n\n    0\n}\n",
    },
    .{
        .extension = "ts",
        .language = "typescript",
        .template = "function helper_%d(value: number): number {\n    if (value > 0) {\n" ++
            "        return value;\n    }\n\n    return 0;\n}\n",
    },
    .{
        .extension = "zig",
        .language = "zig",
        .template = "fn helper_%d(value: u32) u32 {\n    if (value > 0) {\n" ++
            "        return value;\n    }\n\n    return 0;\n}\n",
    },
};

const line_count = 10_000;
const placeholder = "%d";

comptime {
    @setEvalBranchQuota(1 << 16);

    for (bodies) |body| {
        assert(std.mem.count(u8, body.template, placeholder) == 1);
        assert(std.mem.endsWith(u8, body.template, "\n"));
    }
}

fn source(gpa: std.mem.Allocator, template: []const u8) ![]u8 {
    const at = std.mem.find(u8, template, placeholder).?;
    const template_line_count = std.mem.countScalar(u8, template, '\n');

    assert(template_line_count > 0);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);

    var text_line_count: usize = 0;

    for (0..line_count + 1) |index| {
        if (text_line_count >= line_count) break;

        try text.appendSlice(gpa, template[0..at]);
        try text.print(gpa, "{d}", .{index});
        try text.appendSlice(gpa, template[at + placeholder.len ..]);
        text_line_count += template_line_count;
    } else unreachable;

    assert(std.mem.countScalar(u8, text.items, '\n') == text_line_count);

    return text.toOwnedSlice(gpa);
}

fn measured(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !i64 {
    assert(path.len > 0);

    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "check", "--isolated", "--format", "concise", path });

    const started = std.Io.Clock.Timestamp.now(io, .awake);

    var output = try command.output(gpa, io);
    defer output.deinit(gpa);

    const elapsed = started.untilNow(io);

    try std.testing.expect(output.code != null);

    return elapsed.raw.toMicroseconds();
}

fn reported() bool {
    return std.testing.environ.containsConstant("TIGERSTYLE_BENCH");
}

test "every language checks ten thousand lines" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const reporting = reported();

    var workspace: Workspace = try .init(gpa, io, "bench", "languages");
    defer workspace.deinit();

    if (reporting) std.debug.print("{{\n", .{});

    for (bodies, 0..) |body, index| {
        const name = try gpa.print("bench.{s}", .{body.extension});
        defer gpa.free(name);

        const text = try source(gpa, body.template);
        defer gpa.free(text);

        const path = try workspace.write(name, text);
        const microseconds = try measured(gpa, io, path);
        const comma = if (index + 1 == bodies.len) "" else ",";

        try std.testing.expect(microseconds >= 0);

        if (reporting) {
            std.debug.print("  \"{s}\": {{\"microseconds\": {d}, \"lines\": {d}}}{s}\n", .{
                body.language,
                microseconds,
                line_count,
                comma,
            });
        }
    }

    if (reporting) std.debug.print("}}\n", .{});
}
