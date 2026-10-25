const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const types = @import("../types.zig");
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const HandOvers = @import("../hand_overs.zig");
const Language = scylla.Language;
const MacroBodies = @import("../macro_bodies.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const TestScope = @import("../test_scope.zig");
const Token = scylla.Token;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use explicitly-sized types like `u32` for everything, avoid " ++
                "architecture-specific `usize`.\"",
        },
    },
    .code = "TS027",
    .default_on = false,
    .description = "A type spells its width, so the same program runs the same way on a smaller " ++
        "target.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "explicit-sized-types",
    .severity = .warning,
    .summary = "Avoid architecture-dependent `usize`/`isize` where a sized type serves",
    .url = "",
};

const StructCover = struct {
    count: u32,
    pairs: [struct_cover_capacity]Pair,
    state: State,

    const Pair = struct {
        end: u32,
        start: u32,

        fn earlier(_: void, left: Pair, right: Pair) bool {
            return left.start < right.start;
        }
    };

    const State = enum {
        built,
        overflowed,
        unbuilt,
    };

    fn build(cover: *StructCover, context: *const Context) void {
        assert(cover.state == .unbuilt);

        var structs = context.views(.@"struct");

        cover.count = 0;
        cover.state = .built;

        for (0..structs.remaining) |_| {
            const held = structs.next() orelse break;
            const frame = Frame.of(context, held) orelse continue;

            if (cover.count == struct_cover_capacity) {
                cover.state = .overflowed;

                return;
            }

            cover.pairs[cover.count] = .{
                .end = frame.end orelse std.math.maxInt(u32),
                .start = frame.start,
            };

            cover.count += 1;
        }

        const pairs = cover.pairs[0..cover.count];
        var reach: u32 = 0;

        std.sort.pdq(Pair, pairs, {}, Pair.earlier);

        for (pairs) |*pair| {
            reach = @max(reach, pair.end);
            pair.end = reach;
        }

        assert(cover.count <= struct_cover_capacity);
    }

    fn covers(cover: *const StructCover, index: u32) bool {
        assert(cover.state == .built);

        const pairs = cover.pairs[0..cover.count];
        const after = std.sort.partitionPoint(Pair, pairs, index, start_at_or_before);

        assert(after <= cover.count);

        if (after == 0) return false;
        return index < pairs[after - 1].end;
    }

    fn start_at_or_before(index: u32, pair: Pair) bool {
        return pair.start <= index;
    }
};

const index_scan_max: u32 = 4_096;
const struct_cover_capacity: u32 = 2_048;
const measure_calls = [_][]const u8{ "cap", "count", "len", "position", "rposition" };
const measure_words = [_][]const u8{ "cap", "len" };
const optional_marker = "?";
const pointer_argument_words = [_][]const u8{ "Pointer", "data", "ptr", "raw_data", "rawptr" };
const pointer_width_name = "uintptr";

const range_type_names = [_][]const u8{
    "Range",
    "RangeFrom",
    "RangeInclusive",
    "RangeTo",
    "RangeToInclusive",
};

const return_wrappers = [_][]const u8{ "Err", "Ok", "Some" };
const step_operators = [_][]const u8{ "+", "-" };
const tuple_struct_depth_max: u32 = 8;
const type_argument_scan_max: u32 = 64;
const wrapper_depth_max: u32 = 8;

pub fn run(context: *const Context, sink: *Sink) void {
    const names = context.grammar.sized_type_names;
    if (names.len == 0) return;

    var cover: StructCover = undefined;
    var hand_overs: HandOvers = undefined;

    cover.state = .unbuilt;

    hand_overs.begin();

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);
        const text = context.text(token);
        if (!scan.word_listed(names, text)) continue;
        if (exempt(context, &cover, &hand_overs, index)) continue;

        assert(token.length == text.len);
        assert(token.end() <= context.source.len);

        sink.report_formatted(
            token.span(),
            "{s} is architecture dependent; spell the width",
            .{scan.utf8_or(text, "the type")},
        );
    }
}

