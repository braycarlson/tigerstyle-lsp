const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const shape = @import("../shape.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"_Order_ matters for readability (even if it doesn't affect semantics). " ++
                "On the first read, a file is read top-down, so put important things near the " ++
                "top. [...] The same goes for `structs`, the order is fields then types then " ++
                "methods.\"",
        },
    },
    .code = "TS044",
    .default_on = false,
    .description = "A type is ordered fields, then nested types, then methods, so its shape " ++
        "reads before its behaviour.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "member-order",
    .severity = .information,
    .summary = "Order a type's members: fields, then types, then methods",
    .url = "",
};

const Rank = enum(u32) {
    field,
    type,
    method,
};

pub fn run(context: *const Context, sink: *Sink) void {
    if (context.conventions.container_words.len == 0) return;

    var nodes = context.views(.@"struct");

    for (0..nodes.remaining) |_| {
        const node = nodes.next() orelse break;
        const container = node.as_container() orelse continue;

        assert(node.category() == .@"struct");

        if (!is_container(context, node)) continue;

        const body = container.body();

        assert(body.index() >= node.index());

        report_first_out_of_order(context, sink, body);
    }
}

fn report_first_out_of_order(context: *const Context, sink: *Sink, body: View) void {
    var members = body.children();
    var reached: Rank = .field;
    var reached_by: ?View = null;

    for (0..members.remaining) |_| {
        const member = members.next() orelse break;
        const rank = rank_of(context, member) orelse continue;

        assert(member.index() > body.index());

        if (@backingInt(rank) >= @backingInt(reached)) {
            reached = rank;
            reached_by = member;

            continue;
        }

        assert(@backingInt(rank) < @backingInt(reached));

        const held = reached_by orelse unreachable;
        const earlier = label_of(context, member, rank);

        sink.report_formatted(
            member.span(),
            "{s} comes after {s}; a type is ordered fields, then types, then methods",
            .{ earlier, label_of(context, held, reached) },
        );

        return;
    }
}

fn label_of(context: *const Context, member: View, rank: Rank) []const u8 {
    assert(member.span().end() <= context.source.len);

    const label = switch (rank) {
        .field => "a field",
        .type => if (declares_a_type(context, member)) "a nested type" else "a constant",
        .method => "a method",
    };

    assert(std.mem.startsWith(u8, label, "a "));

    return label;
}

fn declares_a_type(context: *const Context, member: View) bool {
    const declaration = member.as_declaration() orelse return true;

    assert(member.category() == .declaration);

    if (declaration.value()) |value| {
        if (value.category() == .@"struct") return true;
    }

    const name = declaration.name_token() orelse return false;

    assert(name < context.front.tokens().len);

    return shape.names_a_type(context, context.front_text(name));
}

fn is_container(context: *const Context, node: View) bool {
    const body = context.tokens_in(node.span());

    assert(body.len <= context.tokens.len);
    assert(context.conventions.container_words.len > 0);

    for (body) |token| {
        if (token.kind == .block_start) return false;
        if (!token.is_keyword(.@"struct")) continue;
        return scan.word_listed(context.conventions.container_words, context.text(token));
    }

    return false;
}

fn rank_of(context: *const Context, member: View) ?Rank {
    if (member.category() == .function) return .method;

    const word = leading_word(context, member);

    assert(word.len <= member.span().length);

    if (word.len > 0) {
        if (scan.word_listed(context.conventions.member_type_words, word)) return .type;
        if (scan.word_listed(context.conventions.member_field_words, word)) return .field;
    }

    if (aliases_a_method(context, member)) return .method;
    if (names_a_field(context, member)) return .field;

    assert(member.as_field() == null);

    return null;
}

fn aliases_a_method(context: *const Context, member: View) bool {
    const body = context.tokens_in(member.span());
    if (body.len < 3) return false;
    if (body.len % 2 == 0) return false;

    for (body, 0..) |token, position| {
        if (position % 2 == 1) {
            if (!token.is_punctuation(.assign)) return false;
        } else {
            if (token.kind != .identifier) return false;
        }
    }

    const parent = member.parent() orelse return false;
    const value = context.text(body[body.len - 1]);
    var siblings = parent.children();

    assert(value.len > 0);

    for (0..siblings.remaining) |_| {
        const sibling = siblings.next() orelse return false;
        if (sibling.index() == member.index()) return false;

        const function = sibling.as_function() orelse continue;
        const name = function.name_token() orelse continue;
        if (std.mem.eql(u8, context.front_text(name), value)) return true;
    }

    return false;
}

