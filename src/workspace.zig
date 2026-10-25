const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const languages = @import("languages.zig");
const scan_module = @import("scan.zig");
const Draft = @import("config/draft.zig");
const FileWalk = scylla.FileWalk;
const Limits = @import("limits.zig");
const log = scylla.log;

entries: FileWalk,
path_bytes_max: u32,
walk: FileWalk,

const Workspace = @This();

pub const Capacity = struct {
    entry_bytes_max: u32,
    entry_count_max: u32,
    path_bytes_max: u32,
    walk_bytes_max: u32,
    walk_count_max: u32,
};

pub const Ignores = struct {
    gitignore: FileWalk.Ignores,
    gitignore_respected: bool,
    globs: scylla.glob.Filter,

    pub const Capacity = struct {
        glob_bytes_max: u32,
        glob_count_max: u32,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        capacity: Ignores.Capacity,
    ) std.mem.Allocator.Error!Ignores {
        assert(capacity.glob_count_max > 0);
        assert(capacity.glob_bytes_max > 0);

        var gitignore: FileWalk.Ignores = try .init(gpa, .{
            .arena_bytes_max = capacity.glob_bytes_max,
            .file_count_max = directory_count_max,
            .line_count_max = capacity.glob_count_max *| ignore_lines_per_glob,
            .text_bytes_max = ignore_text_bytes_max,
        }, .{});

        errdefer gitignore.deinit(gpa);

        const globs: scylla.glob.Filter = try .init(gpa, .{
            .byte_count_max = capacity.glob_bytes_max,
            .class_count_max = Limits.glob_class_count_max,
            .pattern_count_max = capacity.glob_count_max,
        }, .unanchored);

        return .{ .gitignore = gitignore, .gitignore_respected = true, .globs = globs };
    }

    pub fn deinit(ignores: *Ignores, gpa: std.mem.Allocator) void {
        assert(ignores.gitignore.count() <= directory_count_max);

        ignores.gitignore.deinit(gpa);
        ignores.globs.deinit(gpa);
        ignores.* = undefined;
    }

    pub fn apply(ignores: *Ignores, draft: *const Draft) void {
        var excludes = draft.glob_patterns(.exclude);
        var includes = draft.glob_patterns(.include);

        for (0..excludes.remaining) |_| {
            const pattern = excludes.next() orelse break;

            ignores.exclude(pattern) catch |err| skipped_log(err, pattern);
        }

        for (0..includes.remaining) |_| {
            const pattern = includes.next() orelse break;

            ignores.include(pattern) catch |err| skipped_log(err, pattern);
        }

        ignores.gitignore_respected = draft.respect_gitignore;

        assert(excludes.remaining == 0);
        assert(includes.remaining == 0);
    }

    pub fn exclude(ignores: *Ignores, pattern: []const u8) scylla.glob.Error!void {
        assert(ignores.gitignore.count() <= directory_count_max);

        return ignores.globs.exclude(pattern);
    }

    pub fn include(ignores: *Ignores, pattern: []const u8) scylla.glob.Error!void {
        assert(ignores.gitignore.count() <= directory_count_max);

        return ignores.globs.include(pattern);
    }
};

pub const RecordError = error{ EntriesExhausted, PathInvalid, PathTooLong };
const depth_max: u32 = 64;
const directory_count_max: u32 = 4_096;
const ignore_lines_per_glob: u32 = 8;
const ignore_text_bytes_max: u32 = 1 << 14;
const skipped_cache = ".tigerstyle_cache";
const skipped = FileWalk.skipped_default ++ [_][]const u8{skipped_cache};

pub fn init(gpa: std.mem.Allocator, capacity: *const Capacity) std.mem.Allocator.Error!Workspace {
    assert(capacity.entry_count_max > 0);
    assert(capacity.entry_bytes_max >= capacity.path_bytes_max);
    assert(capacity.walk_count_max >= capacity.entry_count_max);
    assert(capacity.walk_bytes_max >= capacity.entry_bytes_max);

    var entries: FileWalk = try .init(gpa, .{
        .arena_bytes_max = capacity.entry_bytes_max,
        .depth_max = depth_max,
        .entry_count_max = capacity.entry_count_max,
        .pending_max = directory_count_max,
    });

    errdefer entries.deinit(gpa);

    const walk: FileWalk = try .init(gpa, .{
        .arena_bytes_max = capacity.walk_bytes_max,
        .depth_max = depth_max,
        .entry_count_max = capacity.walk_count_max,
        .pending_max = directory_count_max,
    });

    return .{ .entries = entries, .path_bytes_max = capacity.path_bytes_max, .walk = walk };
}