fn exempt(
    context: *const Context,
    cover: *StructCover,
    hand_overs: *HandOvers,
    index: u32,
) bool {
    assert(index < context.tokens.len);
    assert(context.tokens[index].length > 0);

    if (qualifies_a_name(context, index)) return true;
    if (justifies_a_width(context, index)) return true;
    if (TestScope.file_is_a_fixture(context)) return true;
    if (converts_a_pointer(context, index)) return true;
    if (lists_a_type(context, index)) return true;
    if (MacroBodies.holds(context, index)) return true;
    if (dictated_by_a_signature(context, hand_overs, index)) return true;
    if (declares_a_field(context, cover, index)) return false;
    if (!names_an_element(context, index)) return false;
    return !stores_in_a_file_field(context, index);
}

fn stores_in_a_file_field(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const offset = context.tokens[index].offset;
    if (context.function_at(offset) != null) return false;

    var declarations = context.views(.declaration);

    for (0..declarations.remaining) |_| {
        const held = declarations.next() orelse return false;
        const span = held.span();
        if (span.offset > offset) return false;
        if (span.end() <= offset) continue;
        if (held.as_field() == null) continue;

        const parent = held.parent() orelse continue;

        assert(span.offset <= offset);

        if (parent.category() == .file) return true;
    }

    return false;
}

fn qualifies_a_name(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index > 0) {
        if (context.tokens[index - 1].is_punctuation(.dot)) return true;
    }

    if (index + 1 >= context.tokens.len) return false;

    const next = context.tokens[index + 1];

    assert(next.offset >= context.tokens[index].offset);

    if (next.is_punctuation(.dot)) return true;
    return next.is_punctuation(.colon);
}

fn justifies_a_width(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (follows_a_cast(context, index)) return true;
    if (converts_a_value(context, index)) return true;
    if (carries_a_completion(context, index)) return true;
    if (spans_a_range(context, index)) return true;
    if (returns_an_index(context, index)) return true;

    const name = annotated_name(context, index) orelse adjacent_name(context, index) orelse
        return false;

    assert(name.len > 0);

    return indexes_with(context, index, name);
}

fn follows_a_cast(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const words = context.grammar.cast_words;
    if (words.len == 0) return false;
    if (index == 0) return false;

    var cursor = index - 1;

    if (context.tokens[cursor].is_punctuation(.paren_open)) {
        if (cursor == 0) return false;

        cursor -= 1;
    }

    assert(cursor < index);

    return scan.word_listed(words, context.text(context.tokens[cursor]));
}

fn converts_a_value(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const text = context.text(context.tokens[index]);

    assert(text.len > 0);

    if (std.mem.eql(u8, text, pointer_width_name)) return false;
    if (index + 1 >= context.tokens.len) return false;
    return context.tokens[index + 1].is_punctuation(.paren_open);
}

fn carries_a_completion(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index == 0) return false;
    if (!context.tokens[index - 1].is_punctuation(.bang)) return false;

    assert(context.tokens[index - 1].offset < context.tokens[index].offset);

    return inside_a_parameter(context, index);
}

fn spans_a_range(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index < 2) return false;
    if (!context.tokens[index - 1].is_punctuation(.less)) return false;

    assert(context.tokens[index - 2].offset <= context.tokens[index - 1].offset);

    return scan.word_in(&range_type_names, context.text(context.tokens[index - 2]));
}

fn inside_a_parameter(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const offset = context.tokens[index].offset;
    var functions = context.views(.function);

    for (0..functions.remaining) |_| {
        const function = functions.next() orelse return false;
        const callable = function.as_function() orelse continue;
        const span = callable.parameters_span() orelse continue;
        if (offset < span.offset) continue;
        if (offset >= span.end()) continue;

        assert(span.length > 0);

        return true;
    }

    return false;
}

fn returns_an_index(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const offset = context.tokens[index].offset;
    if (!support.in_signature(context, offset)) return false;
    if (inside_a_parameter(context, index)) return false;

    const function = context.function_at(offset) orelse return false;
    const callable = function.as_function() orelse return false;
    const body = callable.body() orelse return false;
    const span = body.span();
    var returned: u32 = 0;
    var statements = context.views(.@"return");

    assert(span.end() <= context.source.len);

    for (0..statements.remaining) |_| {
        const statement = statements.next() orelse break;
        const held = statement.span();
        if (held.offset < span.offset) continue;
        if (held.end() > span.end()) continue;

        returned += 1;

        if (!measures_an_index(context, index, context.tokens_in(held))) return false;
    }

    if (support.tail_site(context, body)) |tail| {
        returned += 1;

        if (!measures_an_index(context, index, context.tokens_in(tail.span()))) return false;
    }

    return returned > 0;
}

