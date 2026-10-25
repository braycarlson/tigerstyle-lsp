const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Source = struct {
    path: []const u8,
    text: [:0]const u8,
};

const Sources = std.ArrayList(Source);
const source_directories = [_][]const u8{ "examples", "src" };

const entry_points = [_][]const u8{
    "examples/lint.zig",
    "src/corpus_test.zig",
    "src/fuzz_tests.zig",
    "src/golden_findings_test.zig",
    "src/golden_tokens_test.zig",
    "src/latency_test.zig",
    "src/main.zig",
    "src/matrix_test.zig",
    "src/precision_test.zig",
    "src/unit_tests.zig",
    "src/watch_test.zig",
};

const test_roots = [_][]const u8{
    "src/corpus_test.zig",
    "src/golden_findings_test.zig",
    "src/golden_tokens_test.zig",
    "src/latency_test.zig",
    "src/matrix_test.zig",
    "src/precision_test.zig",
    "src/unit_tests.zig",
    "src/watch_test.zig",
};

const banned = [_][]const u8{
    "std.debug." ++ "assert(",
    "Self = " ++ "@This()",
    "== " ++ "error.",
    "!= " ++ "error.",
    "using" ++ "namespace",
    "@" ++ "Type(",
    "@" ++ "cImport",
};

const file_count_max = 4_096;
const function_lines_max = 70;
const import_count_max = 1 << 16;
const line_columns_max = 100;
const line_count_max = 1 << 20;
const source_bytes_max = 1 << 22;

test "tidy" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var sources: Sources = .empty;
    defer sources_free(gpa, &sources);

    try sources_read(gpa, io, &sources);

    var problems: u32 = 0;

    for (sources.items) |source| {
        problems += file_name_check(source.path);
        problems += lines_check(source);
        problems += try functions_check(gpa, source);
    }

    problems += try imports_check(gpa, sources.items);
    problems += try test_roots_check(gpa, sources.items);

    try std.testing.expect(sources.items.len >= entry_points.len);
    try std.testing.expectEqual(0, problems);
}

fn sources_read(gpa: std.mem.Allocator, io: std.Io, sources: *Sources) !void {
    for (source_directories) |name| try directory_read(gpa, io, sources, name);

    const path = try gpa.dupe(u8, "build.zig");
    errdefer gpa.free(path);

    try sources.append(gpa, .{ .path = path, .text = try source_read(gpa, io, path) });
}

fn directory_read(gpa: std.mem.Allocator, io: std.Io, sources: *Sources, name: []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, name, .{ .iterate = true });
    defer directory.close(io);

    var walker = try directory.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        assert(sources.items.len < file_count_max);

        const path = try gpa.print("{s}/{s}", .{ name, entry.path });
        errdefer gpa.free(path);

        if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, path, '\\', '/');

        try sources.append(gpa, .{ .path = path, .text = try source_read(gpa, io, path) });
    }
}

fn source_read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]const u8 {
    assert(path.len > 0);

    const text = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(source_bytes_max),
        .of(u8),
        0,
    );

    assert(text.len <= source_bytes_max);

    return text;
}

fn sources_free(gpa: std.mem.Allocator, sources: *Sources) void {
    for (sources.items) |source| {
        gpa.free(source.path);
        gpa.free(source.text);
    }

    sources.deinit(gpa);
}

fn file_name_check(path: []const u8) u32 {
    const name = std.Io.Dir.path.basename(path);

    assert(name.len > 0);

    const allowed = "abcdefghijklmnopqrstuvwxyz0123456789_.";
    if (std.mem.findNone(u8, name, allowed) == null) return 0;

    std.debug.print("{s}: the file name is not snake_case\n", .{path});

    return 1;
}

fn lines_check(source: Source) u32 {
    var problems: u32 = 0;
    var lines = std.mem.splitScalar(u8, source.text, '\n');
    var line_number: u32 = 0;

    while (lines.next()) |line| {
        line_number += 1;

        assert(line_number <= line_count_max);

        problems += line_check(source.path, line_number, line);
    }

    if (!std.mem.endsWith(u8, source.text, "\n")) {
        std.debug.print("{s}: the file does not end with a newline\n", .{source.path});

        problems += 1;
    }

    return problems;
}

