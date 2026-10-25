const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../scan.zig");
const stream = @import("../stream.zig");
const Category = scylla.View.Category;
const Context = @import("context.zig");
const Enclosures = @import("enclosures.zig");
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;
const Views = Context.Views;

end: ?u32,
header: u32,
start: u32,

const Frame = @This();

pub const Covering = struct {
    frame: Frame,
    view: View,
};

pub const Coverings = struct {
    category_index: u32,
    chain: Enclosures.Chain,
    chained: bool,
    context: *const Context,
    offset: u32,
    token: u32,
    views: Views,

    fn category_enter(frames: *Coverings) void {
        assert(frames.category_index < categories.len);

        const category = categories[frames.category_index];
        const slot = Enclosures.slot_of(category).?;
        const context = frames.context;

        frames.chained = context.enclosures.chain_fill(
            context.front,
            slot,
            frames.offset,
            &frames.chain,
        );

        frames.views = context.views(category);

        if (frames.chained) assert(frames.chain.count <= Enclosures.chain_capacity);
    }

    fn covering_next(frames: *Coverings) ?Covering {
        if (frames.chained) return frames.covering_chained();

        assert(frames.views.remaining <= frames.views.positions.len);

        for (0..frames.views.remaining) |_| {
            const view = frames.views.next() orelse return null;

            assert(view.category() == categories[frames.category_index]);

            if (frames.covering_of(view)) |found| return found;
        }

        return null;
    }

    fn covering_chained(frames: *Coverings) ?Covering {
        assert(frames.chained);
        assert(frames.chain.count <= Enclosures.chain_capacity);

        for (0..Enclosures.chain_capacity) |_| {
            if (frames.chain.count == 0) return null;

            frames.chain.count -= 1;

            const view = frames.context.view(frames.chain.positions[frames.chain.count]);

            assert(view.category() == categories[frames.category_index]);

            if (frames.covering_of(view)) |found| return found;
        }

        return null;
    }

    fn covering_of(frames: *const Coverings, view: View) ?Covering {
        assert(frames.offset == frames.context.tokens[frames.token].offset);

        const context = frames.context;
        const extent = view.span();
        const line = context.line_of(extent.end() -| 1);
        const limit = context.line_span(line).end();

        if (frames.offset < extent.offset) return null;
        if (frames.offset >= limit) return null;

        const frame = of(context, view) orelse return null;
        if (!frame.covers(frames.token)) return null;

        assert(frame.header < context.tokens.len);

        return .{ .frame = frame, .view = view };
    }

    pub fn next(frames: *Coverings) ?Covering {
        assert(frames.category_index < categories.len);
        assert(frames.token < frames.context.tokens.len);

        for (0..categories.len) |_| {
            if (frames.covering_next()) |found| return found;
            if (frames.category_index + 1 == categories.len) return null;

            frames.category_index += 1;

            frames.category_enter();
        }

        unreachable;
    }
};

const BodyStart = struct {
    inlined: bool,
    start: u32,
};

pub const categories = [_]Category{
    .block,
    .branch,
    .except,
    .function,
    .loop,
    .match,
    .@"struct",
    .@"try",
};

pub const attribute_count_max: u32 = 16;
const attribute_marks = [_][]const u8{ "#", "@" };

comptime {
    assert(attribute_count_max > 0);
    assert(categories.len == 8);
}

pub fn of(context: *const Context, view: View) ?Frame {
    const header = header_of(context, view);
    if (header >= context.tokens.len) return null;

    const opened = body_start_of(context, view, header) orelse return null;

    assert(opened.start < context.tokens.len);

    if (opened.inlined) return frame_inline(context, view, header, opened.start);

    const frame: Frame = .{
        .end = block_end_of(context, opened.start),
        .header = header,
        .start = opened.start,
    };

    if (frame.end) |end| assert(end > frame.start);

    return frame;
}

fn frame_inline(context: *const Context, view: View, header: u32, start: u32) ?Frame {
    assert(header < context.tokens.len);
    assert(start < context.tokens.len);

    const limit = context.lexer_index_from(view.span().end());
    if (limit == 0) return null;

    const last = limit - 1;
    const end: ?u32 = if (last < start) null else last;

    return .{ .end = end, .header = header, .start = start };
}

pub fn at_block(context: *const Context, start: u32) Frame {
    assert(start < context.tokens.len);
    assert(context.tokens[start].kind == .block_start);

    const frame: Frame = .{ .end = block_end_of(context, start), .header = start, .start = start };

    if (frame.end) |end| assert(end > start);

    return frame;
}

