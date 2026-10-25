const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Context = @import("context.zig");
const MacroOpeners = @import("macro_openers.zig");
const Token = scylla.Token;

depth: u32,
overflowed: bool,
position: u32,
stack: [macro_body_depth_max]?u32,

const MacroBodies = @This();
const macro_body_depth_max: u32 = 256;
const macro_scan_max: u32 = 2_048;

comptime {
    assert(macro_body_depth_max > 0);
    assert(macro_scan_max > 0);
}

pub const empty: MacroBodies = .{
    .depth = 0,
    .overflowed = false,
    .position = 0,
    .stack = undefined,
};

pub fn inside(bodies: *MacroBodies, context: *const Context, cursor: u32) bool {
    if (!context.conventions.macros_invoke_with_bang) return false;
    if (bodies.overflowed) return holds(context, cursor);

    const ceiling: u32 = @min(cursor, @as(u32, @intCast(context.tokens.len)));

    assert(bodies.position <= ceiling);

    if (!bodies.advanced(context.tokens, ceiling)) return holds(context, cursor);

    assert(bodies.position == ceiling);

    if (bodies.depth == 0) return false;

    const latest = bodies.stack[bodies.depth - 1] orelse return false;
    const floor = ceiling - @min(ceiling, macro_scan_max);

    assert(latest < ceiling);

    return latest >= floor;
}

fn advanced(bodies: *MacroBodies, tokens: []const Token, ceiling: u32) bool {
    assert(ceiling <= tokens.len);

    for (tokens[bodies.position..ceiling], bodies.position..) |token, index| {
        if (token.closes_a_group_or_block()) {
            if (bodies.depth > 0) bodies.depth -= 1;

            continue;
        }

        if (!token.opens_a_group_or_block()) continue;

        if (bodies.depth == macro_body_depth_max) {
            bodies.overflowed = true;

            return false;
        }

        const below = if (bodies.depth > 0) bodies.stack[bodies.depth - 1] else null;
        const opener: u32 = @intCast(index);
        const latest = if (MacroOpeners.opens_a_macro(tokens, opener)) opener else below;

        bodies.stack[bodies.depth] = latest;
        bodies.depth += 1;
    }

    bodies.position = ceiling;

    assert(bodies.depth <= macro_body_depth_max);

    return true;
}

pub fn holds(context: *const Context, cursor: u32) bool {
    if (!context.conventions.macros_invoke_with_bang) return false;

    const ceiling: u32 = @min(cursor, @as(u32, @intCast(context.tokens.len)));
    const step_count: u32 = @min(ceiling, macro_scan_max);
    var depth: u32 = 0;

    assert(ceiling <= context.tokens.len);
    assert(step_count <= macro_scan_max);

    if (!context.macro_openers.any_within(ceiling - step_count, ceiling)) return false;

    for (0..step_count) |step| {
        const index = ceiling - 1 - @as(u32, @intCast(step));
        const token = context.tokens[index];

        assert(index < ceiling);

        if (token.closes_a_group_or_block()) {
            depth += 1;

            continue;
        }

        if (!token.opens_a_group_or_block()) continue;

        if (depth > 0) {
            depth -= 1;

            continue;
        }

        if (MacroOpeners.opens_a_macro(context.tokens, index)) return true;
    }

    return false;
}
