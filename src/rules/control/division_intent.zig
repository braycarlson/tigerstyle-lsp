const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;
const parameter_count_max = scylla.limits.parameter_count_max;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Show your intent with respect to division. For example, use " ++
                "`@divExact()`, `@divFloor()` or `div_ceil()` to show the reader you've thought " ++
                "through all the interesting scenarios where rounding may be involved.\"",
        },
    },
    .code = "TS040",
    .default_on = false,
    .description = "Integer division names the way it rounds, because the remainder is " ++
        "discarded either way.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "division-intent",
    .severity = .information,
    .summary = "Say which way a division rounds",
    .url = "",
};

const Operand = enum {
    float,
    integer,
    signed,
    unknown,
    unsigned,
};

const Operation = enum {
    divides,
    remainders,
};

const ViewBefore = struct {
    context: *const Context,
    offset: u32,

    fn precedes(before: ViewBefore, position: u32) bool {
        return before.context.view(position).span().offset < before.offset;
    }
};

const cast_word = "as";
const divisor_shift_max: u32 = 12;
const dot_mark = '.';
const float_prefixes = [_][]const u8{ "@float", "float" };
const member_count = "count";
const member_length = "len";
const radix_prefixes = [_][]const u8{ "0x", "0b", "0o" };
const remainder_word = "%";
const self_type_builtin = "@This";

pub fn run(context: *const Context, sink: *Sink) void {
    if (!context.conventions.division_names_rounding) return;

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);
        const operation = operation_of(context, token) orelse continue;
        const first = operand_start(context, index);
        const last = operand_end(context, index + 1);

        assert(first <= index);
        assert(last > index);

        if (!reports(context, operation, index, first, last)) continue;

        const span = stream.span_of_range(context.tokens, first, last);

        switch (operation) {
            .divides => sink.report(
                span,
                "the division discards a remainder; name the way it rounds",
            ),
            .remainders => sink.report(
                span,
                "the remainder takes its sign from one operand; name whether it follows the " ++
                    "dividend or the divisor",
            ),
        }
    }
}

fn operation_of(context: *const Context, token: Token) ?Operation {
    assert(token.end() <= context.source.len);

    if (token.is_punctuation(.slash)) return .divides;
    if (!token.is_punctuation(.other)) return null;
    if (!std.mem.eql(u8, context.text(token), remainder_word)) return null;

    assert(token.length == remainder_word.len);

    return .remainders;
}

fn reports(context: *const Context, operation: Operation, index: u32, first: u32, last: u32) bool {
    assert(first <= index);
    assert(index < last);

    const cast = casts_to_a_float(context, last);
    const left = operand_kind(context, first, index);
    const right: Operand = if (cast) .float else operand_kind(context, index + 1, last);
    if (!integer_operands(context, left, right)) return false;

    switch (operation) {
        .remainders => return left == .signed,
        .divides => {
            if (left != .unsigned) return true;
            if (index + 1 >= context.tokens.len) return true;
            return !is_shift(context, context.tokens[index + 1]);
        },
    }
}

fn integer_operands(context: *const Context, left: Operand, right: Operand) bool {
    if (left == .float) return false;
    if (right == .float) return false;

    assert(left != .float);
    assert(right != .float);

    if (context.conventions.division_assumes_integers) return true;
    if (left == .integer) return true;
    if (right == .integer) return true;
    return is_declared(left) and is_declared(right);
}

fn is_declared(operand: Operand) bool {
    const declared = switch (operand) {
        .signed, .unsigned => true,
        .float, .integer, .unknown => false,
    };

    if (declared) assert(operand != .unknown);

    return declared;
}

