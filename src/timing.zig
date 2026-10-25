const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");

pub const Clock = scylla.timing.Clock;

pub const Stage = enum(u32) {
    front,
    rules,
    tables,

    pub fn index(stage: Stage) u32 {
        const result = @backingInt(stage);

        assert(result < stage_count);
        assert(stage_names[result].len > 0);

        return result;
    }

    pub fn name(stage: Stage) []const u8 {
        const result = stage_names[stage.index()];

        assert(std.mem.eql(u8, result, @tagName(stage)));

        return result;
    }
};

pub const Timings = scylla.timing.TimingsType(Stage, scylla.limits.rule_count_max);
pub const stage_count: u32 = @typeInfo(Stage).@"enum".field_names.len;

pub const stage_names = [stage_count][]const u8{
    "front",
    "rules",
    "tables",
};

comptime {
    assert(stage_count == 3);

    for (std.enums.values(Stage), 0..) |stage, position| {
        assert(@backingInt(stage) == position);
        assert(std.mem.eql(u8, stage_names[position], @tagName(stage)));
    }
}

test "the stage indices are distinct and named" {
    var static_allocator: scylla.StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    const stages = [_]Stage{ .front, .rules, .tables };

    for (stages, 0..) |stage, position| {
        try std.testing.expectEqual(@as(u32, @intCast(position)), stage.index());
        try std.testing.expect(stage_names[stage.index()].len > 0);
        try std.testing.expectEqualStrings(stage_names[position], stage.name());
    }
}
