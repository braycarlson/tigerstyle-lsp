const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const PRNG = scylla.testing.PRNG;

pub const FuzzArgs = struct {
    events_max: ?u32,
    seed: u64,
};

pub const binary_path = @import("cli.zig").binary_path;
const fragment_count_max = 256;
const exit_code_max = 2;
const git_commit_length = 40;
const guard_tripped = "allocation guard tripped";
const stderr_bytes_max = 1 << 24;
const stderr_chunk_bytes = 4_096;

pub fn parse_seed(text: []const u8) error{InvalidSeed}!u64 {
    if (text.len == 0) return error.InvalidSeed;

    if (text.len == git_commit_length) {
        comptime assert(git_commit_length * 4 == @bitSizeOf(u160));

        const commit = std.fmt.parseUnsigned(u160, text, 16) catch return error.InvalidSeed;
        return @truncate(commit);
    }

    const seed = std.fmt.parseUnsigned(u64, text, 10) catch return error.InvalidSeed;

    assert(text.len < git_commit_length);

    return seed;
}

pub fn binary_spawn(io: std.Io, arguments: []const []const u8) !std.process.Child {
    assert(arguments.len > 1);
    assert(std.mem.eql(u8, arguments[0], binary_path));

    const child = try std.process.spawn(io, .{
        .argv = arguments,
        .stderr = .pipe,
        .stdin = .pipe,
        .stdout = .ignore,
    });

    assert(child.stdin != null);
    assert(child.stderr != null);

    return child;
}

pub fn binary_finish(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child) !void {
    assert(child.stdin == null);
    assert(child.stderr != null);

    var buffer: [stderr_chunk_bytes]u8 = undefined;
    var reader = child.stderr.?.reader(io, &buffer);

    const stderr = try reader.interface.allocRemaining(gpa, .limited(stderr_bytes_max));
    defer gpa.free(stderr);

    const term = try child.wait(io);

    outcome_check(stderr, term);
}

fn outcome_check(stderr: []const u8, term: std.process.Child.Term) void {
    if (std.mem.find(u8, stderr, guard_tripped) != null) {
        std.debug.panic("the allocation guard tripped: {s}", .{stderr});
    }

    const code = switch (term) {
        .exited => |value| value,
        .signal, .stopped, .unknown => std.debug.panic("the binary did not exit: {s}", .{stderr}),
    };

    if (code > exit_code_max) std.debug.panic("the binary exited {d}: {s}", .{ code, stderr });

    assert(code <= exit_code_max);
}

pub fn source_generate(prng: *PRNG, fragments: []const []const u8, buffer: []u8) []const u8 {
    assert(fragments.len > 0);
    assert(buffer.len > 0);

    const fragment_count = prng.int_inclusive(u32, fragment_count_max);
    var length: u32 = 0;

    for (0..fragment_count) |_| {
        const fragment = fragments[prng.index(fragments.len)];
        if (length + fragment.len > buffer.len) break;

        @memcpy(buffer[length..][0..fragment.len], fragment);
        length += @intCast(fragment.len);
    }

    assert(length <= buffer.len);

    return buffer[0..length];
}

test "a seed reads as a decimal or as a commit hash" {
    try std.testing.expectEqual(123, try parse_seed("123"));

    try std.testing.expectEqual(
        0xfedcba9876543210,
        try parse_seed("0123456789abcdef0123456789abcdeffedcba9876543210"[8..]),
    );

    try std.testing.expectError(error.InvalidSeed, parse_seed(""));
    try std.testing.expectError(error.InvalidSeed, parse_seed("seed"));
}

test "a generated source joins whole fragments within its buffer" {
    var prng = PRNG.init(7);
    var buffer: [16]u8 = undefined;

    for (0..64) |_| {
        const source = source_generate(&prng, &.{ "ab", "c" }, &buffer);
        const pairs = std.mem.count(u8, source, "ab");
        const seconds = std.mem.countScalar(u8, source, 'b');

        try std.testing.expect(source.len <= buffer.len);
        try std.testing.expectEqual(pairs, seconds);
    }
}