fn operand_kind(context: *const Context, start: u32, end: u32) Operand {
    const stop = @min(end, @as(u32, @intCast(context.tokens.len)));

    assert(start <= end);
    assert(stop <= context.tokens.len);

    if (stop <= start) return .unknown;

    var kind: Operand = .unknown;
    var nested_end: u32 = start;

    for (context.tokens[start..stop], start..) |token, position| {
        const offset: u32 = @intCast(position);
        const text = context.text(token);
        if (is_float_token(token, text)) return .float;
        if (offset < nested_end) continue;

        if (opens_an_index_or_arguments(context, start, offset)) {
            const close = context.pairs.partner_of(offset) orelse offset;

            assert(close >= offset);

            nested_end = close + 1;

            continue;
        }

        if (is_integer_token(context, token, start, offset)) kind = .integer;
    }

    assert(kind == .unknown or kind == .integer);

    if (kind != .unknown) return kind;
    if (member_is_float(context, start, stop)) return .float;
    if (stop != start + 1) return kind;
    if (context.tokens[start].kind != .identifier) return kind;
    return declared_kind(context, start);
}

fn member_is_float(context: *const Context, start: u32, stop: u32) bool {
    const tokens = context.tokens;

    assert(start < stop);
    assert(stop <= tokens.len);

    if (stop - start < 3) return false;

    const last = stop - 1;

    const called = tokens[last].is_punctuation(.paren_close) and
        tokens[last - 1].is_punctuation(.paren_open);

    const member = if (called) last - 2 else last;
    if (member <= start) return false;
    if (tokens[member].kind != .identifier) return false;
    if (!tokens[member - 1].is_punctuation(.dot)) return false;

    const name = context.text(tokens[member]);
    if (called) return method_is_float(context, name);
    if (receiver_spelled(context, start, stop)) |spelled| return names_a_float_type(spelled);
    return field_is_float(context, name);
}

fn receiver_spelled(context: *const Context, start: u32, stop: u32) ?[]const u8 {
    assert(start < stop);
    assert(stop <= context.tokens.len);

    if (expression_spanning(context, start, stop)) |view| {
        if (context.tables.receiver_type_of(view, view)) |spelled| return spelled;
    }

    if (stop - start != 3) return null;
    if (inline_field_spelled(context, start)) |spelled| return spelled;

    const container = self_qualified_type_of(context, start) orelse return null;
    return field_spelled(context, container, context.text(context.tokens[start + 2]));
}

fn inline_field_spelled(context: *const Context, head: u32) ?[]const u8 {
    const tokens = context.tokens;

    assert(head + 2 < tokens.len);

    const receiver = context.text(tokens[head]);
    const field = context.text(tokens[head + 2]);
    const function = context.function_at(tokens[head].offset) orelse return null;
    const held = function.as_function() orelse return null;

    var parameters = held.parameters();

    for (0..parameter_count_max + 1) |_| {
        const parameter = parameters.next() orelse return null;
        const named = parameter.name orelse continue;
        const span = parameter.type_span orelse continue;

        if (!std.mem.eql(u8, context.front_text(named), receiver)) continue;
        return struct_field_spelled(context, span, field);
    }

    return null;
}

fn struct_field_spelled(context: *const Context, span: Span, field: []const u8) ?[]const u8 {
    const tokens = context.tokens_in(span);

    assert(field.len > 0);

    if (tokens.len < 4) return null;
    if (!tokens[0].is_keyword(.@"struct")) return null;

    var braces: u32 = 0;
    var groups: u32 = 0;

    for (tokens, 0..) |token, offset| {
        if (token.kind == .block_start) braces += 1;
        if (token.kind == .block_end) braces -|= 1;
        if (opens_a_group(token)) groups += 1;
        if (closes_a_group(token)) groups -|= 1;
        if (braces != 1) continue;
        if (groups != 0) continue;
        if (offset + 2 >= tokens.len) return null;
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), field)) continue;
        if (!tokens[offset + 1].is_punctuation(.colon)) continue;
        return field_type_text(context, tokens[offset + 2 ..]);
    }

    return null;
}

