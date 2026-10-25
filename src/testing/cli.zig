const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const Command = struct {
    arguments: std.ArrayList([]const u8),
    binary: []u8,
    cwd: ?[]const u8,
    environment: std.process.Environ.Map,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Command {
        const base = try root(gpa, io);
        defer gpa.free(base);

        const binary = try std.Io.Dir.path.join(gpa, &.{ base, binary_path });
        errdefer gpa.free(binary);

        var environment = try std.testing.environ.createMap(gpa);
        errdefer environment.deinit();

        var arguments: std.ArrayList([]const u8) = .empty;
        errdefer arguments.deinit(gpa);

        try arguments.append(gpa, binary);

        assert(arguments.items.len == 1);
        assert(std.Io.Dir.path.isAbsolute(binary));

        return .{
            .arguments = arguments,
            .binary = binary,
            .cwd = null,
            .environment = environment,
        };
    }

    pub fn deinit(runner: *Command, gpa: std.mem.Allocator) void {
        assert(runner.arguments.items.len >= 1);
        assert(runner.arguments.items[0].ptr == runner.binary.ptr);

        runner.arguments.deinit(gpa);
        runner.environment.deinit();
        gpa.free(runner.binary);
        runner.* = undefined;
    }

    pub fn argument(runner: *Command, gpa: std.mem.Allocator, text: []const u8) !void {
        assert(runner.arguments.items.len >= 1);
        assert(runner.arguments.items.len < argument_count_max);

        try runner.arguments.append(gpa, text);
    }

    pub fn arguments_add(
        runner: *Command,
        gpa: std.mem.Allocator,
        texts: []const []const u8,
    ) !void {
        const argument_count = runner.arguments.items.len;

        assert(argument_count >= 1);

        for (texts) |text| try runner.argument(gpa, text);

        assert(runner.arguments.items.len == argument_count + texts.len);
    }

    pub fn directory_set(runner: *Command, directory: []const u8) void {
        assert(directory.len > 0);
        assert(runner.cwd == null);

        runner.cwd = directory;
    }

    pub fn environment_remove(runner: *Command, key: []const u8) void {
        assert(key.len > 0);

        _ = runner.environment.swapRemove(key);

        assert(!runner.environment.contains(key));
    }

    pub fn environment_set(runner: *Command, key: []const u8, value: []const u8) !void {
        assert(key.len > 0);

        try runner.environment.put(key, value);

        assert(runner.environment.contains(key));
    }

    pub fn output(runner: *const Command, gpa: std.mem.Allocator, io: std.Io) !Output {
        assert(runner.arguments.items.len >= 1);
        assert(runner.arguments.items.len <= argument_count_max);

        const result = try std.process.run(gpa, io, .{
            .argv = runner.arguments.items,
            .cwd = runner.cwd_of(),
            .environ_map = &runner.environment,
        });

        return .{ .code = code_of(result.term), .stderr = result.stderr, .stdout = result.stdout };
    }

    pub fn output_piped(
        runner: *const Command,
        gpa: std.mem.Allocator,
        io: std.Io,
        input: []const u8,
    ) !Output {
        assert(runner.arguments.items.len >= 1);
        assert(runner.arguments.items.len <= argument_count_max);

        var child = try std.process.spawn(io, .{
            .argv = runner.arguments.items,
            .cwd = runner.cwd_of(),
            .environ_map = &runner.environment,
            .stderr = .pipe,
            .stdin = .pipe,
            .stdout = .pipe,
        });

        defer child.kill(io);

        const stdin = child.stdin.?;

        child.stdin = null;

        stdin.writeStreamingAll(io, input) catch |err| {
            stdin.close(io);

            return err;
        };

        stdin.close(io);

        return collected(gpa, io, &child);
    }

    pub fn spawn(runner: *const Command, io: std.Io) !Running {
        assert(runner.arguments.items.len >= 1);
        assert(runner.arguments.items.len <= argument_count_max);

        const child = try std.process.spawn(io, .{
            .argv = runner.arguments.items,
            .cwd = runner.cwd_of(),
            .environ_map = &runner.environment,
            .stderr = .pipe,
            .stdin = .ignore,
            .stdout = .pipe,
        });

        assert(child.stdout != null);
        assert(child.stderr != null);

        return .{ .child = child };
    }

    fn cwd_of(runner: *const Command) std.process.Child.Cwd {
        const directory = runner.cwd orelse return .inherit;

        assert(directory.len > 0);

        return .{ .path = directory };
    }
};

