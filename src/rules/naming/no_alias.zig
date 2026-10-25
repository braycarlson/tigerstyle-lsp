const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const naming = @import("../naming.zig");
const scan = @import("../../scan.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Declaration = scylla.View.Declaration;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const View = scylla.View;
const parameter_count_max = scylla.limits.parameter_count_max;
const word_in = scan.word_in;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Don't duplicate variables or take aliases to them. This will reduce the " ++
                "probability that state gets out of sync.\"",
        },
    },
    .code = "TS045",
    .default_on = false,
    .description = "A binding that renames another value gives one thing two names, which can " ++
        "disagree.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-alias",
    .severity = .information,
    .summary = "Do not alias a variable",
    .url = "",
};

const comparison_operators = [_][]const u8{ "!=", "<=", "==", ">=" };
const comptime_word = "comptime";
const self_word = "this";
const statement_lookbehind_max: u32 = 64;
const step_operators = [_][]const u8{ "++", "--" };
const target_count_max: u32 = 8;
const storage_markers = [_][]const u8{"undefined"};

pub fn run(context: *const Context, sink: *Sink) void {
    var bindings = naming.bindings_of(context);

    for (0..bindings.count()) |_| {
        const node = bindings.next() orelse break;
        const value = alias_of(context, node) orelse continue;

        assert(value.index() > node.index());
        assert(value.token_end() == value.token_start() + 1);

        sink.report_formatted(value.span(), "the binding is an alias of {s}", .{
            scan.utf8_or(value.text(context.source), "the word"),
        });
    }
}

fn alias_of(context: *const Context, node: View) ?View {
    const declaration = node.as_declaration() orelse return null;

    if (node.ancestor_of(.function) == null) {
        if (node.ancestor_of(.lambda) == null) return null;
    }

    if (declares_inside(node)) return null;
    if (naming.enclosing_loop(node) != null) return null;
    if (copies_into_a_variable(context, declaration)) return null;

    const named = declaration.name_token() orelse return null;
    const alias = context.front_text(named);
    if (support.names_the_discard(context, alias)) return null;
    if (rebinds_an_outer_name(context, node, alias)) return null;

    const value = declaration.value() orelse return null;

    assert(value.index() > node.index());

    if (!names_a_value(context, value)) return null;
    if (converts_representation(context, declaration, value)) return null;

    const text = value.text(context.source);

    assert(text.len > 0);

    if (keeps_a_distinct_name(context, node, alias, text)) return null;
    if (freezes_a_comptime_variable(context, node, alias, value)) return null;
    return value;
}

fn converts_representation(context: *const Context, target: Declaration, value: View) bool {
    if (context.front.language != .zig) return false;

    const target_type = target.type_of() orelse return false;
    const source = context.declaration_of(value.span().offset) orelse return false;
    const declaration = source.as_declaration() orelse return false;
    const source_type = declaration.type_of() orelse return false;
    const target_shape = representation(context, target_type);
    const source_shape = representation(context, source_type);

    return target_shape != .unknown and source_shape != .unknown and target_shape != source_shape;
}

const Representation = enum { unknown, array, vector };

fn representation(context: *const Context, initial: View) Representation {
    var node = initial;

    for (0..16) |_| {
        const text = scan.trim_ascii(node.text(context.source));
        if (std.mem.startsWith(u8, text, "@Vector(")) return .vector;

        if (std.mem.startsWith(u8, text, "[")) {
            if (text.len < 2) return .unknown;
            if (text[1] == ']') return .unknown;
            if (text[1] == '*') return .unknown;
            return .array;
        }

        if (node.category() != .name) return .unknown;

        const source = context.declaration_of(node.span().offset) orelse return .unknown;
        const declaration = source.as_declaration() orelse return .unknown;

        node = declaration.value() orelse return .unknown;
    }

    return .unknown;
}

