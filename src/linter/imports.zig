const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Buffer = scylla.Buffer;
const Front = scylla.Front;
const Fronts = scylla.Fronts;

consulted: bool,
fronts: Fronts,
io: std.Io,
joined: []u8,
located: Buffer,
parsed: Buffer,
source: []u8,
source_length: u32,

const Imports = @This();

pub const Capacity = struct {
    front: Front.Capacity,
    path_bytes_max: u32,
    source_bytes_max: u32,
};

pub const File = struct {
    front: *const Front,
    path: []const u8,
    source: []const u8,
};

pub const Opening = struct {
    from: []const u8,
    specifier: []const u8,
};

const extension = ".zig";
const test_kind_source = "pub const Kind = enum { a, b };\n";

pub const test_capacity: Capacity = .{
    .front = .{
        .diagnostic_count_max = 64,
        .event_count_max = 1 << 12,
        .node_count_max = 1 << 10,
        .semantic = null,
        .tag_count_max = 64,
        .token_count_max = 1 << 11,
    },
    .path_bytes_max = 512,
    .source_bytes_max = 1 << 14,
};

pub fn init(
    imports: *Imports,
    gpa: std.mem.Allocator,
    io: std.Io,
    capacity: *const Capacity,
) std.mem.Allocator.Error!void {
    assert(capacity.front.semantic == null);
    assert(capacity.path_bytes_max > 0);
    assert(capacity.source_bytes_max > 0);

    imports.consulted = false;
    imports.io = io;
    imports.source_length = 0;

    try imports.fronts.init(gpa, &capacity.front, .initOne(.zig), &.{});
    errdefer imports.fronts.deinit(gpa);

    imports.joined = try gpa.alloc(u8, capacity.path_bytes_max);
    errdefer gpa.free(imports.joined);

    imports.located = try .init(gpa, capacity.path_bytes_max);
    errdefer imports.located.deinit(gpa);

    imports.parsed = try .init(gpa, capacity.path_bytes_max);
    errdefer imports.parsed.deinit(gpa);

    imports.source = try gpa.alloc(u8, capacity.source_bytes_max);

    assert(imports.parsed.empty());
    assert(imports.source.len == capacity.source_bytes_max);
}

pub fn deinit(imports: *Imports, gpa: std.mem.Allocator) void {
    assert(imports.source_length < imports.source.len);

    gpa.free(imports.source);
    imports.parsed.deinit(gpa);
    imports.located.deinit(gpa);
    gpa.free(imports.joined);
    imports.fronts.deinit(gpa);
    imports.* = undefined;
}

pub fn reset(imports: *Imports) void {
    imports.consulted = false;
    imports.parsed.clear();

    assert(imports.parsed.empty());
    assert(!imports.consulted);
}

pub fn open(imports: *Imports, opening: *const Opening) ?File {
    assert(opening.specifier.len > 0);

    if (!std.mem.endsWith(u8, opening.specifier, extension)) return null;

    const base = imports.located_of(opening.from) orelse return null;

    const length = scylla.path.join(imports.joined, .{
        .base = scylla.path.directory_of(base),
        .relative = opening.specifier,
    }) catch return null;

    const joined = imports.joined[0..length];

    assert(joined.len > 0);

    if (std.mem.eql(u8, joined, imports.parsed.const_slice())) return imports.current();

    imports.parsed.clear();

    const body = std.Io.Dir.cwd().readFile(imports.io, joined, imports.source) catch return null;
    if (body.len == imports.source.len) return null;

    imports.consulted = true;

    _ = imports.fronts.parse(.of(.zig), body) catch return null;

    imports.parsed.push(joined) catch return null;
    imports.source_length = @intCast(body.len);

    return imports.current();
}

fn located_of(imports: *Imports, from: []const u8) ?[]const u8 {
    if (from.len == 0) return null;

    scylla.uri.decode(&imports.located, from) catch |err| switch (err) {
        error.Overflow => return null,
        error.SchemeNotFile => return from,
    };

    if (imports.located.empty()) return null;
    return imports.located.const_slice();
}

pub fn current(imports: *const Imports) ?File {
    assert(imports.source_length < imports.source.len);

    if (imports.parsed.empty()) return null;

    return .{
        .front = imports.fronts.front(.zig),
        .path = imports.parsed.const_slice(),
        .source = imports.source[0..imports.source_length],
    };
}

test "an import resolves beside the file that names it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = false });
    defer temporary.cleanup();

    try temporary.dir.writeFile(io, .{ .sub_path = "kind.zig", .data = test_kind_source });
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "" });

    const from = try std.Io.Dir.path.join(gpa, &.{
        std.testing.TmpDir.parent_dir_path,
        &temporary.sub_path,
        "main.zig",
    });
    defer gpa.free(from);

    var imports: Imports = undefined;

    try imports.init(gpa, io, &test_capacity);
    defer imports.deinit(gpa);

    try std.testing.expect(imports.open(&.{ .from = from, .specifier = "std" }) == null);
    try std.testing.expect(imports.open(&.{ .from = from, .specifier = "absent.zig" }) == null);
    try std.testing.expect(imports.open(&.{ .from = "", .specifier = "kind.zig" }) == null);
    try std.testing.expect(!imports.consulted);

    const file = imports.open(&.{ .from = from, .specifier = "kind.zig" }).?;

    try std.testing.expect(imports.consulted);
    try std.testing.expect(std.mem.endsWith(u8, file.path, "kind.zig"));
    try std.testing.expectEqualStrings(test_kind_source, file.source);
    try std.testing.expect(file.front.node_count() > 1);

    const again = imports.open(&.{ .from = from, .specifier = "./kind.zig" }).?;

    try std.testing.expectEqual(file.front, again.front);
    try std.testing.expectEqualStrings(file.path, again.path);

    imports.reset();

    try std.testing.expect(!imports.consulted);
    try std.testing.expect(imports.parsed.empty());
}

test "an import resolves beside a file named by its uri" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = false });
    defer temporary.cleanup();

    try temporary.dir.writeFile(io, .{ .sub_path = "kind.zig", .data = test_kind_source });
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "" });

    const absolute = try temporary.dir.realPathFileAlloc(io, "main.zig", gpa);
    defer gpa.free(absolute);

    var uri: Buffer = try .init(gpa, 1024);
    defer uri.deinit(gpa);

    try scylla.uri.encode(&uri, absolute);

    var imports: Imports = undefined;

    try imports.init(gpa, io, &test_capacity);
    defer imports.deinit(gpa);

    const file = imports.open(&.{ .from = uri.const_slice(), .specifier = "kind.zig" }).?;

    try std.testing.expectEqualStrings(test_kind_source, file.source);
    try std.testing.expect(scylla.path.is_absolute(file.path));
}