fn field_type_text(context: *const Context, tokens: []const Token) ?[]const u8 {
    assert(tokens.len > 0);

    var groups: u32 = 0;
    var end = tokens[0].offset;

    for (tokens) |token| {
        if (groups == 0) {
            if (token.kind == .block_end) break;
            if (token.is_punctuation(.comma)) break;
            if (token.is_punctuation(.assign)) break;
        }

        if (token.kind == .block_start) groups += 1;
        if (token.kind == .block_end) groups -|= 1;
        if (opens_a_group(token)) groups += 1;
        if (closes_a_group(token)) groups -|= 1;

        end = token.end();
    }

    if (end == tokens[0].offset) return null;

    assert(end > tokens[0].offset);

    return scan.trim_ascii(context.source[tokens[0].offset..end]);
}

fn opens_a_group(token: Token) bool {
    if (token.is_punctuation(.paren_open)) return true;
    return token.is_punctuation(.bracket_open);
}

fn closes_a_group(token: Token) bool {
    if (token.is_punctuation(.paren_close)) return true;
    return token.is_punctuation(.bracket_close);
}

fn expression_spanning(context: *const Context, start: u32, stop: u32) ?View {
    assert(start < stop);
    assert(stop <= context.tokens.len);

    const offset = context.tokens[start].offset;
    const end = context.tokens[stop - 1].end();
    const positions = context.front.nodes_of(.expression);
    const before: ViewBefore = .{ .context = context, .offset = offset };
    const first = std.sort.partitionPoint(u32, positions, before, ViewBefore.precedes);

    assert(first <= positions.len);

    for (positions[first..]) |position| {
        const view = context.view(position);
        const span = view.span();
        if (span.offset != offset) return null;
        if (span.end() == end) return view;
    }

    return null;
}

fn self_qualified_type_of(context: *const Context, head: u32) ?[]const u8 {
    assert(head < context.tokens.len);

    const name = context.text(context.tokens[head]);
    const function = context.function_at(context.tokens[head].offset) orelse return null;
    const body = context.tokens_in(function.span());

    for (body, 0..) |token, offset| {
        if (offset + 5 >= body.len) return null;
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;
        if (!body[offset + 1].is_punctuation(.colon)) continue;
        if (context.is_path_separator(body[offset + 1])) continue;
        if (body[offset + 2].kind != .identifier) continue;
        if (!body[offset + 3].is_punctuation(.dot)) continue;
        if (body[offset + 4].kind != .identifier) continue;
        if (body[offset + 5].is_punctuation(.dot)) return null;
        if (!names_the_file_itself(context, context.text(body[offset + 2]))) return null;
        return context.text(body[offset + 4]);
    }

    return null;
}

fn names_the_file_itself(context: *const Context, name: []const u8) bool {
    const tokens = context.tokens;

    assert(name.len > 0);

    for (tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);
        if (index + 3 >= tokens.len) return false;
        if (token.kind != .identifier) continue;
        if (context.pairs.depth_of(index) != 0) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;
        if (!tokens[index + 1].is_punctuation(.assign)) continue;
        if (!std.mem.eql(u8, context.text(tokens[index + 2]), self_type_builtin)) continue;
        return tokens[index + 3].is_punctuation(.paren_open);
    }

    return false;
}

fn field_spelled(context: *const Context, container: []const u8, name: []const u8) ?[]const u8 {
    assert(container.len > 0);
    assert(name.len > 0);

    for (context.tables.fields.const_slice()) |*field| {
        if (!std.mem.eql(u8, context.span_text(field.container), container)) continue;
        if (!std.mem.eql(u8, context.span_text(field.name), name)) continue;
        return scan.trim_ascii(context.span_text(field.spelled));
    }

    return null;
}

fn field_is_float(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    var floats: u32 = 0;

    for (context.tables.fields.const_slice()) |*field| {
        if (!std.mem.eql(u8, context.span_text(field.name), name)) continue;

        if (!names_a_float_type(scan.trim_ascii(context.span_text(field.spelled)))) {
            return false;
        }

        floats += 1;
    }

    return floats > 0;
}

