const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const classify = @import("../classify.zig");
const scan = @import("../scan.zig");
const stream = @import("../stream.zig");
const Category = scylla.View.Category;
const Conventions = @import("../conventions.zig");
const Enclosures = @import("enclosures.zig");
const Front = scylla.Front;
const Grammar = @import("../grammar.zig");
const Index = scylla.LineIndex;
const MacroOpeners = @import("macro_openers.zig");
const Pairs = scylla.Brackets;
const Registry = scylla.rule.Registry;
const Settings = @import("../settings.zig");
const Span = scylla.Span;
const Tables = scylla.Calls;
const Token = scylla.Token;
const TokenIndex = scylla.TokenIndex;
const View = scylla.View;

conventions: *const Conventions,
enclosures: *const Enclosures,
expectation_aliases: *classify.ExpectationAliases,
front: *const Front,
grammar: *const Grammar,
lines: *const Index,
macro_openers: *const MacroOpeners,
pairs: *const Pairs,
path: []const u8,
registry: *const Registry,
settings: *const Settings,
source: []const u8,
tables: *const Tables,
token_index: *const TokenIndex,
tokens: []const Token,

const Context = @This();

pub const Views = struct {
    front: *const Front,
    positions: []const u32,
    remaining: u32,

    pub fn next(iterator: *Views) ?View {
        assert(iterator.remaining <= iterator.positions.len);

        if (iterator.remaining == 0) return null;

        const position = iterator.positions[iterator.positions.len - iterator.remaining];

        iterator.remaining -= 1;

        return iterator.front.view(position).?;
    }
};

pub const TokenRange = struct {
    end: u32,
    start: u32,
};

pub const callable_categories = [_]Category{ .function, .lambda };
const export_word = "export";
const public_word = "pub";
pub const path_separator = "::";
const significant_lookbehind_max: u32 = 256;
const function_slot = Enclosures.slot_of(.function).?;
const lambda_slot = Enclosures.slot_of(.lambda).?;

pub fn view(context: *const Context, node: u32) View {
    const held = context.front.view(node).?;

    assert(held.index() == node);

    return held;
}

pub fn views(context: *const Context, category: Category) Views {
    const positions = context.front.nodes_of(category);

    assert(positions.len <= context.front.node_count());

    return .{
        .front = context.front,
        .positions = positions,
        .remaining = @intCast(positions.len),
    };
}

pub fn view_at(context: *const Context, category: Category, offset: u32) ?View {
    assert(offset <= context.source.len);

    return context.front.view_at(category, offset);
}

pub fn function_at(context: *const Context, offset: u32) ?View {
    assert(offset <= context.source.len);

    const enclosures = context.enclosures;
    const function = enclosures.innermost(context.front, function_slot, offset);
    const lambda = enclosures.innermost(context.front, lambda_slot, offset);

    const outer = switch (function) {
        .absent => null,
        .found => |position| context.view(position),
        .unordered => return context.front.function_at(offset),
    };

    const inner = switch (lambda) {
        .absent => return outer,
        .found => |position| context.view(position),
        .unordered => return context.front.function_at(offset),
    };

    const held = outer orelse return inner;
    if (inner.span().offset >= held.span().offset) return inner;
    return held;
}

fn lexer_token_at(context: *const Context, offset: u32) ?Token {
    const index = stream.index_at(context.tokens, offset) orelse return null;

    assert(index < context.tokens.len);

    return context.tokens[index];
}

pub fn declares_an_expectation_name(context: *const Context) bool {
    assert(context.source.len <= std.math.maxInt(u32));

    if (context.front.language != .zig) return false;
    return context.expectation_aliases.declares_a_name();
}

pub fn calls_an_expectation_alias(context: *const Context, index: u32) bool {
    const next = index + 1;

    assert(index < context.tokens.len);

    if (next == context.tokens.len) return false;
    if (!context.tokens[next].is_punctuation(.paren_open)) return false;
    if (!classify.opens_an_expectation(context.source, context.tokens[index])) return false;
    if (context.front.language != .zig) return false;

    assert(context.tokens[index].end() <= context.source.len);

    return context.expectation_aliases.calls(context.tokens[index]);
}

pub fn is_assertion(context: *const Context, statement: View) bool {
    const leading = context.tokens_in(statement.span());

    assert(statement.span().end() <= context.source.len);

    if (leading.len > 0) {
        if (leading[0].is_keyword(.assert)) return true;
    }

    const call = statement.as_call() orelse call: {
        const child = statement.child_first_of(.call) orelse return false;

        break :call child.as_call() orelse return false;
    };

    const name = call.name_token() orelse return false;
    const token = context.lexer_token_at(context.front_token(name).offset) orelse return false;

    assert(token.offset == context.front_token(name).offset);

    if (token.is_keyword(.assert)) return true;
    if (context.front.language != .zig) return false;
    return context.expectation_aliases.calls(token);
}

pub fn lexer_index_at(context: *const Context, offset: u32) ?u32 {
    const index = stream.index_at(context.tokens, offset) orelse return null;

    assert(index < context.tokens.len);

    return index;
}

pub fn lexer_index_from(context: *const Context, offset: u32) u32 {
    const index = stream.index_from(context.tokens, offset);

    assert(index <= context.tokens.len);

    return index;
}

pub fn lexer_index_from_hint(context: *const Context, offset: u32, hint: u32) u32 {
    const index = stream.index_from_hint(context.tokens, offset, hint);

    assert(index >= hint);
    assert(index <= context.tokens.len);

    return index;
}