fn measures_an_index(context: *const Context, index: u32, tokens: []const Token) bool {
    assert(index < context.tokens.len);

    const value = stepped_name(context, unwrapped(context, returned_value(tokens)));

    assert(value.len <= tokens.len);

    if (value.len == 3) {
        if (reads_a_field(value)) {
            const tokens_end: u32 = @intCast(context.tokens.len);
            return indexes_within(context, 0, tokens_end, context.text(value[2]));
        }
    }

    if (value.len == 1) {
        if (value[0].kind == .identifier) {
            const name = context.text(value[0]);
            if (indexes_with(context, index, name)) return true;
            return bound_to_a_measure(context, index, name);
        }
    }

    return calls_a_measure(context, value);
}

fn returned_value(tokens: []const Token) []const Token {
    var value = tokens;

    if (value.len > 0) {
        if (value[0].is_keyword(.@"return")) value = value[1..];
    }

    if (value.len > 0) {
        if (value[value.len - 1].is_punctuation(.semicolon)) value = value[0 .. value.len - 1];
    }

    assert(value.len <= tokens.len);
    assert(value.len + 2 >= tokens.len);

    return value;
}

fn unwrapped(context: *const Context, tokens: []const Token) []const Token {
    var value = tokens;

    for (0..wrapper_depth_max) |_| {
        if (value.len < 3) break;

        const first = value[0];
        const inner = value[1 .. value.len - 1];

        assert(inner.len >= 1);

        if (first.kind != .identifier) break;
        if (!scan.word_in(&return_wrappers, context.text(first))) break;
        if (!inner[0].is_punctuation(.paren_open)) break;
        if (!value[value.len - 1].is_punctuation(.paren_close)) break;

        value = inner[1..];
    }

    assert(value.len <= tokens.len);

    return value;
}

fn stepped_name(context: *const Context, value: []const Token) []const Token {
    if (value.len != 3) return value;

    assert(value[0].offset <= value[1].offset);

    if (!scan.word_in(&step_operators, context.text(value[1]))) return value;
    if (value[2].kind != .number) return value;

    assert(value[1].offset < value[2].offset);

    return value[0..1];
}

fn reads_a_field(value: []const Token) bool {
    assert(value.len == 3);

    const receiver = switch (value[0].kind) {
        .identifier => true,
        .keyword => |keyword| keyword == .other,
        else => false,
    };

    if (!receiver) return false;
    if (!value[1].is_punctuation(.dot)) return false;

    assert(value[0].offset <= value[1].offset);

    return value[2].kind == .identifier;
}

fn calls_a_measure(context: *const Context, value: []const Token) bool {
    assert(value.len <= context.tokens.len);

    var depth: u32 = 0;

    for (0..value.len) |step| {
        const cursor = value.len - 1 - step;
        const token = value[cursor];

        if (token.closes_a_group()) {
            depth += 1;

            continue;
        }

        if (token.opens_a_group()) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;
        if (!token.is_punctuation(.dot)) continue;
        if (cursor + 2 >= value.len) return false;

        assert(cursor + 2 < value.len);

        if (!scan.word_in(&measure_calls, context.text(value[cursor + 1]))) return false;
        return value[cursor + 2].is_punctuation(.paren_open);
    }

    return false;
}

fn bound_to_a_measure(context: *const Context, index: u32, name: []const u8) bool {
    assert(index < context.tokens.len);
    assert(name.len > 0);

    const offset = context.tokens[index].offset;
    const function = context.function_at(offset) orelse return false;
    const span = function.span();
    const tokens_end: u32 = @intCast(context.tokens.len);
    const first = context.lexer_index_from(span.offset);
    const last = @min(context.lexer_index_from(span.end()), tokens_end);

    assert(first <= last);

    for (first..last) |position| {
        const cursor: u32 = @intCast(position);
        if (!context.tokens[cursor].is_keyword(.declare)) continue;

        const named = declared_name(context, cursor) orelse continue;
        if (!std.mem.eql(u8, context.text(context.tokens[named]), name)) continue;
        if (calls_a_measure(context, statement_tokens(context, named, last))) return true;
    }

    return false;
}

fn declared_name(context: *const Context, declare: u32) ?u32 {
    assert(context.tokens[declare].is_keyword(.declare));

    var named = declare + 1;

    if (named < context.tokens.len) {
        if (context.tokens[named].is_keyword(.mutable)) named += 1;
    }

    if (named >= context.tokens.len) return null;
    if (context.tokens[named].kind != .identifier) return null;

    assert(named > declare);

    return named;
}