fn method_is_float(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    var floats: u32 = 0;

    for (context.tables.functions()) |*function| {
        if (!std.mem.eql(u8, context.span_text(function.name), name)) continue;

        const held = context.view(function.node).as_function() orelse return false;
        const span = support.returns_span(context, held) orelse return false;
        if (!names_a_float_type(context.span_text(span))) return false;

        floats += 1;
    }

    return floats > 0;
}

fn is_float_token(token: Token, text: []const u8) bool {
    assert(text.len == token.length);

    const float = switch (token.kind) {
        .number => number_is_float(text),
        .identifier => names_a_float_type(text) or names_a_float_conversion(text),
        else => false,
    };

    if (float) assert(text.len > 0);

    return float;
}

fn names_a_float_conversion(text: []const u8) bool {
    assert(text.len > 0);

    for (float_prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return true;
    }

    return false;
}

fn is_integer_token(context: *const Context, token: Token, start: u32, offset: u32) bool {
    assert(start <= offset);
    assert(offset < context.tokens.len);

    const text = context.text(token);

    switch (token.kind) {
        .number => {
            if (number_is_float(text)) return false;
            if (offset == start) return true;
            return !names_a_tuple_field(context, offset);
        },
        .identifier => {
            if (integer_type_of(text) != null) return true;
            return measures_a_length(context, start, offset);
        },
        else => return false,
    }
}

fn names_a_tuple_field(context: *const Context, offset: u32) bool {
    assert(offset > 0);
    assert(offset < context.tokens.len);

    const before = context.tokens[offset - 1];
    if (!before.is_punctuation(.dot)) return false;
    return before.length == 1;
}

fn opens_an_index_or_arguments(context: *const Context, start: u32, offset: u32) bool {
    assert(start <= offset);
    assert(offset < context.tokens.len);

    if (offset == start) return false;

    const token = context.tokens[offset];
    const before = context.tokens[offset - 1];

    const follows_a_value = before.kind == .identifier or
        before.is_punctuation(.paren_close) or
        before.is_punctuation(.bracket_close);

    if (token.is_punctuation(.bracket_open)) return follows_a_value;
    if (!token.is_punctuation(.paren_open)) return false;
    if (follows_a_value) return true;
    return before.is_punctuation(.greater) or before.is_punctuation(.bang);
}

fn casts_to_a_float(context: *const Context, end: u32) bool {
    assert(end <= context.tokens.len);

    if (end + 1 >= context.tokens.len) return false;
    if (!std.mem.eql(u8, context.text(context.tokens[end]), cast_word)) return false;
    return names_a_float_type(context.text(context.tokens[end + 1]));
}

fn measures_a_length(context: *const Context, start: u32, offset: u32) bool {
    assert(start <= offset);
    assert(offset < context.tokens.len);

    if (offset == start) return false;
    if (!context.tokens[offset - 1].is_punctuation(.dot)) return false;

    const text = context.text(context.tokens[offset]);
    if (std.mem.eql(u8, text, member_length)) return true;
    if (!std.mem.eql(u8, text, member_count)) return false;
    if (offset + 1 >= context.tokens.len) return false;
    return context.tokens[offset + 1].is_punctuation(.paren_open);
}

fn declared_kind(context: *const Context, index: u32) Operand {
    assert(index < context.tokens.len);
    assert(context.tokens[index].kind == .identifier);

    const name = context.text(context.tokens[index]);
    const function = context.function_at(context.tokens[index].offset) orelse return .unknown;
    const body = context.tokens_in(function.span());

    for (body, 0..) |token, offset| {
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;
        if (offset + 2 >= body.len) continue;
        if (!body[offset + 1].is_punctuation(.colon)) continue;
        if (context.is_path_separator(body[offset + 1])) continue;
        if (body[offset + 2].kind != .identifier) continue;

        const spelled = context.text(body[offset + 2]);
        if (names_a_float_type(spelled)) return .float;

        const kind = integer_type_of(spelled) orelse continue;
        if (kind != .signed) return kind;

        const use = context.tokens[index].offset;
        if (rebound_before(context, body[offset + 3 ..], name, use)) return .unknown;
        return kind;
    }

    return .unknown;
}