pub fn inside(context: *const Context, category: Category, offset: u32) bool {
    for (context.front.nodes_of(category)) |position| {
        if (context.view(position).span().contains(offset)) return true;
    }

    return false;
}

pub fn front_token(context: *const Context, position: u32) Token {
    const tokens = context.front.tokens();

    assert(position < tokens.len);

    return tokens[position];
}

pub fn front_text(context: *const Context, position: u32) []const u8 {
    const token = context.front_token(position);

    assert(token.end() <= context.source.len);

    return context.source[token.offset..token.end()];
}

pub fn span_text(context: *const Context, span: Span) []const u8 {
    assert(span.end() <= context.source.len);

    return context.source[span.offset..span.end()];
}

pub fn tokens_in(context: *const Context, span: Span) []const Token {
    const held = stream.in_span(context.tokens, span);

    assert(held.len <= context.tokens.len);

    return held;
}

pub fn line_count(context: *const Context) u32 {
    const count = context.lines.count();

    assert(count > 0);

    return count;
}

pub fn line_of(context: *const Context, offset: u32) u32 {
    const line = context.lines.line_of(offset);

    assert(line < context.line_count());

    return line;
}

pub fn line_span(context: *const Context, line: u32) Span {
    assert(line < context.line_count());

    return context.lines.line_span(line, context.source);
}

pub fn line_text(context: *const Context, line: u32) []const u8 {
    return context.span_text(context.line_span(line));
}

pub fn lines_of(context: *const Context, span: Span) u32 {
    const end = @min(span.end(), @as(u32, @intCast(context.source.len)));
    const first = context.line_of(span.offset);

    var last = context.line_of(end);

    if (last > first) {
        if (end == context.line_span(last).offset) last -= 1;
    }

    const lines_max = last - first;

    for (0..lines_max) |_| {
        if (last == first) break;

        const trails = trails_the_block(
            context.source,
            context.lines,
            first,
            last,
            context.grammar,
        );

        if (!trails) break;

        last -= 1;
    }

    assert(last >= first);

    return last - first + 1;
}

pub fn text(context: *const Context, token: Token) []const u8 {
    assert(token.end() <= context.source.len);

    return token.text(context.source);
}

fn trails_the_block(
    source: []const u8,
    index: *const Index,
    first: u32,
    last: u32,
    grammar: *const Grammar,
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(first <= last);
    assert(last < index.count());

    const line = index.line_span(last, source).text(source);
    const trimmed = scan.trim_ascii(line);
    if (trimmed.len == 0) return true;

    const prefix = grammar.comment_prefix;
    if (prefix.len == 0) return false;
    if (!std.mem.startsWith(u8, trimmed, prefix)) return false;

    const opening = index.line_span(first, source).text(source);
    return scan.indent_width(line) <= scan.indent_width(opening);
}

pub fn declares_publicly(context: *const Context, binding: u32) bool {
    const bindings = context.front.bindings();

    assert(binding < bindings.count());

    const name = bindings.at(binding).name;
    const start = context.line_span(context.line_of(name.offset)).offset;
    const before = context.source[start..name.offset];

    assert(start <= name.offset);

    if (scan.find_word(before, export_word)) return true;
    return scan.find_word(before, public_word);
}

pub fn significant_before(context: *const Context, index: u32) ?u32 {
    assert(index <= context.tokens.len);

    var cursor = index;

    for (0..significant_lookbehind_max) |_| {
        if (cursor == 0) return null;

        cursor -= 1;

        if (Token.is_significant(context.tokens[cursor].kind)) return cursor;
    }

    assert(cursor < index);

    return null;
}

pub fn significant_after(context: *const Context, index: u32) ?u32 {
    assert(index < context.tokens.len);

    const found = context.significant_from_hint(context.tokens[index].end(), index + 1);

    if (found) |held| assert(held > index);

    return found;
}

pub fn significant_from_hint(context: *const Context, offset: u32, hint: u32) ?u32 {
    assert(offset <= context.source.len);

    const start = context.lexer_index_from_hint(offset, hint);

    assert(start >= hint);

    for (context.tokens[start..], start..) |token, index| {
        if (Token.is_significant(token.kind)) return @intCast(index);
    }

    return null;
}

pub fn significant_from(context: *const Context, offset: u32) ?u32 {
    assert(offset <= context.source.len);

    const start = context.lexer_index_from(offset);

    assert(start <= context.tokens.len);

    for (context.tokens[start..], start..) |token, index| {
        if (Token.is_significant(token.kind)) return @intCast(index);
    }

    return null;
}

pub fn is_path_separator(context: *const Context, token: Token) bool {
    if (!token.is_punctuation(.colon)) return false;

    assert(token.length >= 1);
    assert(token.end() <= context.source.len);

    return std.mem.eql(u8, context.text(token), path_separator);
}

pub fn declaration_of(context: *const Context, offset: u32) ?View {
    const bindings = context.front.bindings();

    assert(offset <= context.source.len);

    for (0..bindings.reference_count()) |index| {
        const reference = bindings.reference_at(@intCast(index));
        if (reference.name.offset != offset) continue;

        assert(reference.name.end() <= context.source.len);

        const bound = switch (reference.resolution) {
            .bound => |bound| bound,
            .builtin, .external, .maybe, .unresolved => return null,
        };

        if (bound >= bindings.count()) return null;

        const binding = bindings.at(bound);
        if (binding.node >= context.front.node_count()) return null;
        return context.view(binding.node).declaring_of();
    }

    return null;
}