pub fn deinit(workspace: *Workspace, gpa: std.mem.Allocator) void {
    assert(workspace.path_bytes_max > 0);

    workspace.entries.deinit(gpa);
    workspace.walk.deinit(gpa);
    workspace.* = undefined;
}

pub fn collect(
    workspace: *Workspace,
    io: std.Io,
    paths: []const []const u8,
    ignores: *Ignores,
) void {
    assert(workspace.count() == 0);
    assert(paths.len > 0);

    for (paths) |argument| {
        if (scylla.path.is_directory(io, argument)) {
            workspace.scan(io, argument, ignores);

            continue;
        }

        workspace.record(argument) catch |err| switch (err) {
            error.EntriesExhausted => {
                log.line("skipping a path that does not fit the workspace table", .{});
            },
            error.PathInvalid => {
                log.line("skipping a path tigerstyle-lsp cannot spell in UTF-8", .{});
            },
            error.PathTooLong => {
                log.line("skipping a path longer than {d} bytes", .{workspace.path_bytes_max});
            },
        };
    }

    workspace.settle();
}

pub fn count(workspace: *const Workspace) u32 {
    return workspace.entries.count();
}

pub fn path(workspace: *const Workspace, index: u32) []const u8 {
    assert(index < workspace.count());

    return workspace.entries.path_of(index);
}

pub fn record(workspace: *Workspace, bytes: []const u8) RecordError!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.PathInvalid;
    if (bytes.len > workspace.path_bytes_max) return error.PathTooLong;

    const entry_count_before = workspace.count();

    workspace.entries.record(bytes) catch |err| switch (err) {
        error.ArenaExhausted,
        error.DepthExceeded,
        error.EntriesExhausted,
        error.IgnoresExhausted,
        error.ListingExhausted,
        error.PathEmpty,
        error.PathTooLong,
        error.PendingExhausted,
        => return error.EntriesExhausted,
    };

    assert(workspace.count() == entry_count_before + 1);
}

pub fn scan(workspace: *Workspace, io: std.Io, root: []const u8, ignores: *Ignores) void {
    assert(root.len > 0);

    if (!std.unicode.utf8ValidateSlice(root)) {
        log.line("skipping a root tigerstyle-lsp cannot spell in UTF-8", .{});

        return;
    }

    const options: FileWalk.Options = .{
        .excludes = if (ignores.globs.excludes.empty()) null else &ignores.globs,
        .ignores = if (ignores.gitignore_respected) &ignores.gitignore else null,
        .skipped = &skipped,
    };

    workspace.walk.run(io, root, &options) catch |err| switch (err) {
        error.DepthExceeded => log.line("stopping the scan {d} directories deep", .{depth_max}),
        error.ArenaExhausted,
        error.EntriesExhausted,
        error.IgnoresExhausted,
        error.ListingExhausted,
        error.PathTooLong,
        error.PendingExhausted,
        => log.line("stopping the scan at {d} files", .{workspace.walk.count()}),
        error.Unopenable => {},
    };

    workspace.scan_record(ignores);
}

fn scan_record(workspace: *Workspace, ignores: *Ignores) void {
    const walked = workspace.walk.count();

    for (0..walked) |index| {
        const found = workspace.walk.path_of(@intCast(index));
        if (!ignores.globs.included(found)) continue;
        if (languages.of_path(found) == null) continue;

        workspace.entries.record(found) catch |err| switch (err) {
            error.ArenaExhausted,
            error.DepthExceeded,
            error.EntriesExhausted,
            error.IgnoresExhausted,
            error.ListingExhausted,
            error.PathEmpty,
            error.PathTooLong,
            error.PendingExhausted,
            => {
                log.line("stopping the scan at {d} files", .{workspace.entries.count()});

                return;
            },
        };
    }

    assert(workspace.walk.count() == walked);
}

fn settle(workspace: *Workspace) void {
    const entry_count_before = workspace.count();

    workspace.entries.sort();
    workspace.entries.dedup();

    assert(workspace.count() <= entry_count_before);
}

fn skipped_log(err: scylla.glob.Error, pattern: []const u8) void {
    const shown = scan_module.utf8_or(pattern, "<pattern>");

    assert(shown.len > 0);

    log.line("a pattern is skipped: {s} ({s})", .{ scylla.glob.message(err), shown });
}