fn statement_tokens(context: *const Context, from: u32, limit: u32) []const Token {
    assert(from < context.tokens.len);
    assert(limit <= context.tokens.len);

    if (from >= limit) return context.tokens[from..from];

    for (context.tokens[from..limit], from..) |token, cursor| {
        if (token.is_punctuation(.semicolon)) return context.tokens[from..cursor];
    }

    return context.tokens[from..limit];
}

fn adjacent_name(context: *const Context, index: u32) ?[]const u8 {
    assert(index < context.tokens.len);

    if (context.grammar.type_follows_colon) return null;
    if (index == 0) return null;

    const before = context.tokens[index - 1];
    if (before.kind != .identifier) return null;

    assert(before.length > 0);

    return context.text(before);
}

fn annotated_name(context: *const Context, index: u32) ?[]const u8 {
    assert(index < context.tokens.len);

    var cursor = index;

    for (0..wrapper_depth_max) |_| {
        if (cursor == 0) break;

        const before = context.tokens[cursor - 1];
        if (before.is_punctuation(.colon)) break;
        if (!wraps_a_type(context, before)) return null;

        cursor -= 1;
    }

    assert(cursor <= index);

    if (cursor < 2) return null;

    const colon = context.tokens[cursor - 1];
    const named = context.tokens[cursor - 2];

    if (!colon.is_punctuation(.colon)) return null;
    if (named.kind != .identifier) return null;

    assert(named.offset < colon.offset);

    return context.text(named);
}

fn wraps_a_type(context: *const Context, before: Token) bool {
    assert(before.end() <= context.source.len);
    assert(!before.is_punctuation(.colon));

    if (before.kind == .identifier) return true;
    if (before.is_punctuation(.less)) return true;
    if (before.is_punctuation(.ampersand)) return true;
    if (before.is_punctuation(.bracket_open)) return true;
    if (before.is_punctuation(.star)) return true;
    return scan.word_listed(context.conventions.optional_markers, context.text(before));
}

fn indexes_with(context: *const Context, index: u32, name: []const u8) bool {
    assert(index < context.tokens.len);
    assert(name.len > 0);

    const offset = context.tokens[index].offset;
    const tokens_end: u32 = @intCast(context.tokens.len);

    const function = context.function_at(offset) orelse
        return indexes_within(context, 0, tokens_end, name);

    const span = function.span();
    const first = context.lexer_index_from(span.offset);
    const last = context.lexer_index_from(span.end());
    const end = @min(last, first + index_scan_max, tokens_end);

    assert(first <= end);

    return indexes_within(context, first, end, name);
}

fn indexes_within(context: *const Context, first: u32, end: u32, name: []const u8) bool {
    assert(first <= end);
    assert(end <= context.tokens.len);

    for (context.tokens[first..end], first..) |token, position| {
        const cursor: u32 = @intCast(position);

        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;
        if (subscripts(context, cursor)) return true;
        if (compares_to_a_length(context, cursor)) return true;
    }

    return false;
}

fn subscripts(context: *const Context, cursor: u32) bool {
    assert(cursor < context.tokens.len);
    assert(context.tokens[cursor].kind == .identifier);

    if (cursor > 0) {
        if (context.tokens[cursor - 1].is_punctuation(.bracket_open)) return true;
    }

    if (cursor + 1 >= context.tokens.len) return false;
    return context.tokens[cursor + 1].is_punctuation(.bracket_close);
}

fn compares_to_a_length(context: *const Context, cursor: u32) bool {
    assert(cursor < context.tokens.len);
    assert(context.tokens[cursor].kind == .identifier);

    if (!compared(context, cursor)) return false;

    const line = context.line_text(context.line_of(context.tokens[cursor].offset));

    assert(std.mem.findScalar(u8, line, '\n') == null);

    for (measure_words) |word| {
        if (scan.find_word(line, word)) return true;
    }

    return false;
}

fn compared(context: *const Context, cursor: u32) bool {
    assert(cursor < context.tokens.len);
    assert(context.tokens[cursor].kind == .identifier);

    if (cursor > 0) {
        if (compares(context.tokens[cursor - 1])) return true;
    }

    if (cursor + 1 >= context.tokens.len) return false;
    return compares(context.tokens[cursor + 1]);
}