const Running = struct {
    child: std.process.Child,

    pub fn kill(running: *Running, io: std.Io) void {
        running.child.kill(io);

        assert(running.child.id == null);
    }

    pub fn stop(running: *Running, gpa: std.mem.Allocator, io: std.Io) !Output {
        const id = running.child.id orelse unreachable;

        try terminated(id);

        const output = try collected(gpa, io, &running.child);

        assert(running.child.id == null);

        return output;
    }
};

fn terminated(id: std.process.Child.Id) error{ PermissionDenied, Unexpected }!void {
    if (windows) {
        const status = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(@as(u32, 1)));

        switch (status) {
            .SUCCESS, .PROCESS_IS_TERMINATING, .ACCESS_DENIED => {},
            else => return error.Unexpected,
        }
    } else {
        std.posix.kill(id, .KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            error.PermissionDenied, error.Unexpected => |failure| return failure,
        };
    }
}

fn collected(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child) !Output {
    assert(child.stdin == null);
    assert(child.stdout != null);
    assert(child.stderr != null);

    var buffers: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;

    multi_reader.init(gpa, io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    for (0..fill_count_max) |_| {
        multi_reader.fill(fill_bytes, .none) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |failure| return failure,
        };
    } else unreachable;

    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);

    const stderr = try multi_reader.toOwnedSlice(1);
    return .{ .code = code_of(term), .stderr = stderr, .stdout = stdout };
}

pub const Output = struct {
    code: ?u8,
    stderr: []u8,
    stdout: []u8,

    pub fn deinit(output: *Output, gpa: std.mem.Allocator) void {
        gpa.free(output.stderr);
        gpa.free(output.stdout);
        output.* = undefined;
    }

    pub fn code_or_negative(output: *const Output) i32 {
        const code: i32 = if (output.code) |value| value else -1;

        assert(code >= -1);
        assert(code <= std.math.maxInt(u8));

        return code;
    }

    pub fn success(output: *const Output) bool {
        const code = output.code orelse return false;
        return code == 0;
    }
};

pub const Lines = struct {
    rest: []const u8,

    pub fn init(text: []const u8) Lines {
        return .{ .rest = text };
    }

    pub fn next(lines: *Lines) ?[]const u8 {
        if (lines.rest.len == 0) return null;

        const rest_length = lines.rest.len;

        const end = std.mem.findScalar(u8, lines.rest, '\n') orelse {
            const last = lines.rest;

            lines.rest = lines.rest[lines.rest.len..];

            return last;
        };

        const line = lines.rest[0..end];

        lines.rest = lines.rest[end + 1 ..];

        assert(lines.rest.len < rest_length);

        if (std.mem.endsWith(u8, line, "\r")) return line[0 .. line.len - 1];
        return line;
    }
};

const Listed = struct {
    items: []const []const u8,

    pub fn format(listed_items: Listed, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("[");

        for (listed_items.items, 0..) |item, index| {
            if (index > 0) try writer.writeAll(", ");

            try writer.print("\"{s}\"", .{item});
        }

        try writer.writeAll("]");
    }
};

const Components = struct {
    offset: u32,
    path: []const u8,

    fn init(path: []const u8) Components {
        assert(path.len <= std.math.maxInt(u32));

        return .{ .offset = 0, .path = path };
    }

    fn next(components: *Components) ?[]const u8 {
        const path = components.path;

        assert(components.offset <= path.len);

        if (components.offset == 0) {
            if (std.mem.startsWith(u8, path, "/")) {
                components.offset = 1;

                return "/";
            }

            if (dot_leading(path)) {
                components.offset = 1;

                return ".";
            }
        }

        for (0..path.len + 1) |_| {
            const start = std.mem.findNonePos(u8, path, components.offset, "/") orelse {
                components.offset = @intCast(path.len);

                return null;
            };

            const end = std.mem.findScalarPos(u8, path, start, '/') orelse path.len;
            const part = path[start..end];

            components.offset = @intCast(end);

            assert(part.len > 0);

            if (std.mem.eql(u8, part, ".")) continue;
            return part;
        }

        unreachable;
    }
};