fn rebound_before(context: *const Context, tokens: []const Token, name: []const u8, use: u32) bool {
    assert(name.len > 0);
    assert(use < context.source.len);

    for (tokens, 0..) |token, position| {
        if (token.offset >= use) return false;
        if (!token.is_keyword(.declare)) continue;

        const named = bound_name(tokens, position) orelse continue;
        if (!std.mem.eql(u8, context.text(tokens[named]), name)) continue;
        if (!binding_holds_at(tokens[position..], use)) continue;
        return true;
    }

    return false;
}

fn bound_name(tokens: []const Token, declare: usize) ?usize {
    assert(declare < tokens.len);
    assert(tokens[declare].is_keyword(.declare));

    var named = declare + 1;

    if (named < tokens.len) {
        if (tokens[named].is_keyword(.mutable)) named += 1;
    }

    if (named >= tokens.len) return null;
    if (tokens[named].kind != .identifier) return null;
    return named;
}

fn binding_holds_at(tokens: []const Token, use: u32) bool {
    var depth: u32 = 0;
    var ended = false;

    for (tokens) |token| {
        if (token.offset >= use) return ended;

        if (token.opens_a_group_or_block()) {
            depth += 1;

            continue;
        }

        if (token.closes_a_group_or_block()) {
            if (depth == 0) return false;

            depth -= 1;

            continue;
        }

        if (depth == 0) {
            if (token.is_punctuation(.semicolon)) ended = true;
        }
    }

    return false;
}

fn number_is_float(text: []const u8) bool {
    assert(text.len > 0);

    const number = trimmed_dot(text);

    for (radix_prefixes) |prefix| {
        if (std.mem.startsWith(u8, number, prefix)) return false;
    }

    if (std.mem.findAny(u8, number, ".eE") != null) return true;

    const suffixed = std.mem.endsWith(u8, number, "f32") or std.mem.endsWith(u8, number, "f64");

    if (suffixed) assert(number.len >= 3);

    return suffixed;
}

fn trimmed_dot(text: []const u8) []const u8 {
    assert(text.len > 0);

    if (text.len == 1) return text;
    if (text[text.len - 1] != dot_mark) return text;

    const trimmed = text[0 .. text.len - 1];

    assert(trimmed.len > 0);
    assert(trimmed.len + 1 == text.len);

    return trimmed;
}

fn names_a_float_type(text: []const u8) bool {
    if (text.len < 3) return false;
    if (text[0] != 'f') return false;

    assert(text.len >= 3);
    assert(text[0] == 'f');

    for (text[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }

    return true;
}

fn integer_type_of(text: []const u8) ?Operand {
    if (text.len == 0) return null;

    const kind: Operand = switch (text[0]) {
        'i' => .signed,
        'u' => .unsigned,
        else => return null,
    };

    const rest = text[1..];

    assert(rest.len + 1 == text.len);

    if (std.mem.eql(u8, rest, "size")) return kind;
    if (rest.len == 0) return null;

    assert(rest.len > 0);

    for (rest) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }

    return kind;
}

fn operand_start(context: *const Context, index: u32) u32 {
    assert(index < context.tokens.len);

    var cursor = index;

    for (0..index + 1) |_| {
        if (cursor == 0) break;

        const before = cursor - 1;
        const token = context.tokens[before];

        if (token.closes_a_group()) {
            cursor = context.pairs.open_of(before) orelse before;

            continue;
        }

        if (!is_operand_part(context, token)) break;

        cursor = before;
    }

    assert(cursor <= index);

    return cursor;
}

fn operand_end(context: *const Context, start: u32) u32 {
    assert(start <= context.tokens.len);

    const count: u32 = @intCast(context.tokens.len);
    var cursor = start;

    for (0..count + 1) |_| {
        if (cursor >= count) break;

        const token = context.tokens[cursor];

        if (token.opens_a_group()) {
            const range = context.pairs.arguments_of(cursor) orelse break;

            cursor = range.last + 1;

            continue;
        }

        if (!is_operand_part(context, token)) break;

        cursor += 1;
    }

    const end = @min(@max(cursor, start + 1), count);

    assert(end <= count);

    return end;
}