fn compares(token: Token) bool {
    const punctuation = switch (token.kind) {
        .punctuation => |held| held,
        else => return false,
    };

    const comparison = switch (punctuation) {
        .equal, .greater, .greater_equal, .less, .less_equal, .not_equal => true,
        else => false,
    };

    if (comparison) assert(token.length > 0);
    if (comparison) assert(!token.opens_a_group_or_block());

    return comparison;
}

fn converts_a_pointer(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (!std.mem.eql(u8, context.text(context.tokens[index]), pointer_width_name)) return false;
    if (index + 1 >= context.tokens.len) return false;
    if (!context.tokens[index + 1].is_punctuation(.paren_open)) return false;

    const tokens_end: u32 = @intCast(context.tokens.len);
    const limit = @min(index + 1 + types.function_type_scan_max, tokens_end);
    var depth: u32 = 0;

    assert(limit > index + 1);

    for (context.tokens[index + 1 .. limit]) |token| {
        if (token.is_punctuation(.paren_open)) {
            depth += 1;

            continue;
        }

        if (token.is_punctuation(.paren_close)) {
            assert(depth > 0);

            depth -= 1;

            if (depth == 0) return false;

            continue;
        }

        const text = context.text(token);
        if (std.mem.eql(u8, text, "&")) return true;
        if (std.mem.eql(u8, text, "^")) return true;
        if (scan.word_in(&pointer_argument_words, text)) return true;
    }

    return false;
}

fn lists_a_type(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const opener = types.enclosing_group_opener(context, index) orelse return false;
    const token = context.tokens[opener];

    assert(opener < index);

    if (token.kind != .block_start) {
        if (!std.mem.eql(u8, context.text(token), "{")) return false;
    }

    if (opener == 0) return false;
    return context.tokens[opener - 1].is_punctuation(.dot);
}

fn names_an_element(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index == 0) return false;

    const before = context.tokens[index - 1];

    assert(before.offset <= context.tokens[index].offset);

    if (before.is_punctuation(.bracket_close)) return true;
    if (before.is_punctuation(.less)) return true;
    if (std.mem.eql(u8, context.text(before), optional_marker)) return true;
    if (before.is_keyword(.constant)) return qualifies_a_slice(context, index - 1);
    if (before.is_punctuation(.comma)) return follows_a_type_argument(context, index - 1);
    return argues_a_container_type(context, index - 1);
}

fn follows_a_type_argument(context: *const Context, comma: u32) bool {
    assert(comma < context.tokens.len);
    assert(context.tokens[comma].is_punctuation(.comma));

    if (context.front.language == .rust) return opens_a_type_argument_list(context, comma);

    const opener = types.enclosing_group_opener(context, comma) orelse return false;
    return argues_a_container_type(context, opener);
}

fn opens_a_type_argument_list(context: *const Context, comma: u32) bool {
    assert(comma < context.tokens.len);

    const step_count: u32 = @min(comma, type_argument_scan_max);
    var angle_depth: u32 = 0;
    var group_depth: u32 = 0;

    for (0..step_count) |step| {
        const token = context.tokens[comma - 1 - @as(u32, @intCast(step))];

        if (token.closes_a_group_or_block()) {
            group_depth += 1;

            continue;
        }

        if (token.opens_a_group_or_block()) {
            if (group_depth == 0) return false;

            group_depth -= 1;

            continue;
        }

        if (group_depth > 0) continue;
        if (token.is_punctuation(.semicolon)) return false;

        if (token.is_punctuation(.greater)) {
            angle_depth += 1;

            continue;
        }

        if (!token.is_punctuation(.less)) continue;
        if (angle_depth == 0) return true;

        angle_depth -= 1;
    }

    return false;
}

fn qualifies_a_slice(context: *const Context, qualifier: u32) bool {
    assert(qualifier < context.tokens.len);
    assert(context.tokens[qualifier].is_keyword(.constant));

    if (qualifier == 0) return false;
    return context.tokens[qualifier - 1].is_punctuation(.bracket_close);
}

