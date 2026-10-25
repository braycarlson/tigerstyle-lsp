const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");

arena: std.heap.ArenaAllocator,
io: std.Io,
root: []const u8,

const Workspace = @This();
const body_bytes_max = 1 << 22;
const suffix_length = 8;

pub fn init(gpa: std.mem.Allocator, io: std.Io, suite: []const u8, name: []const u8) !Workspace {
    assert(suite.len > 0);
    assert(name.len > 0);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    var suffix_bytes: [suffix_length]u8 = undefined;

    io.random(&suffix_bytes);

    const suffix = std.fmt.bytesToHex(suffix_bytes, .lower);
    var base_bytes: [cli.temporary_bytes_max]u8 = undefined;
    const base = cli.temporary_root(&base_bytes);

    const root = try arena.allocator().print("{s}/tigerstyle-lsp-{s}-{s}-{s}", .{
        base,
        suite,
        name,
        &suffix,
    });

    try std.Io.Dir.cwd().createDirPath(io, root);

    assert(root.len > base.len);

    return .{ .arena = arena, .io = io, .root = root };
}

pub fn deinit(workspace: *Workspace) void {
    assert(workspace.root.len > 0);

    std.Io.Dir.cwd().deleteTree(workspace.io, workspace.root) catch |err| {
        std.debug.print("{s} could not be removed: {s}\n", .{ workspace.root, @errorName(err) });
    };

    workspace.arena.deinit();
    workspace.* = undefined;
}

pub fn path(workspace: *Workspace, name: []const u8) ![]const u8 {
    assert(name.len > 0);
    assert(!std.Io.Dir.path.isAbsolute(name));

    return std.Io.Dir.path.join(workspace.arena.allocator(), &.{ workspace.root, name });
}

pub fn write(workspace: *Workspace, name: []const u8, body: []const u8) ![]const u8 {
    const target = try workspace.path(name);
    const cwd = std.Io.Dir.cwd();

    if (std.Io.Dir.path.dirname(target)) |parent| try cwd.createDirPath(workspace.io, parent);

    try cwd.writeFile(workspace.io, .{ .sub_path = target, .data = body });

    assert(target.len > workspace.root.len);

    return target;
}

pub fn directory(workspace: *Workspace, name: []const u8) ![]const u8 {
    const target = try workspace.path(name);

    try std.Io.Dir.cwd().createDirPath(workspace.io, target);

    assert(target.len > workspace.root.len);

    return target;
}

pub fn read(workspace: *Workspace, name: []const u8) ![]const u8 {
    const target = try workspace.path(name);
    const limit: std.Io.Limit = .limited(body_bytes_max);

    return std.Io.Dir.cwd().readFileAlloc(workspace.io, target, workspace.arena.allocator(), limit);
}

pub fn exists(workspace: *Workspace, name: []const u8) !bool {
    const target = try workspace.path(name);

    std.Io.Dir.cwd().access(workspace.io, target, .{}) catch return false;

    return true;
}

test "a workspace holds what it writes and leaves nothing behind" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, "workspace", "round-trip");

    const root = try gpa.dupe(u8, workspace.root);
    defer gpa.free(root);

    _ = try workspace.write("deep/a.rs", "fn main() {}\n");

    try std.testing.expectEqualStrings("fn main() {}\n", try workspace.read("deep/a.rs"));
    try std.testing.expect(try workspace.exists("deep/a.rs"));
    try std.testing.expect(!try workspace.exists("deep/b.rs"));

    workspace.deinit();

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, root, .{}));
}
