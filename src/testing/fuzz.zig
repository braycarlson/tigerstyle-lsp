const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");

pub const Arguments = struct {
    events_max: ?u32,
    seed: u64,
};

pub const binary_path = @import("../harness/cli.zig").binary_path;
pub const parse_seed = scylla.testing.fuzz.parse_seed;
pub const source_generate = scylla.testing.fuzz.source_generate;
const exit_code_max = 2;
const guard_tripped = "allocation guard tripped";
const stderr_bytes_max = 1 << 24;
const stderr_chunk_bytes = 4_096;

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