fn argues_a_container_type(context: *const Context, open: u32) bool {
    assert(open < context.tokens.len);

    if (!context.conventions.types_are_values) return false;
    if (open == 0) return false;
    if (!context.tokens[open].is_punctuation(.paren_open)) return false;

    const callee = context.tokens[open - 1];
    const name = context.text(callee);

    assert(callee.offset < context.tokens[open].offset);

    if (callee.kind != .identifier) return false;
    if (std.ascii.isUpper(name[0])) return true;
    return scan.word_listed(context.conventions.allocation_methods, name);
}

fn declares_a_field(context: *const Context, cover: *StructCover, index: u32) bool {
    assert(index < context.tokens.len);

    const offset = context.tokens[index].offset;
    if (context.function_at(offset) != null) return false;
    if (inside_a_tuple_struct(context, index)) return true;

    if (cover.state == .unbuilt) cover.build(context);
    if (cover.state == .built) return cover.covers(index);

    assert(cover.state == .overflowed);

    var structs = context.views(.@"struct");

    for (0..structs.remaining) |_| {
        const held = structs.next() orelse return false;
        const frame = Frame.of(context, held) orelse continue;
        if (!frame.covers(index)) continue;

        assert(frame.start <= index);

        return true;
    }

    return false;
}

fn inside_a_tuple_struct(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    var cursor = index;

    for (0..tuple_struct_depth_max) |_| {
        const opener = types.enclosing_group_opener(context, cursor) orelse return false;
        const token = context.tokens[opener];

        assert(opener < cursor);

        if (token.is_punctuation(.paren_open)) {
            if (names_a_tuple_struct(context, opener)) return true;
        } else {
            if (!token.is_punctuation(.bracket_open)) return false;
        }

        cursor = opener;
    }

    return false;
}

fn names_a_tuple_struct(context: *const Context, open: u32) bool {
    assert(open < context.tokens.len);
    assert(context.tokens[open].is_punctuation(.paren_open));

    if (open < 2) return false;
    if (context.tokens[open - 1].kind != .identifier) return false;
    return context.tokens[open - 2].is_keyword(.@"struct");
}

fn dictated_by_a_signature(
    context: *const Context,
    hand_overs: *HandOvers,
    index: u32,
) bool {
    assert(index < context.tokens.len);

    const offset = context.tokens[index].offset;

    assert(offset <= context.source.len);

    if (types.line_marks_a_boundary(context, offset)) return true;

    const function = support.signature_owner(context, offset) orelse return false;

    if (types.nests_a_boundary(context, index)) return true;
    if (types.declares_without_a_body(context, offset)) return true;
    if (hand_overs.covers(context, function)) return true;
    return support.implements_a_trait(context, index);
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a zig file's own field stores its element width" {
    const source = "limbs: std.ArrayList(usize),\nunified: ?usize = 3,\n\n" ++
        "fn run(options: struct { count: ?usize = null }) void {\n" ++
        "    var first_index: ?usize = null;\n    first_index = options.count;\n}\n";

    try expect_count(.zig, source, 2);
}