fn is_operand_part(context: *const Context, token: Token) bool {
    const part = switch (token.kind) {
        .identifier, .number, .string => true,
        .punctuation => |punctuation| switch (punctuation) {
            .colon => true,
            .dot => std.mem.allEqual(u8, context.text(token), dot_mark),
            else => false,
        },
        .block_end, .block_start, .comment, .keyword, .newline => false,
    };

    if (part) assert(token.kind != .newline);
    if (part) assert(token.kind != .comment);

    return part;
}

fn is_shift(context: *const Context, token: Token) bool {
    assert(token.end() <= context.source.len);

    if (token.kind != .number) return false;

    const value = scan.decimal_read(trimmed_dot(context.text(token))) orelse return false;
    if (value == 0) return false;
    if (value & (value - 1) != 0) return false;

    assert(value > 0);
    assert(@popCount(value) == 1);

    return @ctz(value) <= divisor_shift_max;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a division with nothing after it stays inside the token stream" {
    try expect_count(.zig, "/", 1);
}

test "a division at the end of a body stays inside the token stream" {
    try expect_count(.zig, "fn f() void {\n    a = b /", 1);
}

test "a zig field chain is not a fraction" {
    try expect_count(.zig, "fn f(self: Grid) u32 {\n    return self.count / self.width;\n}\n", 1);
}