fn rebinds_an_outer_name(context: *const Context, node: View, alias: []const u8) bool {
    assert(alias.len > 0);

    const words = context.conventions.outer_scope_words;
    if (words.len == 0) return false;

    const function = node.ancestor_of(.function) orelse return false;
    const first = context.lexer_index_from(function.span().offset);
    const last = context.lexer_index_from(node.span().offset);

    assert(first <= last);

    var keyword_line: ?u32 = null;

    for (context.tokens[first..last]) |token| {
        const text = context.text(token);

        if (scan.word_listed(words, text)) {
            keyword_line = context.line_of(token.offset);

            continue;
        }

        const line = keyword_line orelse continue;

        if (context.line_of(token.offset) != line) {
            keyword_line = null;

            continue;
        }

        if (std.mem.eql(u8, text, alias)) return true;
    }

    return false;
}

fn copies_into_a_variable(context: *const Context, declaration: Declaration) bool {
    if (!context.conventions.compiler_rejects_an_unmutated_variable) return false;

    assert(declaration.view.span().end() <= context.source.len);
    assert(declaration.view.index() < context.front.node_count());

    return declaration.is_mutable();
}

fn freezes_a_comptime_variable(
    context: *const Context,
    node: View,
    alias: []const u8,
    value: View,
) bool {
    if (!context.conventions.compiler_rejects_an_unmutated_variable) return false;

    if (!runs_at_compile_time(context, node)) {
        if (!lends_past_its_block(context, node, alias)) return false;
    }

    assert(alias.len > 0);
    assert(value.index() > node.index());

    const source = context.declaration_of(value.span().offset) orelse return false;
    const held = source.as_declaration() orelse return false;

    assert(source.index() < context.front.node_count());

    return held.is_mutable();
}

fn lends_past_its_block(context: *const Context, node: View, alias: []const u8) bool {
    const block = node.parent() orelse return false;
    const start = context.lexer_index_from(node.span().end());
    const end = context.lexer_index_from(block.span().end());

    assert(alias.len > 0);
    assert(block.index() < node.index());

    if (start >= end) return false;

    for (context.tokens[start..end], start..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), alias)) continue;

        const lead = lent_from(context, index) orelse continue;
        if (escapes_after(context, lead)) return true;
    }

    return false;
}

fn lent_from(context: *const Context, index: u32) ?u32 {
    const tokens = context.tokens;

    assert(index < tokens.len);

    if (index > 0) {
        if (tokens[index - 1].is_punctuation(.ampersand)) return index - 1;
    }

    if (index + 1 >= tokens.len) return null;
    if (tokens[index + 1].is_punctuation(.bracket_open)) return index;
    return null;
}

fn escapes_after(context: *const Context, lead: u32) bool {
    const tokens = context.tokens;
    const before = context.significant_before(lead) orelse return false;
    const token = tokens[before];

    assert(before < lead);

    if (token.is_keyword(.@"return")) return true;
    if (token.is_keyword(.@"break")) return true;
    if (token.is_punctuation(.assign)) return !declares_the_target(context, before);
    if (token.kind != .identifier) return false;

    const colon = context.significant_before(before) orelse return false;
    if (!tokens[colon].is_punctuation(.colon)) return false;

    const keyword = context.significant_before(colon) orelse return false;
    return tokens[keyword].is_keyword(.@"break");
}

fn declares_the_target(context: *const Context, assign: u32) bool {
    assert(assign < context.tokens.len);

    var cursor = assign;

    for (0..statement_lookbehind_max) |_| {
        cursor = context.significant_before(cursor) orelse return false;

        const token = context.tokens[cursor];
        if (token.is_keyword(.constant)) return true;
        if (token.is_keyword(.mutable)) return true;
        if (token.is_punctuation(.semicolon)) return false;
        if (token.kind == .block_start) return false;
        if (token.kind == .block_end) return false;
    }

    return true;
}

fn runs_at_compile_time(context: *const Context, node: View) bool {
    var ancestors = node.ancestors();

    assert(node.span().end() <= context.source.len);

    for (0..ancestors.remaining + 1) |_| {
        const parent = ancestors.next() orelse return false;

        assert(parent.index() < node.index());

        switch (parent.category()) {
            .function, .lambda => return false,
            else => {},
        }

        if (parent.category() != .block) continue;

        const open = context.lexer_index_from(parent.span().offset);
        if (open == 0) continue;
        if (open >= context.tokens.len) continue;
        if (std.mem.eql(u8, context.text(context.tokens[open - 1]), comptime_word)) return true;
    }

    return false;
}

