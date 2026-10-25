const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../scan.zig");
const stream = @import("../stream.zig");
const Category = scylla.View.Category;
const Context = @import("context.zig");
const Frame = @import("frame.zig");
const Token = scylla.Token;
const TokenRange = Context.TokenRange;
const View = scylla.View;

const Group = struct {
    closed: u32,
    open: u32,
};

pub const body_word = "do";
const capture_marker = "|";
const arm_word = "=>";
const keyword_categories = [_]Category{ .branch, .loop, .match, .@"try" };
const lifetime_quote = "'";

const infix_words = [_][]const u8{
    "and",
    "as",
    "catch",
    "in",
    "instanceof",
    "is",
    "of",
    "or",
    "orelse",
    "xor",
};

pub fn condition_of(context: *const Context, index: u32) TokenRange {
    const header = header_range(context, index);
    const condition = clauses_within(context, header) orelse header;

    assert(condition.start <= condition.end);
    assert(condition.end <= context.tokens.len);

    return condition;
}

pub fn clauses(context: *const Context, index: u32) ?TokenRange {
    const header = header_range(context, index);

    assert(header.start <= header.end);
    assert(header.end <= context.tokens.len);

    return clauses_within(context, header);
}

pub fn header_range(context: *const Context, index: u32) TokenRange {
    assert(index < context.tokens.len);

    if (header_group(context, index)) |group| {
        return .{ .end = group.closed, .start = group.open + 1 };
    }

    const start = index + 1;
    const end = header_end(context, start);
    const header: TokenRange = .{ .end = end, .start = start };

    assert(start <= end);

    if (!context.conventions.handlers_end_with_colon) return header;

    const colon = top_level_punctuation(context, header, .colon) orelse return header;

    assert(colon < end);

    return .{ .end = colon, .start = start };
}

pub fn header_group(context: *const Context, index: u32) ?Group {
    assert(index < context.tokens.len);

    const open = index + 1;
    if (open >= context.tokens.len) return null;
    if (!context.tokens[open].is_punctuation(.paren_open)) return null;

    const closed = context.pairs.partner_of(open) orelse return null;
    const group: Group = .{ .closed = closed, .open = open };

    assert(closed > open);

    const after = significant_after(context, closed + 1) orelse return group;
    if (continues_the_header(context, context.tokens[after])) return null;
    return group;
}

pub fn header_end(context: *const Context, start: u32) u32 {
    assert(start <= context.tokens.len);

    const end: u32 = end: {
        var depth: u32 = 0;

        for (context.tokens[start..], start..) |token, offset| {
            if (token.opens_a_group()) depth += 1;

            if (token.closes_a_group()) {
                if (depth == 0) break :end @intCast(offset);

                depth -= 1;
            }

            if (closes_the_header(context, token, depth)) break :end @intCast(offset);
            if (depth > 0) continue;
            if (!token.is_keyword(.other)) continue;
            if (std.mem.eql(u8, context.text(token), body_word)) break :end @intCast(offset + 1);
        }

        break :end @intCast(context.tokens.len);
    };

    assert(end >= start);
    assert(end <= context.tokens.len);

    return end;
}

pub fn compound_operator(context: *const Context, condition: TokenRange) ?u32 {
    assert(condition.start <= condition.end);
    assert(condition.end <= context.tokens.len);

    var depth: u32 = 0;

    for (context.tokens[condition.start..condition.end], condition.start..) |token, offset| {
        if (token.opens_a_group_or_block()) {
            depth += 1;

            continue;
        }

        if (token.closes_a_group_or_block()) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;
        if (token.is_punctuation(.ampersand_double)) return @intCast(offset);
        if (token.is_punctuation(.bar_double)) return @intCast(offset);
    }

    return null;
}

pub fn top_level_punctuation(
    context: *const Context,
    range: TokenRange,
    wanted: Token.Punctuation,
) ?u32 {
    assert(range.start <= range.end);
    assert(range.end <= context.tokens.len);

    var depth: u32 = 0;

    for (context.tokens[range.start..range.end], range.start..) |token, offset| {
        if (token.opens_a_group_or_block()) depth += 1;
        if (token.closes_a_group_or_block()) depth -|= 1;
        if (depth > 0) continue;
        if (token.is_punctuation(wanted)) return @intCast(offset);
    }

    return null;
}