fn leading_word(context: *const Context, member: View) []const u8 {
    const body = context.tokens_in(member.span());
    const head = @min(body.len, shape.member_modifier_max + 1);

    assert(head <= body.len);
    assert(head <= shape.member_modifier_max + 1);

    for (body[0..head]) |token| {
        if (token.kind == .block_start) break;

        const text = context.text(token);
        if (scan.word_listed(context.conventions.member_type_words, text)) return text;
        if (scan.word_listed(context.conventions.member_field_words, text)) return text;
        if (!token.is_keyword(.other)) return text;
    }

    return "";
}

fn names_a_field(context: *const Context, member: View) bool {
    if (member.as_field() != null) return true;

    const category = member.category();
    const declares = category == .declaration and context.conventions.assignment_declares;

    if (!declares) {
        switch (category) {
            .assignment, .expression => {},
            .declaration => if (member.as_declaration() != null) return true,
            else => return false,
        }
    }

    const body = context.tokens_in(member.span());

    assert(body.len <= context.tokens.len);

    if (body.len < 2) return false;
    if (body[0].kind != .identifier) return false;

    const next = body[1];

    assert(next.offset >= body[0].end());

    if (context.is_path_separator(next)) return false;
    if (next.is_punctuation(.colon)) return true;
    if (next.is_punctuation(.assign)) return true;
    return next.is_punctuation(.comma);
}

fn expect_one(language: scylla.Language, source: []const u8, wanted: ?[]const u8) !void {
    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());

    if (wanted) |text| {
        try std.testing.expect(std.mem.find(u8, findings.message(0), text) != null);
    }
}

test "a zig container reports a field after a method" {
    const source = "const Point = struct {\n    pub fn zero() u32 {\n        return 0;\n" ++
        "}\n\n    x: u32,\n};\n";

    try expect_one(.zig, source, "a field comes after");
}

test "a zig container in order is quiet" {
    const source = "const Point = struct {\n    x: u32,\n\n    const Inner = struct {\n" ++
        "y: u32,\n    };\n\n    pub fn zero() u32 {\n        return 0;\n    }\n};\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a rust impl reports a constant after a method" {
    const source = "impl Reader {\n    fn read(&self) -> u32 {\n        0\n    }\n\n" ++
        "const WIDTH: u32 = 1;\n}\n";

    try expect_one(.rust, source, null);
}

test "a rust struct body is out of scope" {
    try testing.expect_quiet(@This(), .rust, "struct Reader {\n    first: u32,\n}\n");
}

test "a python class reports a field after a method" {
    const source = "class Store:\n    def read(self):\n        return self.limit\n\n" ++
        "    limit = 4\n";

    try expect_one(.python, source, "a field comes after");
}

test "a python class in order is quiet" {
    const source = "class Store:\n    limit = 4\n\n    def read(self):\n" ++
        "        return self.limit\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a python name bound to a method the class declares is a method" {
    const alias = "class Flag:\n    def configure(self):\n        return 1\n\n" ++
        "    config = configure\n    __eq__ = __ne__ = configure\n";

    const field = "class Flag:\n    def configure(self):\n        return 1\n\n" ++
        "    limit = configure_limit\n";

    try testing.expect_quiet(@This(), .python, alias);
    try expect_one(.python, field, "a field comes after");
}

test "a python assignment in a method is not a field" {
    const source = "class Store:\n    limit = 4\n\n    def read(self):\n        total = " ++
        "1\n        return total\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a go struct is out of scope" {
    try testing.expect_quiet(@This(), .go, "type Reader struct {\n\tfirst int\n}\n");
}

test "a rust associated type after a method is reported" {
    const source = "impl Reader {\n    fn read(&self) -> u32 {\n        0\n    }\n\n    type " ++
        "Item = u32;\n}\n";

    try expect_one(.rust, source, "a nested type comes after");
}

test "a zig enum is a container" {
    try expect_one(.zig, "const E = enum(u8) {\n    fn name() void {}\n    a,\n    b,\n};\n", null);
}

test "a zig constant is labelled as one" {
    const source = "const S = struct {\n    fn f() void {}\n\n    const max: u32 = 4;\n};\n";

    try expect_one(.zig, source, "a constant comes after");
}

test "a python nested class after a method is reported" {
    const source = "class Store:\n    def read(self):\n        return 1\n\n    class Inner:\n" ++
        "pass\n";

    try expect_one(.python, source, "a nested type comes after");
}

test "a typescript interface is a container" {
    const source = "interface Range {\n    read(): number;\n    start: number;\n}\n";

    try expect_one(.typescript, source, null);
}