fn declares_inside(node: View) bool {
    assert(node.as_declaration() != null);

    var children = node.children_of(.declaration);

    for (0..children.remaining) |_| {
        const child = children.next() orelse return false;

        assert(child.category() == .declaration);

        if (child.as_declaration() != null) return true;
    }

    return false;
}

fn names_a_value(context: *const Context, value: View) bool {
    if (value.token_end() != value.token_start() + 1) return false;

    const text = value.text(context.source);
    const self_reference = value.category() == .expression and std.mem.eql(u8, text, self_word);

    if (value.category() != .name) {
        if (!self_reference) return false;
    }

    if (value.category() != .name) assert(self_reference);

    assert(value.token_start() < value.token_end());

    if (naming.is_screaming(text)) return false;
    if (support.is_literal_constant(text)) return false;
    if (support.is_primitive_type(context, text)) return false;
    if (word_in(&storage_markers, text)) return false;
    return true;
}

fn keeps_a_distinct_name(
    context: *const Context,
    node: View,
    alias: []const u8,
    text: []const u8,
) bool {
    assert(text.len > 0);
    assert(node.as_declaration() != null);

    if (std.mem.eql(u8, alias, text)) return true;
    if (names_a_type(alias, text)) return true;
    if (declares_a_member(node)) return true;
    if (loop_binds(context, node, text)) return true;
    if (rebinds(context, node, alias)) return true;
    if (binds_a_parameter(context, node, alias)) return true;
    return reassigned(context, node, alias);
}

fn names_a_type(name: []const u8, value: []const u8) bool {
    assert(value.len > 0);

    if (name.len == 0) return false;
    if (!std.ascii.isUpper(name[0])) return false;
    return std.ascii.isUpper(value[0]);
}

fn binds_a_parameter(context: *const Context, node: View, alias: []const u8) bool {
    const owner = naming.enclosing_body(node) orelse return false;
    const function = owner.as_function() orelse return false;

    assert(owner.index() < node.index());
    assert(function.view.index() == owner.index());

    var parameters = function.parameters();

    for (0..parameter_count_max + 1) |_| {
        const parameter = parameters.next() orelse return false;
        const name = parameter.name orelse continue;
        if (std.mem.eql(u8, context.front_text(name), alias)) return true;
    }

    return false;
}

fn rebinds(context: *const Context, node: View, alias: []const u8) bool {
    const owner = naming.enclosing_body(node) orelse return false;
    const scope = owner.span();
    const before = node.span().offset;

    assert(scope.offset <= before);

    var bindings = naming.bindings_of(context);

    for (0..bindings.count()) |_| {
        const held = bindings.next() orelse return false;
        const span = held.span();
        if (span.offset >= before) continue;
        if (span.offset < scope.offset) continue;
        if (span.end() > scope.end()) continue;
        if (span.end() >= node.span().end()) continue;
        if (!parent_holds(held, before)) continue;

        const token = identifier_first(context, span) orelse continue;
        if (std.mem.eql(u8, context.text(token), alias)) return true;
    }

    return false;
}

fn parent_holds(held: View, offset: u32) bool {
    const parent = held.parent() orelse return false;
    const span = parent.span();

    assert(parent.index() < held.index());

    if (span.offset > offset) return false;
    return offset < span.end();
}

fn identifier_first(context: *const Context, span: scylla.Span) ?scylla.Token {
    for (context.tokens_in(span)) |token| {
        if (token.kind != .identifier) continue;

        assert(token.offset >= span.offset);

        return token;
    }

    return null;
}