test "a zig member the file declares as a float is a float" {
    const source = "const Size = struct {\n    height: f64,\n};\n\n" ++
        "const Bounds = struct {\n    top: f64,\n\n    fn span(self: Bounds) f64 {\n" ++
        "        return self.top;\n    }\n};\n\n" ++
        "fn scale(size: Size, bounds: Bounds) f64 {\n" ++
        "    return size.height / bounds.span();\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig local spelled like a foreign member leaves the member an integer" {
    const source = "fn throttle() u64 {\n    const ns_per_s: f64 = 1e9;\n    _ = ns_per_s;\n" ++
        "    return std.time.ns_per_s / 30;\n}\n";

    try expect_count(.zig, source, 1);
}

test "a zig member the file declares as an integer still reports" {
    const source = "const Size = struct {\n    height: u32,\n};\n\n" ++
        "const Other = struct {\n    height: f64,\n};\n\n" ++
        "fn half(size: Size, other: Size) u32 {\n" ++
        "    return size.height / other.height;\n}\n";

    try expect_count(.zig, source, 1);
}

test "a zig member resolved through its receiver's declared type is a float" {
    const declared = "const Size = struct {\n    height: f64,\n};\n\n" ++
        "const Box = struct {\n    height: u32,\n};\n\n" ++
        "fn scale(group: Size, target: f64) f64 {\n    return target / group.height;\n}\n";

    const integer = "const Size = struct {\n    height: f64,\n};\n\n" ++
        "const Box = struct {\n    height: u32,\n};\n\n" ++
        "fn scale(box: Box, target: u32) u32 {\n    return target / box.height;\n}\n";

    try testing.expect_quiet(@This(), .zig, declared);
    try expect_count(.zig, integer, 1);
}

test "a zig member of a type the file qualifies by its own name is a float" {
    const qualified = "const Glyph = @This();\n\n" ++
        "pub const Size = struct {\n    height: f64,\n};\n\n" ++
        "const Constraint = struct {\n    height: u32,\n\n" ++
        "    fn scale(group: Glyph.Size, target: f64) f64 {\n" ++
        "        return target / group.height;\n    }\n};\n";

    const integer = "const Glyph = @This();\n\n" ++
        "pub const Size = struct {\n    height: f64,\n};\n\n" ++
        "const Constraint = struct {\n    height: u32,\n\n" ++
        "    fn scale(constraint: Glyph.Constraint, target: u32) u32 {\n" ++
        "        return target / constraint.height;\n    }\n};\n";

    try testing.expect_quiet(@This(), .zig, qualified);
    try expect_count(.zig, integer, 1);
}

test "a zig float parameter is quiet" {
    const source = "fn f(a: f32, b: f32) f32 {\n    return a / b;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a power of two divisor only shifts an unsigned operand" {
    const source = "fn f(a: u32, b: i32) i32 {\n    const c = a / 4;\n    return b / 4 + c;\n}\n";

    try expect_count(.zig, source, 1);
}

test "a remainder reports only a signed operand" {
    const source = "fn f(a: u32, b: i32) i32 {\n    const c = a % 4;\n    return b % 4 + c;\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "remainder") != null);
}

test "a rust name a let rebinds before its use loses its declared type" {
    const shadowed = "fn f(total: i64) -> u32 {\n    let total = total.unsigned_abs();\n" ++
        "    (total % 60) as u32\n}\n";

    const scoped = "fn f(total: i64) -> i64 {\n    {\n" ++
        "        let total = total.unsigned_abs();\n    }\n    total % 60\n}\n";

    const initializer = "fn f(total: i64) -> i64 {\n    let total = total % 60;\n    total\n}\n";

    try testing.expect_quiet(@This(), .rust, shadowed);
    try expect_count(.rust, scoped, 1);
    try expect_count(.rust, initializer, 1);
}

test "a rust division of declared integers is reported" {
    try expect_count(.rust, "fn f(a: u32, b: u32) -> u32 {\n    a / b\n}\n", 1);
}

test "a rust division with decisive integer evidence is reported" {
    const source = "fn f(items: &[u32], x: u32) -> usize {\n    let a = items.len() / 2;\n" ++
        "let b = x as u64 / y as u64;\n    a + b as usize\n}\n";

    try expect_count(.rust, source, 2);
}

test "a rust number with a trailing dot keeps its integer evidence" {
    const source = "fn f(x: f64) -> f64 {\n    let a = 0. / (x - x);\n    let b = x / 2.;\n" ++
        "    a + b\n}\n";

    try expect_count(.rust, source, 1);
}

test "an index, a tuple field, or a cast to a float is no integer evidence" {
    const quiet = "fn f(t: &[f32; 8], start: f32, end: f32, count: usize, scale: Scale) " ++
        "-> f32 {\n    let a = (t[3] - t[2]).squared() / ((t[5] - t[2]) * (t[4] - t[2]));\n" ++
        "    let b = (end - start) / (count + 1) as f32;\n    let c = a / scale.0;\n" ++
        "    a + b + c\n}\n";

    const reported = "fn f(t: &[u32; 8], count: usize, scale: Scale) -> u32 {\n" ++
        "    let a = t[3] / 2;\n    let b = (count + 1) / 2;\n    let c = scale.0 / 2;\n" ++
        "    a + b + c\n}\n";

    try testing.expect_quiet(@This(), .rust, quiet);
    try expect_count(.rust, reported, 3);
}

test "a zig unwrap ends the operand before it" {
    const source = "fn f(w: W) u64 {\n    return w.start.?.ns / std.time.ns_per_us;\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 2, 21 }});
}

test "a rust division without integer evidence is quiet" {
    const source = "fn f(a: f64, b: f64) -> f64 {\n    let c = a / b;\n    let d = 1.5 / 2.0;\n" ++
        "let e = x as f64 / y as f64;\n    let g = self.count / self.width;\n" ++
        "c + d + e + g\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a zig member of a parameter typed by an inline struct takes that field's type" {
    const floats = "fn depth(v: struct { near: f32, far: f32 }) f32 {\n" ++
        "    return v.far / (v.far - v.near);\n}\n";

    const integers = "fn depth(v: struct { near: u32, far: u32 }) u32 {\n" ++
        "    return v.far / v.near;\n}\n";

    try testing.expect_quiet(@This(), .zig, floats);
    try expect_count(.zig, integers, 1);
}