fn line_check(path: []const u8, line_number: u32, line: []const u8) u32 {
    var problems: u32 = 0;

    const columns = std.unicode.utf8CountCodepoints(line) catch line.len;

    if (columns > line_columns_max) {
        std.debug.print("{s}:{d}: the line is wider than 100 columns\n", .{ path, line_number });

        problems += 1;
    }

    if (std.mem.findAny(u8, line, "\t\r") != null) {
        std.debug.print("{s}:{d}: the line holds a tab or a carriage return\n", .{
            path,
            line_number,
        });

        problems += 1;
    }

    if (std.mem.endsWith(u8, line, " ")) {
        std.debug.print("{s}:{d}: the line ends in whitespace\n", .{ path, line_number });

        problems += 1;
    }

    for (banned) |pattern| {
        if (std.mem.find(u8, line, pattern) == null) continue;

        std.debug.print("{s}:{d}: the line holds {s}\n", .{ path, line_number, pattern });

        problems += 1;
    }

    return problems;
}

fn functions_check(gpa: std.mem.Allocator, source: Source) !u32 {
    var ast = try std.zig.Ast.parse(gpa, source.text, .{ .mode = .zig, .recover = true });
    defer ast.deinit(gpa);

    var problems: u32 = 0;

    for (0..ast.nodes.len) |index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (ast.nodeTag(node) != .fn_decl) continue;

        const first = ast.tokenLocation(0, ast.firstToken(node)).line;
        const last = ast.tokenLocation(0, ast.lastToken(node)).line;
        const lines = last - first + 1;

        assert(last >= first);

        if (lines > function_lines_max) {
            std.debug.print("{s}:{d}: the function is {d} lines long\n", .{
                source.path,
                first + 1,
                lines,
            });

            problems += 1;
        }
    }

    return problems;
}

fn imports_check(gpa: std.mem.Allocator, sources: []const Source) !u32 {
    var imported: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer imported_free(gpa, &imported);

    for (sources) |source| {
        try imports_collect(gpa, source, &imported);
    }

    var problems: u32 = 0;

    for (sources) |source| {
        if (std.mem.eql(u8, source.path, "build.zig")) continue;
        if (imported.contains(source.path)) continue;
        if (is_entry_point(source.path)) continue;

        std.debug.print("{s}: the file is imported from nowhere\n", .{source.path});

        problems += 1;
    }

    return problems;
}

fn test_roots_check(gpa: std.mem.Allocator, sources: []const Source) !u32 {
    var reached: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer imported_free(gpa, &reached);

    for (test_roots) |root| try reached.put(gpa, try gpa.dupe(u8, root), {});

    var index: usize = 0;

    while (index < reached.count()) : (index += 1) {
        assert(reached.count() <= file_count_max);

        const source = source_named(sources, reached.keys()[index]) orelse continue;

        try imports_collect(gpa, source, &reached);
    }

    var problems: u32 = 0;

    for (sources) |source| {
        if (reached.contains(source.path)) continue;
        if (!declares_tests(source.text)) continue;

        std.debug.print("{s}: the tests are reached from no test root\n", .{source.path});

        problems += 1;
    }

    return problems;
}

fn source_named(sources: []const Source, path: []const u8) ?Source {
    assert(path.len > 0);

    for (sources) |source| {
        if (std.mem.eql(u8, source.path, path)) return source;
    }

    return null;
}

fn declares_tests(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_number: u32 = 0;

    while (lines.next()) |line| {
        line_number += 1;

        assert(line_number <= line_count_max);

        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "test ")) return true;
    }

    return false;
}

fn imports_collect(
    gpa: std.mem.Allocator,
    source: Source,
    imported: *std.StringArrayHashMapUnmanaged(void),
) !void {
    const directory = std.Io.Dir.path.dirname(source.path) orelse ".";
    const marker = "@import(\"";

    var offset: usize = 0;
    var count: u32 = 0;

    while (std.mem.findPos(u8, source.text, offset, marker)) |found| {
        count += 1;

        assert(count <= import_count_max);

        const start = found + marker.len;
        const end = std.mem.findScalarPos(u8, source.text, start, '"') orelse break;
        const target = source.text[start..end];

        offset = end;

        if (!std.mem.endsWith(u8, target, ".zig")) continue;

        const resolved = try std.Io.Dir.path.resolveAllocPosix(gpa, &.{ directory, target });
        const entry = try imported.getOrPut(gpa, resolved);

        if (entry.found_existing) gpa.free(resolved);
    }
}

fn imported_free(gpa: std.mem.Allocator, imported: *std.StringArrayHashMapUnmanaged(void)) void {
    for (imported.keys()) |key| gpa.free(key);

    imported.deinit(gpa);
}

fn is_entry_point(path: []const u8) bool {
    assert(path.len > 0);

    for (entry_points) |entry_point| {
        if (std.mem.eql(u8, path, entry_point)) return true;
    }

    return false;
}