fn loop_binds(context: *const Context, node: View, value: []const u8) bool {
    const owner = naming.enclosing_body(node) orelse return false;
    const outer = owner.span().offset;
    const own = node.span().offset;

    assert(outer <= own);

    var ancestors = node.ancestors();

    for (0..ancestors.remaining + 1) |_| {
        const parent = ancestors.next() orelse return false;

        assert(parent.index() < node.index());

        switch (parent.category()) {
            .function, .lambda => return false,
            else => {},
        }

        if (parent.span().offset <= outer) return false;

        if (parent.category() != .block) {
            if (header_names(context, parent, own, value)) return true;
        }
    }

    return false;
}

fn header_names(context: *const Context, parent: View, own: u32, value: []const u8) bool {
    const body = parent.child_first_of(.block);
    const limit = if (body) |held| @min(held.span().offset, own) else own;

    assert(limit <= own);

    for (context.tokens_in(parent.span())) |token| {
        if (token.kind == .block_start) break;
        if (token.offset >= limit) break;
        if (token.kind != .identifier) continue;

        assert(token.offset < own);

        if (std.mem.eql(u8, context.text(token), value)) return true;
    }

    return false;
}

fn declares_a_member(node: View) bool {
    var ancestors = node.ancestors();

    for (0..ancestors.remaining + 1) |_| {
        const parent = ancestors.next() orelse return false;

        assert(parent.index() < node.index());

        switch (parent.category()) {
            .@"struct" => return true,
            .function, .lambda => return false,
            else => {},
        }
    }

    return false;
}

fn reassigned(context: *const Context, node: View, alias: []const u8) bool {
    const owner = naming.enclosing_body(node) orelse return false;
    const scope = owner.span();
    const after = node.span().end();

    assert(scope.offset <= node.span().offset);

    var bindings = naming.bindings_of(context);

    for (0..bindings.count()) |_| {
        const held = bindings.next() orelse break;
        const span = held.span();
        if (span.offset < after) continue;
        if (span.offset < scope.offset) continue;
        if (span.end() > scope.end()) continue;

        const tokens = context.tokens_in(span);
        if (tokens.len < 2) continue;
        if (tokens[0].kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(tokens[0]), alias)) continue;

        const operator = context.text(tokens[1]);
        if (assigns(operator)) return true;
        if (word_in(&step_operators, operator)) return true;
    }

    const block = node.parent() orelse return false;
    return assigned_as_a_target(context, after, block.span().end(), alias);
}

fn assigned_as_a_target(context: *const Context, after: u32, end: u32, alias: []const u8) bool {
    const tokens = context.tokens;
    const first = context.lexer_index_from(after);
    const last = context.lexer_index_from(end);

    assert(alias.len > 0);
    assert(after <= end);

    if (first >= last) return false;

    for (tokens[first..last], first..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), alias)) continue;

        const operator = past_targets(context, index, last) orelse continue;
        const text = context.text(tokens[operator]);

        if (tokens[operator].is_punctuation(.assign_declare)) continue;
        if (!opens_a_statement(context, targets_start(context, index))) continue;
        if (assigns(text)) return true;
        if (word_in(&step_operators, text)) return true;
    }

    return false;
}

fn past_targets(context: *const Context, index: u32, last: u32) ?u32 {
    const tokens = context.tokens;

    assert(index < last);
    assert(last <= tokens.len);

    var cursor = index + 1;

    for (0..target_count_max) |_| {
        if (cursor >= last) return null;
        if (!tokens[cursor].is_punctuation(.comma)) return cursor;
        if (cursor + 1 >= last) return null;
        if (tokens[cursor + 1].kind != .identifier) return null;

        cursor += 2;
    }

    return null;
}

fn targets_start(context: *const Context, index: u32) u32 {
    const tokens = context.tokens;

    assert(index < tokens.len);

    var first = index;

    for (0..target_count_max) |_| {
        if (first < 2) return first;
        if (!tokens[first - 1].is_punctuation(.comma)) return first;
        if (tokens[first - 2].kind != .identifier) return first;

        first -= 2;
    }

    assert(first <= index);

    return first;
}

