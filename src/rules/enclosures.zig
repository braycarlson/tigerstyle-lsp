const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Category = scylla.View.Category;
const Front = scylla.Front;
const Index = scylla.LineIndex;
const StaticAllocator = scylla.StaticAllocator;

calls_ordered: bool,
enclosing: []u32,
ends: []u32,
limits: []u32,
ordered: [category_count]bool,
ranges: [category_count]Range,
starts: []u32,

const Enclosures = @This();

pub const Chain = struct {
    count: u32,
    positions: [chain_capacity]u32,
};

const Innermost = union(enum) {
    absent,
    found: u32,
    unordered,
};

const Range = struct {
    base: u32,
    count: u32,
};

const categories = [_]Category{
    .block,
    .branch,
    .except,
    .function,
    .lambda,
    .loop,
    .match,
    .@"struct",
    .@"try",
};

pub const chain_capacity: u32 = 64;
const category_count = categories.len;
const entry_none: u32 = std.math.maxInt(u32);

comptime {
    assert(chain_capacity > 0);
    assert(category_count == 9);
}

pub fn init(gpa: std.mem.Allocator, entry_count_max: u32) std.mem.Allocator.Error!Enclosures {
    assert(entry_count_max > 0);
    assert(entry_count_max < entry_none);

    const enclosing = try StaticAllocator.reserve(u32, gpa, entry_count_max);
    errdefer StaticAllocator.release(u32, gpa, enclosing);

    const ends = try StaticAllocator.reserve(u32, gpa, entry_count_max);
    errdefer StaticAllocator.release(u32, gpa, ends);

    const limits = try StaticAllocator.reserve(u32, gpa, entry_count_max);
    errdefer StaticAllocator.release(u32, gpa, limits);

    const starts = try StaticAllocator.reserve(u32, gpa, entry_count_max);

    return .{
        .calls_ordered = false,
        .enclosing = enclosing,
        .ends = ends,
        .limits = limits,
        .ordered = @splat(false),
        .ranges = @splat(.{ .base = 0, .count = 0 }),
        .starts = starts,
    };
}

pub fn deinit(enclosures: *Enclosures, gpa: std.mem.Allocator) void {
    assert(enclosures.starts.len == enclosures.limits.len);
    assert(enclosures.starts.len == enclosures.ends.len);

    StaticAllocator.release(u32, gpa, enclosures.enclosing);
    StaticAllocator.release(u32, gpa, enclosures.ends);
    StaticAllocator.release(u32, gpa, enclosures.limits);
    StaticAllocator.release(u32, gpa, enclosures.starts);
    enclosures.* = undefined;
}

pub fn build(
    enclosures: *Enclosures,
    front: *const Front,
    lines: *const Index,
    source: []const u8,
) void {
    var base: u32 = 0;

    for (categories, 0..) |category, slot| {
        const count: u32 = @intCast(front.nodes_of(category).len);

        assert(base + count <= enclosures.starts.len);

        enclosures.ranges[slot] = .{ .base = base, .count = count };
        enclosures.ordered[slot] = enclosures.category_build(front, lines, source, slot);
        base += count;
    }

    enclosures.calls_ordered = offsets_ascend(front, .call);

    assert(base <= front.node_count());
}

fn category_build(
    enclosures: *Enclosures,
    front: *const Front,
    lines: *const Index,
    source: []const u8,
    slot: usize,
) bool {
    assert(slot < enclosures.ranges.len);

    const range = enclosures.ranges[slot];
    const positions = front.nodes_of(categories[slot]);

    assert(positions.len == range.count);

    for (positions, 0..) |position, ordinal| {
        const entry = range.base + @as(u32, @intCast(ordinal));
        const view = front.view(position) orelse return false;
        const span = view.span();
        const line = lines.line_of(span.end() -| 1);

        if (ordinal > 0) {
            if (span.offset < enclosures.starts[entry - 1]) return false;
        }

        enclosures.starts[entry] = span.offset;
        enclosures.ends[entry] = span.end();
        enclosures.limits[entry] = lines.line_span(line, source).end();

        enclosures.enclosing[entry] = enclosures.enclosing_of(.{
            .base = range.base,
            .entry = entry,
        });
    }

    return true;
}

