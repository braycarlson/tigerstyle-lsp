const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const cli = @import("cli.zig");
const Facts = scylla.path.Stat;
const Lint = @import("lint.zig");
const Resolver = scylla.config.Resolver;
const Stamps = scylla.watch.Stamps;
const Workspace = @import("workspace.zig");

configs: Stamps,
stamps: Stamps,

const Watch = @This();

pub const Capacity = struct {
    config_count_max: u32,
    file_count_max: u32,
};

const Swept = struct {
    changed: bool,
    reconfigured: bool,
};

const screen_clear = "\x1b[2J\x1b[H";
const sweep_count_max: u64 = 1 << 48;

pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Watch {
    assert(capacity.config_count_max > 0);
    assert(capacity.file_count_max > 0);

    var configs: Stamps = try .init(gpa, capacity.config_count_max);
    errdefer configs.deinit(gpa);

    const stamps: Stamps = try .init(gpa, capacity.file_count_max);
    return .{ .configs = configs, .stamps = stamps };
}

pub fn run(watch: *Watch, lint: *Lint) u8 {
    assert(watch.configs.count() == 0);
    assert(watch.stamps.count() == 0);

    for (0..sweep_count_max) |_| {
        const sweep = watch.swept(lint.io, &lint.configuration.resolver, &lint.workspace);

        if (sweep.reconfigured) lint.reconfigure();

        if (sweep.changed) {
            lint.output.line(screen_clear, .{});
            _ = lint.sweep();
        }

        scylla.watch.rest(lint.io) catch |err| switch (err) {
            error.Canceled => return cli.exit_success,
        };
    } else unreachable;
}

fn swept(
    watch: *Watch,
    io: std.Io,
    resolver: *const Resolver,
    workspace: *const Workspace,
) Swept {
    var changed = false;
    var reconfigured = false;

    for (0..resolver.chain_count()) |index| {
        const stamp = scylla.path.stat_of(io, resolver.chain_at(@intCast(index)));

        if (recorded(&watch.configs, @intCast(index), stamp)) reconfigured = true;
    }

    for (0..workspace.count()) |index| {
        const stamp = scylla.path.stat_of(io, workspace.path(@intCast(index)));

        if (recorded(&watch.stamps, @intCast(index), stamp)) changed = true;
    }

    assert(watch.configs.count() <= watch.configs.capacity());
    assert(watch.stamps.count() <= watch.stamps.capacity());

    return .{ .changed = changed or reconfigured, .reconfigured = reconfigured };
}

fn recorded(stamps: *Stamps, index: u32, stamp: ?Facts) bool {
    assert(stamps.capacity() > 0);

    const change = stamps.record(index, stamp) catch |err| switch (err) {
        error.Overflow => return false,
    };

    return change == .changed;
}