fn block_end_of(context: *const Context, start: u32) ?u32 {
    assert(start < context.tokens.len);
    assert(context.tokens[start].kind == .block_start);

    if (context.tokens[start].length == 1) {
        const partner = context.pairs.partner_of(start) orelse return null;
        if (partner < start) return null;
        return partner;
    }

    var depth: u32 = 1;

    for (context.tokens[start + 1 ..], start + 1..) |token, index| {
        switch (token.kind) {
            .block_start => depth += 1,
            .block_end => {
                depth -= 1;

                if (depth == 0) return @intCast(index);
            },
            .comment, .identifier, .keyword, .newline, .number, .punctuation, .string => {},
        }
    }

    return null;
}

pub fn covering(context: *const Context, token: u32) Coverings {
    assert(token < context.tokens.len);

    var frames: Coverings = .{
        .category_index = 0,
        .chain = undefined,
        .chained = false,
        .context = context,
        .offset = context.tokens[token].offset,
        .token = token,
        .views = undefined,
    };

    frames.category_enter();

    assert(frames.views.remaining == frames.views.positions.len);

    return frames;
}

pub fn header_of(context: *const Context, view: View) u32 {
    const extent = view.span();
    const limit = context.lexer_index_from_hint(extent.end(), view.token_end());
    var index = context.lexer_index_from_hint(extent.offset, view.token_start());

    assert(index <= limit);
    assert(limit <= context.tokens.len);

    for (0..attribute_count_max) |_| {
        if (index >= limit) break;

        index = stream.significant_next(context.tokens, index, limit) orelse limit;

        if (index >= limit) break;
        if (!scan.word_in(&attribute_marks, context.text(context.tokens[index]))) break;

        index = attribute_end(context, index, limit);
    }

    assert(index <= context.tokens.len);

    return index;
}

fn attribute_end(context: *const Context, index: u32, limit: u32) u32 {
    assert(index < limit);
    assert(limit <= context.tokens.len);

    const next = index + 1;

    assert(next <= limit);

    if (next < limit) {
        if (attribute_group_end(context, next)) |end| return end;
    }

    for (context.tokens[next..limit], next..) |token, cursor| {
        if (token.kind == .newline) return @intCast(cursor);
    }

    return limit;
}

fn attribute_group_end(context: *const Context, open: u32) ?u32 {
    assert(open < context.tokens.len);

    if (!context.tokens[open].opens_a_group()) return null;

    const close = context.pairs.partner_of(open) orelse return null;
    if (close < open) return null;

    assert(context.tokens[close].closes_a_group());

    return close + 1;
}

fn body_start_of(context: *const Context, view: View, header: u32) ?BodyStart {
    assert(header < context.tokens.len);

    if (context.tokens[header].kind == .block_start) return .{ .inlined = false, .start = header };

    if (view.category() == .block) {
        if (block_start_own(context, view, header)) |found| {
            return .{ .inlined = false, .start = found };
        }
    }

    if (block_start_of_children(context, view, header)) |found| return found;

    switch (view.category()) {
        .branch, .except, .loop, .@"try" => return null,
        else => {},
    }

    const limit = context.lexer_index_from(view.span().end());
    const found = block_start_after(context.tokens, header, limit) orelse return null;

    assert(found > header);

    return .{ .inlined = false, .start = found };
}

fn block_start_own(context: *const Context, view: View, header: u32) ?u32 {
    assert(header < context.tokens.len);
    assert(view.category() == .block);

    const limit = if (view.child_first()) |child| child.span().offset else view.span().end();
    const bound = context.lexer_index_from(limit);
    const first = header + 1;

    assert(bound <= context.tokens.len);

    if (first < bound) {
        for (context.tokens[first..bound], first..) |token, index| {
            if (token.kind != .block_start) continue;
            if (opens_a_literal(context.tokens, @intCast(index))) continue;
            return @intCast(index);
        }
    }

    return block_start_before(context.tokens, header, 0);
}

fn block_start_of_children(context: *const Context, view: View, header: u32) ?BodyStart {
    assert(header < context.tokens.len);

    const offset = view.span().offset;
    var bodies = view.children_of(.block);
    var colon: ?u32 = null;

    for (0..bodies.remaining) |_| {
        const child = bodies.next() orelse break;
        const child_offset = child.span().offset;
        if (child_offset <= offset) continue;

        const at = context.lexer_index_from(child_offset);

        assert(at <= context.tokens.len);

        if (follows_an_else(context.tokens, at)) break;

        if (block_start_around(context.tokens, at, header)) |found| {
            return .{ .inlined = false, .start = found };
        }

        if (colon == null) colon = colon_before(context.tokens, at);
    }

    const found = colon orelse return null;

    assert(context.tokens[found].is_punctuation(.colon));

    return .{ .inlined = true, .start = found };
}