fn offsets_ascend(front: *const Front, category: Category) bool {
    const positions = front.nodes_of(category);
    var previous: u32 = 0;

    assert(positions.len <= front.node_count());

    for (positions) |position| {
        const view = front.view(position) orelse return false;
        const offset = view.span().offset;
        if (offset < previous) return false;

        previous = offset;
    }

    return true;
}

fn enclosing_of(enclosures: *const Enclosures, options: struct { base: u32, entry: u32 }) u32 {
    assert(options.entry >= options.base);

    const start = enclosures.starts[options.entry];
    var candidate = if (options.entry == options.base) entry_none else options.entry - 1;

    for (0..options.entry - options.base + 1) |_| {
        if (candidate == entry_none) return entry_none;

        assert(candidate >= options.base);
        assert(candidate < options.entry);

        if (enclosures.reach_of(candidate) > start) return candidate;

        candidate = enclosures.enclosing[candidate];
    }

    unreachable;
}

fn reach_of(enclosures: *const Enclosures, entry: u32) u32 {
    assert(entry < enclosures.limits.len);

    return @max(enclosures.limits[entry], enclosures.ends[entry]);
}

pub fn slot_of(category: Category) ?u32 {
    for (categories, 0..) |held, slot| {
        if (held == category) return @intCast(slot);
    }

    return null;
}

pub fn chain_fill(
    enclosures: *const Enclosures,
    front: *const Front,
    options: struct { offset: u32, slot: u32 },
    chain: *Chain,
) bool {
    assert(options.slot < category_count);

    chain.count = 0;

    if (!enclosures.ordered[options.slot]) return false;

    const range = enclosures.ranges[options.slot];
    const positions = front.nodes_of(categories[options.slot]);
    var entry = enclosures.entry_at_or_before(range, options.offset) orelse return true;

    assert(positions.len == range.count);

    for (0..range.count) |_| {
        assert(enclosures.starts[entry] <= options.offset);

        if (options.offset < enclosures.limits[entry]) {
            if (chain.count == chain_capacity) return false;

            chain.positions[chain.count] = positions[entry - range.base];
            chain.count += 1;
        }

        entry = enclosures.enclosing[entry];

        if (entry == entry_none) return true;
    }

    unreachable;
}

pub fn innermost(
    enclosures: *const Enclosures,
    front: *const Front,
    options: struct { offset: u32, slot: u32 },
) Innermost {
    assert(options.slot < category_count);

    if (!enclosures.ordered[options.slot]) return .unordered;

    const range = enclosures.ranges[options.slot];
    const positions = front.nodes_of(categories[options.slot]);
    var entry = enclosures.entry_at_or_before(range, options.offset) orelse return .absent;

    assert(positions.len == range.count);

    for (0..range.count) |_| {
        assert(enclosures.starts[entry] <= options.offset);

        if (options.offset < enclosures.ends[entry]) return .{
            .found = positions[entry - range.base],
        };

        entry = enclosures.enclosing[entry];

        if (entry == entry_none) return .absent;
    }

    unreachable;
}

fn entry_at_or_before(enclosures: *const Enclosures, range: Range, offset: u32) ?u32 {
    assert(range.base + range.count <= enclosures.starts.len);

    const starts = enclosures.starts[range.base..][0..range.count];
    const after = std.sort.partitionPoint(u32, starts, offset, start_at_or_before);

    assert(after <= starts.len);

    if (after == 0) return null;

    const entry = range.base + @as(u32, @intCast(after - 1));

    assert(entry < range.base + range.count);

    return entry;
}

fn start_at_or_before(offset: u32, start: u32) bool {
    return start <= offset;
}
