const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const cache = @import("cache.zig");
const cli = @import("../config/options.zig");
const Buffer = scylla.Buffer;
const Limits = @import("../limits.zig");
const Options = cli.Options;
const Span = scylla.Span;

directories: Buffer,
io: std.Io,
removed: u32,
roots: scylla.ArrayType(Span),

const Clean = @This();
const report_bytes_max: u32 = 64;
const report_format = "removed {d} cache directories\n";

comptime {
    assert(report_bytes_max >= report_format.len + std.fmt.count("{d}", .{std.math.maxInt(u32)}));
}

pub fn init(
    clean: *Clean,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    limits: *const Limits,
) std.mem.Allocator.Error!void {
    assert(options.mode == .clean);
    assert(limits.path_bytes_max <= scylla.limits.path_bytes_max);

    clean.io = io;
    clean.removed = 0;
    clean.directories = try .init(gpa, limits.workspace_bytes_max);
    clean.roots = try .init(gpa, limits.glob_count_max);

    const named = cache.directory_named(options.cache_directory) orelse cache.directory_default;

    if (options.paths.empty()) {
        clean.root_record(named, limits);

        return;
    }

    for (options.paths.const_slice()) |path| {
        var buffer: [scylla.limits.path_bytes_max]u8 = undefined;

        const length = joined(&buffer, .{ .base = path, .named = named }) catch |err| switch (err) {
            error.Overflow => continue,
        };

        clean.root_record(buffer[0..length], limits);
    }

    assert(clean.roots.count() <= options.paths.count());
}

pub fn run(clean: *Clean) u8 {
    assert(clean.removed == 0);

    for (clean.roots.const_slice()) |root| {
        if (clean.root_removed(root)) clean.removed += 1;
    }

    assert(clean.removed <= clean.roots.count());

    var buffer: [report_bytes_max]u8 = undefined;
    const report = std.mem.print(&buffer, report_format, .{clean.removed}) catch unreachable;

    std.Io.File.stdout().writeStreamingAll(clean.io, report) catch return cli.exit_failure;

    return cli.exit_success;
}

fn root_record(clean: *Clean, directory: []const u8, limits: *const Limits) void {
    assert(directory.len > 0);
    if (directory.len > limits.path_bytes_max) return;
    if (scylla.path.stat_of(clean.io, directory) == null) return;
    if (clean.roots.full()) return;

    const offset = clean.directories.count();

    clean.directories.push(directory) catch return;
    clean.roots.push(.{ .offset = offset, .length = @intCast(directory.len) });

    assert(clean.directories.count() == offset + directory.len);
}

fn root_removed(clean: *Clean, root: Span) bool {
    assert(root.end() <= clean.directories.const_slice().len);

    const root_path = root.text(clean.directories.const_slice());
    assert(root_path.len > 0);

    scylla.path.remove_tree(clean.io, root_path) catch return false;

    return true;
}

fn joined(
    target: []u8,
    options: struct { base: []const u8, named: []const u8 },
) Buffer.CapacityError!u32 {
    assert(options.named.len > 0);

    if (scylla.path.is_absolute(options.named)) return Buffer.written(target, &.{options.named});
    if (options.base.len == 0) return Buffer.written(target, &.{options.named});

    if (options.base[options.base.len - 1] == '/') return Buffer.written(target, &.{
        options.base,
        options.named,
    });

    return Buffer.written(target, &.{ options.base, "/", options.named });
}