fn scanned(ignore: []const u8, respected: bool) !u32 {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, &Limits.default.workspace());
    defer workspace.deinit(gpa);

    var ignores: Ignores = try .init(gpa, Limits.default.ignores());
    defer ignores.deinit(gpa);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "generated");
    try tmp.dir.writeFile(io, .{ .sub_path = "generated/keep.rs", .data = "fn main() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "generated.rs", .data = "fn main() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = ignore });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);

    ignores.gitignore_respected = respected;

    workspace.scan(io, root_buffer[0..root_length], &ignores);
    workspace.settle();

    if (workspace.count() == 1) {
        try std.testing.expect(std.mem.endsWith(u8, workspace.path(0), "generated.rs"));
    }

    return workspace.count();
}

fn scanned_past(source_count: u32, note_count: u32) !u32 {
    assert(source_count > 0);
    assert(note_count > 0);

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var capacity = Limits.default.workspace();

    capacity.entry_count_max = 4;

    var workspace: Workspace = try .init(gpa, &capacity);
    defer workspace.deinit(gpa);

    var ignores: Ignores = try .init(gpa, Limits.default.ignores());
    defer ignores.deinit(gpa);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "nested");

    var name_buffer: [32]u8 = undefined;

    for (0..note_count) |index| {
        const name = try std.mem.print(&name_buffer, "note_{d}.txt", .{index});

        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "notes\n" });
    }

    for (0..source_count) |index| {
        const name = try std.mem.print(&name_buffer, "nested/source_{d}.rs", .{index});

        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "fn main() {}\n" });
    }

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);

    workspace.scan(io, root_buffer[0..root_length], &ignores);

    return workspace.count();
}

test "files no language reads leave the workspace to the source files" {
    try std.testing.expectEqual(@as(u32, 3), try scanned_past(3, 12));
}

test "source files past the workspace are refused" {
    try std.testing.expectEqual(@as(u32, 4), try scanned_past(6, 12));
}

test "a negation reopens what an earlier pattern shut" {
    try std.testing.expectEqual(@as(u32, 2), try scanned("generated\n!generated\n", true));
    try std.testing.expectEqual(@as(u32, 1), try scanned("generated\n", true));
}

test "a directory pattern does not shut a file" {
    try std.testing.expectEqual(@as(u32, 1), try scanned("generated/\n", true));
}

test "an ignore file is read only when asked" {
    try std.testing.expectEqual(@as(u32, 2), try scanned("generated\n", false));
}

test record {
    var workspace: Workspace = try .init(std.testing.allocator, &Limits.default.workspace());
    defer workspace.deinit(std.testing.allocator);

    try workspace.record("/tmp/main.rs");
    try workspace.record("/tmp/other.py");
    try std.testing.expectEqual(@as(u32, 2), workspace.count());
    try std.testing.expectEqualStrings("/tmp/main.rs", workspace.path(0));
    try std.testing.expectEqualStrings("/tmp/other.py", workspace.path(1));
}

test "a long path is refused" {
    var capacity = Limits.default.workspace();

    capacity.path_bytes_max = 16;

    var workspace: Workspace = try .init(std.testing.allocator, &capacity);
    defer workspace.deinit(std.testing.allocator);

    const refused = workspace.record("/tmp/a-very-long-path/main.rs");

    try std.testing.expectError(error.PathTooLong, refused);
    try std.testing.expectEqual(@as(u32, 0), workspace.count());
}

test "a path tigerstyle lsp cannot spell is refused" {
    var workspace: Workspace = try .init(std.testing.allocator, &Limits.default.workspace());
    defer workspace.deinit(std.testing.allocator);

    try std.testing.expectError(error.PathInvalid, workspace.record("/tmp/\xed\xa0\x80a.rs"));
    try std.testing.expectEqual(@as(u32, 0), workspace.count());
}

test collect {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, &Limits.default.workspace());
    defer workspace.deinit(gpa);

    var ignores: Ignores = try .init(gpa, Limits.default.ignores());
    defer ignores.deinit(gpa);

    var draft: Draft = try .init(gpa, Limits.default.draft());
    defer draft.deinit(gpa);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.rs", .data = "fn main() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/other.py", .data = "x = 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/skip.py", .data = "x = 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "notes\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "target/build.rs", .data = "fn main() {}\n" });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);

    try draft.glob_add("**/skip.py", .exclude);
    ignores.apply(&draft);
    workspace.collect(io, &.{root_buffer[0..root_length]}, &ignores);

    try std.testing.expectEqual(@as(u32, 2), workspace.count());
    try std.testing.expect(std.mem.endsWith(u8, workspace.path(0), "main.rs"));
    try std.testing.expect(std.mem.endsWith(u8, workspace.path(1), "other.py"));
}