pub const binary_path = "zig-out" ++ separator ++ "bin" ++ separator ++ "tigerstyle-lsp" ++
    builtin.target.exeFileExt();

pub const temporary_bytes_max = 4_096;
const argument_count_max = 64;
const directory_count_max = 4_096;
const entry_count_max = 1 << 16;
const fill_bytes = 64;
const fill_count_max = 1 << 24;
const golden_bytes_max = 1 << 28;
const separator = std.Io.Dir.path.sep_str;
const windows = builtin.target.os.tag == .windows;

fn dot_leading(path: []const u8) bool {
    if (std.mem.eql(u8, path, ".")) return true;
    return std.mem.startsWith(u8, path, "./");
}

pub fn blessing() bool {
    return std.testing.environ.containsConstant("TIGERSTYLE_GOLDEN");
}

fn code_of(term: std.process.Child.Term) ?u8 {
    const code: ?u8 = switch (term) {
        .exited => |value| value,
        .signal, .stopped, .unknown => null,
    };

    if (code == null) assert(term != .exited);

    return code;
}

pub fn temporary_root(bytes: []u8) []const u8 {
    assert(bytes.len > 0);

    const length = if (windows) temporary_root_windows(bytes) else temporary_root_posix(bytes);

    assert(length > 0);
    assert(length <= bytes.len);

    return bytes[0..length];
}

fn temporary_root_posix(bytes: []u8) usize {
    assert(!windows);

    const directory = std.testing.environ.getPosix("TMPDIR") orelse "/tmp";

    if (directory.len > bytes.len) std.debug.panic("TMPDIR is longer than {d} bytes", .{bytes.len});

    @memcpy(bytes[0..directory.len], directory);

    return directory.len;
}

fn temporary_root_windows(bytes: []u8) usize {
    assert(windows);

    const key = std.unicode.wtf8ToWtf16LeStringLiteral("TEMP");
    const directory = std.testing.environ.getWindows(key) orelse @panic("TEMP is unset");

    if (std.unicode.calcWtf8Len(directory) > bytes.len) {
        std.debug.panic("TEMP is longer than {d} bytes", .{bytes.len});
    }

    return std.unicode.wtf16LeToWtf8(bytes, directory);
}

pub fn command(gpa: std.mem.Allocator, io: std.Io) !Command {
    var result: Command = try .init(gpa, io);
    errdefer result.deinit(gpa);

    result.environment_remove("CLICOLOR_FORCE");
    result.environment_remove("FORCE_COLOR");
    try result.environment_set("NO_COLOR", "1");
    try result.environment_set("TERM", "dumb");
    try result.environment_set("LC_ALL", "C.UTF-8");
    try result.environment_set("TIGERSTYLE_NO_CACHE", "1");

    assert(result.environment.contains("TIGERSTYLE_NO_CACHE"));
    assert(!result.environment.contains("FORCE_COLOR"));

    return result;
}

pub fn root(gpa: std.mem.Allocator, io: std.Io) ![:0]u8 {
    const path = try std.process.currentPathAlloc(io, gpa);

    assert(path.len > 0);
    assert(std.Io.Dir.path.isAbsolute(path));

    return path;
}

pub fn rooted(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    assert(path.len > 0);
    assert(!std.Io.Dir.path.isAbsolute(path));

    const base = try root(gpa, io);
    defer gpa.free(base);

    return std.Io.Dir.path.join(gpa, &.{ base, path });
}

pub fn golden(
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
    actual: []const u8,
    bless: []const u8,
) !void {
    assert(name.len > 0);
    assert(bless.len > 0);

    const path = try std.Io.Dir.path.join(gpa, &.{ directory, name });
    defer gpa.free(path);

    const cwd = std.Io.Dir.cwd();

    if (blessing()) {
        const parent = std.Io.Dir.path.dirname(path) orelse ".";

        try cwd.createDirPath(io, parent);
        try cwd.writeFile(io, .{ .sub_path = path, .data = actual });

        return;
    }

    const expected = cwd.readFileAlloc(io, path, gpa, .limited(golden_bytes_max)) catch |err| {
        std.debug.print("{s} is present; bless with {s}\n", .{ path, bless });

        return err;
    };

    defer gpa.free(expected);

    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("{s} differs; bless with {s}\n", .{ name, bless });
    }

    try std.testing.expectEqualStrings(expected, actual);
}