test "a closure written in place as an argument takes the receiver's widths" {
    const source = "package main\n\nfunc run(items []Item) {\n" ++
        "\tsort.Slice(items, func(i, j int) bool { return items[i].key < items[j].key })\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a closure bound to a name and only called keeps its own widths" {
    const source = "package main\n\nfunc run() {\n" ++
        "\tnext := func(n int) int { return n }\n\tuse(next(4))\n}\n";

    try expect_count(.go, source, 2);
}

test "a procedure type named in a field is a type rather than a function handed over" {
    const source = "Reader_Fn :: proc(data: rawptr) -> int\n\n" ++
        "Reader :: struct {\n    reader_fn: Reader_Fn,\n}\n";

    try expect_count(.odin, source, 1);
}

test "an odin procedure without a body keeps the width its definition chose" {
    const declared = "offset_of_by_string :: proc($T: typeid, member: string) -> uintptr ---\n";
    const defined = "offset_of :: proc(member: string) -> uintptr {\n    return 0\n}\n";

    try testing.expect_quiet(@This(), .odin, declared);
    try expect_count(.odin, defined, 1);
}

test "a counter bounded by a length is quiet" {
    const source = "fn run(items: []u8) void {\n    var i: usize = 0;\n" ++
        "    while (i < items.len) : (i += 1) {\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a field the file indexes with keeps the language width" {
    const indexed = "struct Cursor {\n    position: usize,\n}\n\nimpl Cursor {\n" ++
        "    fn byte(&self, source: &[u8]) -> u8 {\n        source[self.position]\n    }\n}\n";

    const stored = "struct Table {\n    count: usize,\n}\n\nimpl Table {\n" ++
        "    fn grow(&mut self) {\n        self.count += 1;\n    }\n}\n";

    const bounded = "const NAME_LENGTH_MAX: usize = 31;\n\nfn short(name: &[u8]) -> bool {\n" ++
        "    name.len() <= NAME_LENGTH_MAX\n}\n";

    try testing.expect_quiet(@This(), .rust, indexed);
    try expect_count(.rust, stored, 1);
    try testing.expect_quiet(@This(), .rust, bounded);
}

test "a range of usize is the slice index" {
    const source = "struct Entry {\n    data: Range<usize>,\n}\n\n" ++
        "fn cut(source: &[u8], range: Range<usize>) -> &[u8] {\n    &source[range]\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a returned index keeps the language width" {
    const indexed = "fn skip(source: &[u8], position: usize) -> usize {\n" ++
        "    if source[position] == b' ' {\n        return position + 1;\n    }\n\n" ++
        "    position\n}\n";

    const counted = "fn spaces(source: &[u8]) -> usize {\n" ++
        "    let length = source.iter().filter(|byte| **byte == b' ').count();\n\n" ++
        "    length\n}\n";

    const wrapped = "fn tail(source: &[u8]) -> Option<usize> {\n    Some(source.len() - 1)\n}\n";
    const computed = "fn doubled(count: u32) -> usize {\n    count as usize * 2\n}\n";

    const field = "struct Cursor {\n    position: usize,\n}\n\nimpl Cursor {\n" ++
        "    fn position(&self) -> usize {\n        self.position\n    }\n\n" ++
        "    fn byte(&self, source: &[u8]) -> u8 {\n        source[self.position]\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, indexed);
    try testing.expect_quiet(@This(), .rust, counted);
    try testing.expect_quiet(@This(), .rust, wrapped);
    try expect_count(.rust, computed, 1);
    try testing.expect_quiet(@This(), .rust, field);
}

test "a counter bounded by a constant is reported" {
    const source = "fn run() void {\n    var i: usize = 0;\n" ++
        "                       while (i < 4) : (i += 1) {\n    }\n}\n";

    try expect_count(.zig, source, 1);
}

test "a completion parameter is quiet" {
    try testing.expect_quiet(@This(), .zig, "fn on_recv(result: RecvError!usize) void {\n}\n");
}

test "a completion return type is the authors choice" {
    try expect_count(.zig, "fn read() ReadError!usize {\n    return 0;\n}\n", 1);
}

test "an architecture dependent type is reported" {
    const source = "fn read() -> u32 {\n    let sector: usize = 0;\n    return 0;\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "usize") != null);
}

test "a signature width is the authors choice off a boundary" {
    const source = "fn read(sector: usize) -> usize {\n    return sector;\n}\n";
    const foreign = "extern \"C\" fn read(sector: usize) -> usize {\n    return sector;\n}\n";

    const implemented = "impl Index<usize> for Table {\n" ++
        "    fn index(&self, at: usize) -> usize {\n        at\n    }\n}\n";

    try expect_count(.rust, source, 2);
    try testing.expect_quiet(@This(), .rust, foreign);
    try testing.expect_quiet(@This(), .rust, implemented);
}

test "a zig line on a foreign boundary dictates its widths without a body" {
    const declared = "extern \"c\" fn memcpy(*anyopaque, *const anyopaque, usize) *anyopaque;\n";

    const pointer = "const Vtable = struct {\n" ++
        "    alloc: *const fn (*anyopaque, len: usize) callconv(.c) ?[*]u8,\n" ++
        "    count: usize,\n};\n";

    try testing.expect_quiet(@This(), .zig, declared);
    try expect_count(.zig, pointer, 1);
}

test "a name alone does not justify a width" {
    try expect_count(.rust, "fn read(count: usize) -> u32 {\n    return 0;\n}\n", 1);
}

test "an index use justifies a width for a local or a parameter" {
    const parameter = "fn read(items: &[u8], steps: usize) -> u8 {\n    items[steps]\n}\n";
    const local = "fn read(items: &[u8]) -> u8 {\n    let at: usize = 1;\n    items[at]\n}\n";

    try testing.expect_quiet(@This(), .rust, parameter);
    try testing.expect_quiet(@This(), .rust, local);
}

test "a stored width is reported whatever its name" {
    const source = "struct Table {\n    count: usize,\n    offsets: Vec<usize>,\n" ++
        "    lines: [usize; 4],\n}\n";

    try expect_count(.rust, source, 3);
    try expect_count(.zig, "const Table = struct {\n    count: usize,\n};\n", 1);
}

test "an element width in a local is quiet" {
    const source = "fn read() -> u32 {\n    let held: Option<usize> = None;\n    return 0;\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a later type argument in a local is an element width" {
    const quiet = "fn read() -> u32 {\n    let held: HashMap<String, usize> = HashMap::new();\n" ++
        "    let pairs = BTreeMap::<isize, isize>::new();\n    return 0;\n}\n";

    const reported = "struct Table {\n    counts: HashMap<String, usize>,\n}\n\n" ++
        "struct Counts(HashMap<(u32, bool), usize>);\n\n" ++
        "fn read() -> u32 {\n    let pair: (u32, usize) = (0, 0);\n    return 0;\n}\n";

    try testing.expect_quiet(@This(), .rust, quiet);
    try expect_count(.rust, reported, 3);
}

test "a rust tuple struct's field stores its element width" {
    const source = "struct Offsets(Vec<usize>);\n\nstruct Lines(pub [usize; 4], u32);\n";

    try expect_count(.rust, source, 2);
}

test "a zig later type constructor argument in a local is an element width" {
    const source = "fn read() void {\n    var seen: std.AutoHashMap(u32, usize) = undefined;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig element width in a local is quiet" {
    const source = "fn read(items: []const u8, arena: Allocator) !void {\n" ++
        "    var dot: ?usize = null;\n    var stack: std.ArrayList(usize) = .empty;\n" ++
        "    const found = try arena.alloc(usize, items.len);\n" ++
        "    const widths: []const usize = &.{1};\n}\n";

    const drawn = "fn read(prng: *PRNG) void {\n    const chosen = prng.int(usize);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
    try expect_count(.zig, drawn, 1);
}

test "a zig pointer to an index keeps the language width" {
    const indexed = "fn read(text: []const u8, cursor: *usize) u8 {\n" ++
        "    return text[cursor.*];\n}\n";

    const counted = "fn bump(count: *usize) void {\n    count.* += 1;\n}\n";

    try testing.expect_quiet(@This(), .zig, indexed);
    try expect_count(.zig, counted, 1);
}

test "a function handed to a vtable takes the vtable's widths" {
    const source = "fn reader(held: *Held) Reader {\n" ++
        "    return .{ .vtable = &.{ .stream = stream } };\n}\n\n" ++
        "fn stream(held: *Reader, length: usize) StreamError!usize {\n    return length;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a container function a nested prong hands over takes the widths it fills" {
    const returned = "const Parser = struct {\n" ++
        "    fn seek(parser: *Parser, offset: isize) void {\n        _ = parser;\n" ++
        "        _ = offset;\n    }\n};\n\nfn pick(state: State, byte: u8) Seek {\n" ++
        "    return switch (state) {\n        .begin => switch (byte) {\n" ++
        "            ' ' => Parser.seek,\n            else => Parser.seek,\n        },\n" ++
        "    };\n}\n";

    const aliased = "const Parser = struct {\n" ++
        "    fn seek(parser: *Parser, offset: isize) void {\n        _ = parser;\n" ++
        "        _ = offset;\n    }\n};\n\nfn pick(state: State, byte: u8) void {\n" ++
        "    const chosen = switch (state) {\n        .begin => switch (byte) {\n" ++
        "            ' ' => Parser.seek,\n            else => Parser.seek,\n        },\n" ++
        "    };\n    _ = chosen;\n}\n";

    try testing.expect_quiet(@This(), .zig, returned);
    try expect_count(.zig, aliased, 1);
}

test "a go conversion is a cast" {
    const source = "package fixture\n\nfunc take(value int32) int32 {\n" ++
        "\treturn int32(int(value))\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a closure parameter is reported" {
    try expect_count(.rust, "fn read() -> u32 {\n    let f = |x: usize| x;\n    return 0;\n}\n", 1);
}

test "a cast to a width is exempt" {
    const source = "fn read(sector: u32) -> u32 {\n    let value = sector as usize;\n" ++
        "return 0;\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a sized type is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn read(count: u32) -> u32 {\n    return 0;\n}\n");
}
