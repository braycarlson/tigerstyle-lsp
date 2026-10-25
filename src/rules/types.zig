const std = @import("std");
const assert = std.debug.assert;
const scan = @import("../scan.zig");
const support = @import("support.zig");
const Context = @import("context.zig");
const Frame = @import("frame.zig");

pub const function_type_scan_max: u32 = 256;

pub fn declares_without_a_body(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    const bodies = context.conventions.pointer_boundary_bodies;
    if (bodies.len == 0) return false;

    const function = support.signature_owner(context, offset) orelse return false;
    const held = function.as_function() orelse return false;

    assert(function.signature_covers(offset));

    if (held.body() != null) return false;

    const tokens = context.tokens_in(function.span());
    if (tokens.len == 0) return false;
    return scan.word_listed(bodies, context.text(tokens[tokens.len - 1]));
}

pub fn enclosing_group_opener(context: *const Context, index: u32) ?u32 {
    const ceiling: u32 = @min(index, @as(u32, @intCast(context.tokens.len)));
    const step_count: u32 = @min(ceiling, function_type_scan_max);
    var depth: u32 = 0;

    assert(ceiling <= context.tokens.len);
    assert(step_count <= function_type_scan_max);

    for (0..step_count) |step| {
        const cursor = ceiling - 1 - @as(u32, @intCast(step));
        const token = context.tokens[cursor];

        if (token.closes_a_group_or_block()) {
            depth += 1;

            continue;
        }

        if (!token.opens_a_group_or_block()) continue;

        if (depth > 0) {
            depth -= 1;

            continue;
        }

        assert(cursor < index);

        return cursor;
    }

    return null;
}

pub fn line_marks_a_boundary(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    const markers = context.conventions.pointer_boundary_markers;
    if (markers.len == 0) return false;

    const line = context.line_text(context.line_of(offset));

    assert(std.mem.findScalar(u8, line, '\n') == null);

    for (markers) |marker| {
        if (scan.find_word(line, marker)) return true;
    }

    return false;
}

pub fn signature_marks_a_boundary(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    const markers = context.conventions.pointer_boundary_markers;
    if (markers.len == 0) return false;

    const owner = support.signature_owner(context, offset) orelse return false;
    const span = owner.span();
    const body = if (owner.as_function()) |held| held.body() else null;
    const end = if (body) |found| found.span().offset else span.end();

    assert(span.offset <= end);
    assert(end <= context.source.len);

    const signature = context.source[span.offset..end];

    for (markers) |marker| {
        if (scan.find_word(signature, marker)) return true;
    }

    return false;
}

pub fn names_exactly(text: []const u8, name: []const u8) bool {
    assert(name.len > 0);

    if (!std.mem.startsWith(u8, text, name)) return false;
    if (text.len == name.len) return true;

    assert(text.len > name.len);

    return !scan.is_identifier_part(text[name.len]);
}

pub fn nests_a_boundary(context: *const Context, token: u32) bool {
    assert(token < context.tokens.len);

    const markers = context.conventions.pointer_boundary_markers;
    if (markers.len == 0) return false;

    var frames = Frame.covering(context, token);

    for (0..context.front.node_count()) |_| {
        const covering = frames.next() orelse return false;
        const opening = covering.frame.opening_line(context);

        assert(covering.frame.covers(token));

        for (markers) |marker| {
            if (scan.find_word(opening, marker)) return true;
        }
    }

    return false;
}

pub fn starts_a_type(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const offset = context.tokens[index].offset;

    assert(offset <= context.source.len);

    return context.view_at(.type, offset) != null;
}