pub fn keyword_frame(context: *const Context, index: u32) ?Frame {
    assert(index < context.tokens.len);

    const offset = context.tokens[index].offset;

    const view = keyword_view(context, offset) orelse labelled_view(context, index) orelse
        return null;

    assert(view.span().end() <= context.source.len);

    return Frame.of(context, view);
}

pub fn opens_a_do_loop(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (!token.is_keyword(.loop)) return false;

    const opens = std.mem.eql(u8, context.text(token), body_word);

    if (opens) assert(token.length == body_word.len);

    return opens;
}

pub fn captures(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (!token.is_punctuation(.other)) return false;

    const captured = std.mem.eql(u8, context.text(token), capture_marker);

    if (captured) assert(token.length == capture_marker.len);

    return captured;
}

pub fn significant_after(context: *const Context, start: u32) ?u32 {
    const end: u32 = @intCast(context.tokens.len);
    const found = stream.significant_next(context.tokens, start, end) orelse return null;

    assert(found >= start);
    assert(found < end);
    assert(Token.is_significant(context.tokens[found].kind));

    return found;
}

fn clauses_within(context: *const Context, header: TokenRange) ?TokenRange {
    assert(header.start <= header.end);
    assert(header.end <= context.tokens.len);

    var depth: u32 = 0;
    var first: ?u32 = null;

    for (context.tokens[header.start..header.end], header.start..) |token, offset| {
        if (token.opens_a_group_or_block()) depth += 1;
        if (token.closes_a_group_or_block()) depth -|= 1;
        if (depth > 0) continue;
        if (!token.is_punctuation(.semicolon)) continue;

        const opened = first orelse {
            first = @intCast(offset);

            continue;
        };

        assert(opened < offset);

        return .{ .end = @intCast(offset), .start = opened + 1 };
    }

    return null;
}

fn closes_the_header(context: *const Context, token: Token, depth: u32) bool {
    if (token.kind == .block_end) return true;
    if (depth > 0) return false;

    const closes = switch (token.kind) {
        .block_start, .newline => true,
        .keyword => |keyword| keyword == .branch_else,
        .punctuation => |punctuation| punctuation == .other and
            std.mem.eql(u8, context.text(token), arm_word),
        .block_end, .comment, .identifier, .number, .string => false,
    };

    if (closes) assert(token.kind != .comment);

    return closes;
}

fn continues_the_header(context: *const Context, next: Token) bool {
    assert(Token.is_significant(next.kind));

    const continues = switch (next.kind) {
        .keyword => |keyword| keyword == .other and
            scan.word_in(&infix_words, context.text(next)),
        .punctuation => |punctuation| switch (punctuation) {
            .ampersand,
            .ampersand_double,
            .bar_double,
            .bracket_open,
            .comma,
            .dot,
            .equal,
            .greater,
            .greater_equal,
            .less,
            .less_equal,
            .not_equal,
            .paren_open,
            .slash,
            .star,
            => true,
            .other => !std.mem.eql(u8, context.text(next), capture_marker),
            else => false,
        },
        .block_end, .block_start, .comment, .identifier, .newline, .number, .string => false,
    };

    if (continues) assert(next.kind != .identifier);

    return continues;
}

fn keyword_view(context: *const Context, offset: u32) ?View {
    assert(offset <= context.source.len);

    for (keyword_categories) |category| {
        const view = context.view_at(category, offset) orelse continue;

        assert(view.category() == category);

        return view;
    }

    return null;
}

fn labelled_view(context: *const Context, index: u32) ?View {
    assert(index < context.tokens.len);

    if (index < 2) return null;
    if (!context.tokens[index - 1].is_punctuation(.colon)) return null;

    const label = context.tokens[index - 2];
    if (label.kind != .identifier) return null;

    assert(label.offset < context.tokens[index].offset);

    return keyword_view(context, label.offset) orelse quoted_view(context, index - 2);
}

fn quoted_view(context: *const Context, label: u32) ?View {
    assert(label < context.tokens.len);

    if (label == 0) return null;

    const quote = context.tokens[label - 1];
    if (quote.end() != context.tokens[label].offset) return null;
    if (!std.mem.eql(u8, context.text(quote), lifetime_quote)) return null;

    assert(quote.length == lifetime_quote.len);

    return keyword_view(context, quote.offset);
}