fn colon_before(tokens: []const Token, at: u32) ?u32 {
    assert(at <= tokens.len);

    if (at == 0) return null;
    if (!tokens[at - 1].is_punctuation(.colon)) return null;
    return at - 1;
}

fn block_start_after(tokens: []const Token, header: u32, limit: u32) ?u32 {
    assert(header < tokens.len);
    assert(limit <= tokens.len);

    const first = header + 1;
    if (first >= limit) return null;

    for (tokens[first..limit], first..) |token, index| {
        if (token.kind == .block_start) return @intCast(index);
    }

    return null;
}

fn block_start_around(tokens: []const Token, at: u32, header: u32) ?u32 {
    assert(at <= tokens.len);
    assert(header < tokens.len);

    for (tokens[at..], at..) |token, cursor| {
        switch (token.kind) {
            .block_start => {
                if (opens_a_literal(tokens, @intCast(cursor))) return null;
                return @intCast(cursor);
            },
            .comment, .newline => {},
            .block_end, .identifier, .keyword, .number, .punctuation, .string => break,
        }
    }

    return block_start_before(tokens, at, header);
}

fn follows_an_else(tokens: []const Token, at: u32) bool {
    assert(at <= tokens.len);

    const previous = stream.significant_previous(tokens, at) orelse return false;

    assert(previous < at);

    return tokens[previous].is_keyword(.branch_else);
}

fn opens_a_literal(tokens: []const Token, index: u32) bool {
    assert(index < tokens.len);
    assert(tokens[index].kind == .block_start);

    if (index == 0) return false;
    return tokens[index - 1].is_punctuation(.dot);
}

fn block_start_before(tokens: []const Token, from: u32, floor: u32) ?u32 {
    assert(floor <= tokens.len);

    const ceiling: u32 = @min(from, @as(u32, @intCast(tokens.len)));
    if (ceiling <= floor) return null;

    for (0..ceiling - floor) |step| {
        const cursor = ceiling - 1 - @as(u32, @intCast(step));

        assert(cursor >= floor);

        switch (tokens[cursor].kind) {
            .block_start => return cursor,
            .comment, .newline => {},
            .block_end, .identifier, .keyword, .number, .punctuation, .string => return null,
        }
    }

    return null;
}

pub fn body(frame: Frame, tokens: []const Token) []const Token {
    const end: u32 = if (frame.end) |last| last + 1 else @intCast(tokens.len);

    assert(frame.start <= end);
    assert(end <= tokens.len);

    return tokens[frame.start..end];
}

pub fn covers(frame: Frame, token: u32) bool {
    assert(token < std.math.maxInt(u32));

    if (frame.end) |last| assert(last >= frame.start);

    if (token < frame.start) return false;

    const end = frame.end orelse return true;
    return token < end;
}

pub fn span(frame: Frame, tokens: []const Token) Span {
    assert(frame.header < tokens.len);

    const start = tokens[frame.header].offset;
    var last: u32 = frame.end orelse @intCast(tokens.len - 1);

    if (last > frame.header) {
        if (tokens[last].kind == .newline) last -= 1;
    }

    assert(last < tokens.len);

    const end = tokens[last].end();

    assert(end >= start);

    return .between(start, end);
}

fn opening_token(frame: Frame, context: *const Context) u32 {
    assert(context.tokens.len > 0);

    const last: u32 = @intCast(context.tokens.len - 1);
    var cursor = @min(frame.header, last);

    for (0..cursor) |_| {
        switch (context.tokens[cursor].kind) {
            .block_start, .comment, .newline => cursor -= 1,
            .block_end, .identifier, .keyword, .number, .punctuation, .string => break,
        }
    }

    assert(cursor <= last);

    return cursor;
}

pub fn opening_line(frame: Frame, context: *const Context) []const u8 {
    const cursor = frame.opening_token(context);
    const line = context.line_of(context.tokens[cursor].offset);
    const text = context.line_text(line);

    assert(cursor <= frame.header);
    assert(std.mem.findScalar(u8, text, '\n') == null);

    return text;
}

pub fn opening_word(frame: Frame, context: *const Context) []const u8 {
    const cursor = frame.opening_token(context);
    const first = stream.line_start_of_token(context.tokens, context.source, cursor);

    assert(cursor <= frame.header);
    assert(first <= cursor);

    return context.text(context.tokens[first]);
}
