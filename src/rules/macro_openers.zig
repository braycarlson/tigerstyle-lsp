const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Conventions = @import("../conventions.zig");
const StaticAllocator = scylla.StaticAllocator;
const Token = scylla.Token;

count: u32,
indexes: []u32,
overflowed: bool,

const MacroOpeners = @This();
const opener_count_max: u32 = 1 << 16;

pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!MacroOpeners {
    const indexes = try StaticAllocator.reserve(u32, gpa, opener_count_max);

    assert(indexes.len == opener_count_max);

    return .{ .count = 0, .indexes = indexes, .overflowed = false };
}

pub fn deinit(openers: *MacroOpeners, gpa: std.mem.Allocator) void {
    assert(openers.count <= openers.indexes.len);

    StaticAllocator.release(u32, gpa, openers.indexes);
    openers.* = undefined;
}

pub fn build(openers: *MacroOpeners, tokens: []const Token, conventions: *const Conventions) void {
    openers.count = 0;
    openers.overflowed = false;

    if (!conventions.macros_invoke_with_bang) return;

    for (tokens, 0..) |token, index| {
        if (!token.opens_a_group_or_block()) continue;
        if (!opens_a_macro(tokens, @intCast(index))) continue;

        if (openers.count == openers.indexes.len) {
            openers.overflowed = true;

            return;
        }

        openers.indexes[openers.count] = @intCast(index);
        openers.count += 1;
    }

    assert(openers.count <= openers.indexes.len);
}

pub fn any_within(openers: *const MacroOpeners, floor: u32, ceiling: u32) bool {
    assert(floor <= ceiling);

    if (openers.overflowed) return true;

    const indexes = openers.indexes[0..openers.count];
    const after = std.sort.partitionPoint(u32, indexes, floor, below);

    assert(after <= indexes.len);

    if (after == indexes.len) return false;
    return indexes[after] < ceiling;
}

pub fn opens_a_macro(tokens: []const Token, index: u32) bool {
    assert(index < tokens.len);
    assert(tokens[index].opens_a_group_or_block());

    if (index == 0) return false;
    if (tokens[index - 1].is_punctuation(.bang)) return true;
    if (index == 1) return false;
    if (tokens[index - 1].kind != .identifier) return false;
    return tokens[index - 2].is_punctuation(.bang);
}

fn below(floor: u32, index: u32) bool {
    return index < floor;
}