pub fn relative(gpa: std.mem.Allocator, path: []const u8, base: []const u8) ![]u8 {
    var remaining: Components = .init(path);
    var prefix: Components = .init(base);
    var stripped = true;

    for (0..base.len + 1) |_| {
        const expected = prefix.next() orelse break;

        const found = remaining.next() orelse {
            stripped = false;

            break;
        };

        if (!std.mem.eql(u8, expected, found)) {
            stripped = false;

            break;
        }
    }

    if (!stripped) remaining = .init(path);

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    for (0..path.len + 1) |_| {
        const part = remaining.next() orelse break;

        try parts.append(gpa, part);
    }

    assert(remaining.offset == remaining.path.len);

    return std.mem.join(gpa, "/", parts.items);
}

pub fn joined(gpa: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    const text = try std.mem.join(gpa, "\n", lines);
    defer gpa.free(text);

    const result = if (text.len == 0) try gpa.dupe(u8, "") else try std.mem.concat(
        gpa,
        u8,
        &.{ text, "\n" },
    );

    assert(result.len == 0 or result[result.len - 1] == '\n');
    assert(result.len >= text.len);

    return result;
}

pub fn manifest(gpa: std.mem.Allocator, io: std.Io, directory: []const u8) ![]u8 {
    assert(directory.len > 0);

    var entries: std.ArrayList([]const u8) = .empty;
    defer lines_free(gpa, &entries);

    try walk(gpa, io, directory, &entries);

    std.mem.sort([]const u8, entries.items, {}, text_less);

    return joined(gpa, entries.items);
}

pub fn sha256(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const text = std.fmt.bytesToHex(digest, .lower);

    assert(text.len == 64);
    assert(digest.len == 32);

    return text;
}

pub fn is_directory(io: std.Io, path: []const u8) bool {
    assert(path.len > 0);

    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

pub fn is_file(io: std.Io, path: []const u8) bool {
    assert(path.len > 0);

    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

pub fn listed(items: []const []const u8) Listed {
    return .{ .items = items };
}

pub fn lines_free(gpa: std.mem.Allocator, lines: *std.ArrayList([]const u8)) void {
    assert(lines.items.len <= lines.capacity);

    for (lines.items) |line| gpa.free(line);

    lines.deinit(gpa);
    lines.* = undefined;
}

pub fn text_less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn walk(
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    entries: *std.ArrayList([]const u8),
) !void {
    var opened = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer opened.close(io);

    var walker = try opened.walk(gpa);
    defer walker.deinit();

    var directory_count: u32 = 1;

    for (0..entry_count_max) |_| {
        const entry = try walker.next(io) orelse break;

        if (entry.kind == .directory) {
            directory_count += 1;

            assert(directory_count <= directory_count_max);

            continue;
        }

        if (std.mem.eql(u8, entry.path, "MANIFEST.txt")) continue;

        const bytes = try entry.dir.readFileAlloc(
            io,
            entry.basename,
            gpa,
            .limited(golden_bytes_max),
        );

        defer gpa.free(bytes);

        const digest = sha256(bytes);
        const line = try gpa.print("{s}  {s}", .{ entry.path, digest });
        errdefer gpa.free(line);

        if (windows) std.mem.replaceScalar(u8, line[0..entry.path.len], '\\', '/');

        try entries.append(gpa, line);
    } else unreachable;

    assert(entries.items.len < entry_count_max);
}

test "the relative path strips whole components" {
    const gpa = std.testing.allocator;
    const stripped = try relative(gpa, "/a/b/./c//d", "/a/b");
    defer gpa.free(stripped);

    const kept = try relative(gpa, "/a/bc/d", "/a/b");
    defer gpa.free(kept);

    try std.testing.expectEqualStrings("c/d", stripped);
    try std.testing.expectEqualStrings("//a/bc/d", kept);
}