fn opens_a_statement(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    var cursor = index;

    for (0..statement_lookbehind_max) |_| {
        if (cursor == 0) return true;

        cursor -= 1;

        const token = context.tokens[cursor];

        switch (token.kind) {
            .comment => continue,
            .block_end, .block_start, .newline => return true,
            .keyword => |keyword| return switch (keyword) {
                .constant, .declare, .mutable => false,
                else => true,
            },
            .punctuation => |punctuation| return punctuation == .semicolon,
            else => return false,
        }
    }

    return false;
}

fn assigns(operator: []const u8) bool {
    if (!std.mem.endsWith(u8, operator, "=")) return false;

    const compares = word_in(&comparison_operators, operator);

    if (compares) assert(operator.len == 2);

    return !compares;
}

fn expect_count(language: scylla.Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

fn expect_message(language: scylla.Language, source: []const u8, text: []const u8) !void {
    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() == 1) {
        if (std.mem.find(u8, findings.message(0), text) != null) return;
    }

    findings.print();

    return error.TestUnexpectedFindings;
}

test "a loop counter is not an alias" {
    const source = "package main\n\nfunc run(top int, bot int) {\n" ++
        "\tfor y := top; y < bot; y++ {\n\t\tuse(y)\n\t}\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a discard is not an alias" {
    try testing.expect_quiet(@This(), .go, "package main\n\nfunc run(held int) {\n\t_ = held\n}\n");
}

test "a binding outside a loop header is still an alias" {
    const source = "package main\n\nfunc run(top int) {\n\tstart := top\n\tuse(start)\n}\n";

    try expect_count(.go, source, 1);
}

test "a zig undefined binding is quiet" {
    try testing.expect_quiet(@This(), .zig, "fn read() void {\n    var a: u32 = undefined;\n}\n");
}

test "a zig binding of a name is an alias" {
    const source = "fn read() void {\n    var a: u32 = 1;\n    const b = a;\n}\n";

    try expect_message(.zig, source, "alias of a");
}

test "a zig variable started from a name is a new variable" {
    const iterated = "fn tally(iterator: Iterator) u32 {\n    var rest = iterator;\n" ++
        "    var total: u32 = 0;\n\n    while (rest.next()) |_| total += 1;\n\n" ++
        "    return total;\n}\n";

    const modified = "fn limited() Limits {\n    var limits = limits_test;\n\n" ++
        "    limits.depth_max = 2;\n\n    return limits;\n}\n";

    try testing.expect_quiet(@This(), .zig, iterated);
    try testing.expect_quiet(@This(), .zig, modified);
}

test "a zig comptime variable frozen into a constant is not an alias" {
    const frozen = "fn kebab_of(comptime snake: []const u8) []const u8 {\n    comptime {\n" ++
        "        var buffer: [snake.len]u8 = snake[0..snake.len].*;\n\n" ++
        "        buffer[0] = '-';\n\n        const kebab = buffer;\n\n" ++
        "        return &kebab;\n    }\n}\n";

    const runtime = "fn read() void {\n    var buffer: [2]u8 = undefined;\n\n" ++
        "    buffer[0] = 1;\n\n    const held = buffer;\n\n    use(&held);\n}\n";

    try testing.expect_quiet(@This(), .zig, frozen);
    try expect_message(.zig, runtime, "alias of buffer");
}

test "a zig constant frozen to lend its bytes past the block is not an alias" {
    const lent = "fn numeric() [:0]const u8 {\n    const text = text: {\n" ++
        "        var buffer: [11]u8 = @splat(0);\n\n        buffer[0] = '1';\n\n" ++
        "        const final = buffer;\n\n        break :text final[0..1 :0];\n    };\n\n" ++
        "    return text;\n}\n";

    const used = "fn numeric() void {\n    var buffer: [11]u8 = @splat(0);\n\n" ++
        "    buffer[0] = '1';\n\n    const final = buffer;\n\n    use(final[0..1]);\n}\n";

    try testing.expect_quiet(@This(), .zig, lent);
    try expect_message(.zig, used, "alias of buffer");
}

test "a source written after the alias is still an alias" {
    const assigned = "package main\n\nfunc run(value int) int {\n\tcopied := value\n" ++
        "\tvalue = 5\n\treturn copied\n}\n";

    try expect_count(.go, assigned, 1);

    const addressed = "package main\n\nfunc run(value int) int {\n\tcopied := value\n" ++
        "\tp := &value\n\t*p = 5\n\treturn copied\n}\n";

    try expect_count(.go, addressed, 1);
}

test "an alias assigned again is a new variable" {
    const stepped = "package main\n\nfunc run(value int) int {\n\tm := value\n\tm += 1\n" ++
        "\treturn m\n}\n";

    try testing.expect_quiet(@This(), .go, stepped);

    const incremented = "package main\n\nfunc run(value int) int {\n\tm := value\n\tm++\n" ++
        "\treturn m\n}\n";

    try testing.expect_quiet(@This(), .go, incremented);
}

test "an alias reassigned in a target list or a nested block is a new variable" {
    const tuple = "package fixture\n\nrun :: proc(path: string) -> string {\n" ++
        "    p := path\n    p, _ = replace(p)\n    return p\n}\n";

    const nested = "fn run(i: usize) -> usize {\n    let mut end = i;\n" ++
        "    while ok(end) {\n        end += 1;\n    }\n    end\n}\n";

    const keyword = "def run(value):\n    held = value\n    call(held=3)\n    return held\n";

    const declared = "package main\n\nfunc run(value int) int {\n\tif value > 1 {\n" ++
        "\t\terr := limit\n\t\treturn err\n\t}\n\tresult, err := other()\n" ++
        "\treturn result + err\n}\n";

    try testing.expect_quiet(@This(), .odin, tuple);
    try testing.expect_quiet(@This(), .rust, nested);
    try expect_message(.python, keyword, "alias of value");
    try expect_message(.go, declared, "alias of limit");
}

test "a javascript self is an alias of this" {
    const source = "function run() {\n    const self = this;\n    return self;\n}\n";

    try expect_message(.javascript, source, "alias of this");
}

test "a python second order alias is an alias" {
    try expect_count(.python, "def run(value):\n    copy = value\n    x = copy\n    return x\n", 2);

    const member = "class Other:\n    def run(self):\n        a = self.a\n        b = a\n" ++
        "        return b\n";

    try expect_count(.python, member, 1);
}

test "a python name a nested function declares nonlocal is the outer binding" {
    const outer = "def handle(app):\n    seen_headers = None\n\n" ++
        "    def start(status, response_headers):\n        nonlocal seen_headers\n" ++
        "        seen_headers = response_headers\n\n    app(start)\n    return seen_headers\n";

    const local = "def start(status, response_headers):\n    headers = response_headers\n" ++
        "    return headers\n";

    try expect_count(.python, outer, 0);
    try expect_count(.python, local, 1);
}

test "a python loop variable is bound by the header alone" {
    const source = "def run(items):\n    for item in items:\n        first = item\n" ++
        "        other = first\n";

    try expect_count(.python, source, 1);
}

test "a compound assignment rebinds an alias" {
    const nullish = "function run(value, other) {\n    let held = value;\n    held ??= other;\n" ++
        "    return held;\n}\n";

    const cleared = "package main\n\nfunc run(value uint32) uint32 {\n\theld := value\n" ++
        "\theld &^= 4\n\treturn held\n}\n";

    const named = "def run(value, other):\n    held = value\n    if (held := other):\n" ++
        "        return held\n    return held\n";

    try testing.expect_quiet(@This(), .javascript, nullish);
    try testing.expect_quiet(@This(), .go, cleared);
    try testing.expect_quiet(@This(), .python, named);
}

test "vector to array coercion changes representation" {
    const source = "const Lanes = @Vector(8, u8);\n" ++
        "fn bytes() void {\n    const lanes: Lanes = @splat(1);\n" ++
        "    const array: [8]u8 = lanes;\n    consume(array);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an explicit annotation does not excuse a same representation alias" {
    const source = "fn bytes() void {\n    const original: [8]u8 = undefined;\n" ++
        "    const alias: [8]u8 = original;\n    consume(alias);\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}
