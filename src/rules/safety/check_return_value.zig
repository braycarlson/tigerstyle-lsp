const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const safety = @import("../safety.zig");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const CallsFunction = scylla.Calls.Function;
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const TestScope = @import("../test_scope.zig");
const View = scylla.View;
const discard_blank = "_, ";
const discard_blanks = "_, _, _, _, _, _, _, ";
const value_count_max: u32 = 8;

pub const rule: Rule = .{
    .citations = &.{
        .{ .standard = "TigerStyle", .text = "\"All errors must be handled.\"" },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 7: \"The return value of non-void functions must be checked " ++
                "by each calling function.\"",
        },
    },
    .code = "TS017",
    .default_on = false,
    .description = "A returned value is used, because a call made only for its effect hides the " ++
        "result it also produced.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "check-return-value",
    .severity = .warning,
    .summary = "Use a return value or discard it explicitly",
    .url = "",
};

pub fn run(context: *const Context, sink: *Sink) void {
    if (TestScope.file_is_a_fixture(context)) return;

    for (context.front.nodes_of(.call)) |position| {
        const call = context.view(position);
        const node = statement_of(context, call) orelse continue;
        const inner = call.span();
        const spelled = call.child_first() orelse continue;

        assert(call.category() == .call);

        if (spelled.span().offset != inner.offset) continue;

        const written = callee_text(context, call, spelled) orelse continue;
        if (written.len == 0) continue;

        const name = safety.resolved(context, written);
        const method = leaf_of(name);

        assert(method.len <= name.len);

        if (discards_nothing(context, name, method)) continue;

        const bare_method = support.bare_call_names_a_method(context, call, name);
        const local = names_a_local(context, call, spelled) and !bare_method;
        if (!returns_a_value(context, call, name, method, local)) continue;

        report(context, sink, node.span(), name, value_count(context, call, name));
    }
}

fn report(context: *const Context, sink: *Sink, span: Span, name: []const u8, values: u32) void {
    const prefix = context.grammar.discard_prefix;
    const spelled = scan.utf8_or(name, "the call");

    comptime assert(discard_blanks.len == discard_blank.len * (value_count_max - 1));

    assert(span.length > 0);
    assert(span.end() <= context.source.len);
    assert(values <= value_count_max);

    const plain = prefix.len == 0 or values == 0;

    if (plain) {
        sink.report_formatted(span, "the value {s} returns is discarded", .{spelled});

        return;
    }

    const blanks = discard_blanks[0 .. (values - 1) * discard_blank.len];

    sink.fix_begin("Discard the return value", .safe, null);
    sink.fix_edit_formatted(.{ .offset = span.offset, .length = 0 }, "{s}{s}", .{ blanks, prefix });
    sink.report_fixed_formatted(span, "the value {s} returns is discarded", .{spelled});
}

fn statement_of(context: *const Context, call: View) ?View {
    assert(call.category() == .call);

    const parent = call.parent() orelse return null;
    const node = if (parent.category() == .expression) parent else call;
    const holder = node.parent() orelse return null;
    if (!safety.holds_statements(holder)) return null;

    const outer = node.span();
    const inner = call.span();
    const opening = safety.span_start(context, inner);
    if (opening >= context.tokens.len) return null;

    const head = context.pairs.receiver_start(opening);

    assert(head <= opening);

    if (!stream.opens_a_statement(context.tokens, head)) return null;
    if (context.tokens[opening].is_keyword(.assert)) return null;
    if (head != safety.span_start(context, outer)) return null;
    if (!ends_the_statement(context, inner, outer)) return null;
    if (!closes_a_statement(context, inner, outer)) return null;
    if (!context.conventions.statements_need_a_function) return node;
    if (node.ancestor_of(.function) != null) return node;
    if (node.ancestor_of(.lambda) != null) return node;
    return null;
}

fn ends_the_statement(context: *const Context, inner: Span, outer: Span) bool {
    const first = safety.span_end(context, inner);
    const last = @max(safety.span_end(context, outer), first);

    assert(first <= last);
    assert(last <= context.tokens.len);

    for (context.tokens[first..last]) |token| {
        if (token.is_punctuation(.semicolon)) continue;

        switch (token.kind) {
            .comment, .newline => {},
            else => return false,
        }
    }

    return true;
}

fn closes_a_statement(context: *const Context, inner: Span, outer: Span) bool {
    if (!context.grammar.statements_end_with_semicolon) return true;

    const first = safety.span_end(context, inner);
    const last = @max(safety.span_end(context, outer), first);

    assert(first <= last);
    assert(last <= context.tokens.len);

    if (last < context.tokens.len) {
        if (context.tokens[last].is_punctuation(.semicolon)) return true;
    }

    for (context.tokens[first..last]) |token| {
        if (token.is_punctuation(.semicolon)) return true;
    }

    return false;
}

fn callee_text(context: *const Context, call: View, spelled: View) ?[]const u8 {
    const held = call.as_call() orelse return null;
    const span = spelled.span();
    const receiver = held.receiver();

    assert(span.end() <= context.source.len);

    const receives = if (receiver) |owner|
        owner.span().offset == span.offset and owner.span().length == span.length
    else
        false;

    if (!receives) return callee_of(context.span_text(span));

    const named = held.name_token() orelse return null;

    assert(named < context.front.tokens().len);

    return context.front_text(named);
}

fn callee_of(written: []const u8) []const u8 {
    var start: usize = 0;

    for (written, 0..) |byte, index| {
        switch (byte) {
            ')', ']' => start = index + 1,
            else => {},
        }
    }

    assert(start <= written.len);

    const rest = std.mem.trimStart(u8, written[start..], scan.ascii_whitespace);
    const dotted = if (std.mem.startsWith(u8, rest, ".")) rest[1..] else rest;
    const callee = std.mem.trimStart(u8, dotted, scan.ascii_whitespace);

    assert(callee.len <= written.len - start);

    return callee;
}

fn leaf_of(name: []const u8) []const u8 {
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return name;

    assert(dot < name.len);
    assert(name[dot] == '.');

    return name[dot + 1 ..];
}

fn discards_nothing(context: *const Context, name: []const u8, method: []const u8) bool {
    const conventions = context.conventions;

    assert(name.len <= context.source.len);
    assert(method.len <= name.len);

    if (scan.word_listed(conventions.call_void_names, name)) return true;
    if (scan.word_listed(conventions.call_void_methods, method)) return true;
    if (scan.word_listed(conventions.call_checked_methods, method)) return true;
    if (scan.word_listed(conventions.call_exempt_names, name)) return true;

    if (context.tables.function_of(name)) |callee| {
        if (!support.function_returns_a_value(context, callee)) return true;
    }

    if (context.tables.function_of(method)) |callee| {
        if (!support.function_returns_a_value(context, callee)) return true;
    }

    return false;
}

fn names_a_local(context: *const Context, call: View, spelled: View) bool {
    const held = call.as_call() orelse return false;
    const receiver = held.receiver() orelse return true;
    const span = receiver.span();

    assert(call.category() == .call);

    if (span.offset != spelled.span().offset) return true;
    if (span.length != spelled.span().length) return true;

    assert(span.end() <= context.source.len);

    return scan.word_listed(context.conventions.receiver_names, context.span_text(span));
}

fn returns_a_value(
    context: *const Context,
    call: View,
    name: []const u8,
    method: []const u8,
    local: bool,
) bool {
    const conventions = context.conventions;

    assert(call.category() == .call);
    assert(method.len <= name.len);

    if (local) {
        if (context.tables.value_of(name)) |value| return value;
    }

    const head = qualified_head(context, call);

    if (scan.word_listed(conventions.call_value_names, name)) return true;
    if (scan.word_listed(conventions.call_value_names, head)) return true;
    if (scan.word_listed(conventions.call_value_methods, method)) return true;
    if (conventions.call_value_methods_niladic.len == 0) return false;
    if (!scan.word_listed(conventions.call_value_methods_niladic, method)) return false;
    return arguments_are_empty(context, call);
}

fn qualified_head(context: *const Context, call: View) []const u8 {
    const head = safety.call_head(context, call.span());
    const tokens = context.tokens;

    var first = safety.span_start(context, head);

    assert(tokens.len > 0);
    assert(head.offset == call.span().offset);

    for (0..safety.call_head_max) |_| {
        if (first < 2) break;
        if (!tokens[first - 1].is_punctuation(.dot)) break;
        if (tokens[first - 2].kind != .identifier) break;

        first -= 2;
    }

    const start = tokens[@min(first, tokens.len - 1)].offset;
    if (start > head.end()) return "";
    return scan.trim_ascii(context.source[start..head.end()]);
}

fn arguments_are_empty(context: *const Context, call: View) bool {
    assert(call.category() == .call);

    var positions = call.positions();

    const offset = for (0..positions.remaining) |_| {
        const position = positions.next() orelse return false;
        const token = call.token_at(position);
        if (token.is_punctuation(.paren_open)) break token.offset;
    } else return false;

    const index = safety.span_start(context, .{ .offset = offset, .length = 0 });

    assert(index <= context.tokens.len);

    if (index + 1 >= context.tokens.len) return false;
    return context.tokens[index + 1].is_punctuation(.paren_close);
}

fn value_count(context: *const Context, call: View, name: []const u8) u32 {
    const conventions = context.conventions;

    assert(call.category() == .call);
    assert(name.len > 0);

    if (!context.grammar.discard_names_each_value) return 1;

    const held = call.as_call() orelse return 0;

    if (held.receiver() == null) {
        const counted = local_value_count(context, name);
        if (counted > 0) return counted;
    }

    if (!scan.word_listed(conventions.call_value_names, name)) return 0;
    if (scan.word_listed(conventions.call_value_names_paired, name)) return 2;
    return 1;
}

fn local_value_count(context: *const Context, name: []const u8) u32 {
    var counted: u32 = 0;

    assert(name.len > 0);

    for (context.tables.functions()) |*function| {
        if (!std.mem.eql(u8, function.name.text(context.source), name)) continue;

        const held = signature_value_count(context, function);
        if (held == 0) return 0;

        if (counted > 0) {
            if (counted != held) return 0;
        }

        counted = held;
    }

    assert(counted <= value_count_max);

    return counted;
}

fn signature_value_count(context: *const Context, function: *const CallsFunction) u32 {
    const held = context.view(function.node).as_function() orelse return 0;
    const span = support.returns_span(context, held) orelse return 0;
    const spelled = scan.trim_ascii(span.text(context.source));

    assert(span.end() <= context.source.len);

    if (spelled.len == 0) return 0;
    if (spelled[0] != '(') return 1;
    return grouped_value_count(spelled);
}

fn grouped_value_count(spelled: []const u8) u32 {
    var depth: u32 = 0;
    var counted: u32 = 1;

    assert(spelled.len > 0);
    assert(spelled[0] == '(');

    for (spelled, 0..) |byte, index| {
        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth == 0) return 0;

                depth -= 1;

                if (depth == 0) {
                    if (index + 1 < spelled.len) return 1;
                }
            },
            ',' => {
                if (depth == 1) counted += 1;
            },
            else => {},
        }
    }

    if (depth > 0) return 0;
    if (counted > value_count_max) return 0;
    return counted;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a bare call reaches no method of the same name" {
    const source = "struct Command;\n\nimpl Command {\n" ++
        "    fn write_help(&mut self) -> u32 {\n        1\n    }\n\n" ++
        "    fn print(&mut self) {\n        write_help(self);\n        self.write_help();\n" ++
        "    }\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    if (findings.count() != 1) findings.print();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a discarded rust insert is reported" {
    const source = "fn run(map: &mut std::collections::HashMap<u32, u32>) {\n    " ++
        "map.insert(1, 2);\n}\n";

    try expect_count(.rust, source, 1);
}

test "a discarded go print is reported and a cast one is quiet" {
    const source = "package p\n\nimport \"fmt\"\n\nfunc run(s string) {\n\tfmt.Println(s)\n" ++
        "\t_ = fmt.Println(s)\n}\n";

    try expect_count(.go, source, 1);
}

test "a discarded python builtin is reported" {
    try expect_count(.python, "def run(items):\n    len(items)\n    items.pop()\n", 2);
}

test "a call of a value another call returns has no callee to read" {
    try expect_count(.python, "def f(data, name):\n    getattr(data, name)()\n", 0);
    try expect_count(.python, "def f(data):\n    sorted(data)\n", 1);
}

test "a discarded odin package call is reported" {
    const source = "package p\n\nrun :: proc(s: string) {\n    strings.trim_space(s)\n}\n";

    try expect_count(.odin, source, 1);
}

test "a constructor statement reads its own name" {
    const source = "fn work() {\n    Reader::new();\n}\n\nfn new() -> u32 {\n    return 1;\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a propagated call is not discarded" {
    const source = "fn work() -> u32 {\n    step()?;\n    return 1;\n}\n\nfn step() -> u32 " ++
        "{\n    return 1;\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a discarded local call is reported" {
    const source = "fn work() {\n    step();\n}\n\nfn step() -> u32 {\n    return 1;\n}\n";

    try expect_count(.rust, source, 1);
}

test "a zig function whose calling convention precedes void returns nothing" {
    const source = "fn write(value: u32) callconv(.c) void {\n    _ = value;\n}\n\n" ++
        "fn place(value: u32) align(4) callconv(.c) void {\n    _ = value;\n}\n\n" ++
        "pub fn run() void {\n    write(1);\n    place(2);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig function whose calling convention precedes a value still returns it" {
    const source = "fn read(value: u32) callconv(.c) u32 {\n    return value;\n}\n\n" ++
        "pub fn run() void {\n    read(1);\n}\n";

    try expect_count(.zig, source, 1);
}

test "a discarded javascript value method is reported" {
    try expect_count(.javascript, "function run(values) {\n    values.join(\",\");\n}\n", 1);
}

test "a returned javascript value method is quiet" {
    const source = "function run(values) {\n    return values.join(\",\");\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "a discarded typescript value method is reported" {
    const source = "function run(values: string[]) {\n    values.join(\",\");\n}\n";

    try expect_count(.typescript, source, 1);
}

test "a javascript function returning undefined is not a value" {
    const source = "function nothing() {\n    return undefined;\n}\n\nfunction run() {\n    " ++
        "nothing();\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "a javascript function returning null is a value" {
    const source = "function nulled() {\n    return null;\n}\n\nfunction run() {\n    " ++
        "nulled();\n}\n";

    try expect_count(.javascript, source, 1);
}

test "a typescript function spelling void is not a value" {
    const source = "function voided(): void {\n    return;\n}\n\nfunction run() {\n    " ++
        "voided();\n}\n";

    try testing.expect_quiet(@This(), .typescript, source);
}

test "a discarded return gains the discard prefix" {
    const python = "def read() -> int:\n    return 1\n\ndef main() -> None:\n    read()\n";
    const expected = "def read() -> int:\n    return 1\n\ndef main() -> None:\n    _ = read()\n";

    try testing.expect_fixed(@This(), .python, python, .unsafe, expected);
}

test "a rust discarded return gains a binding" {
    const source = "fn read() -> u32 {\n    return 1;\n}\n\nfn main() {\n    read();\n}\n";

    const expected = "fn read() -> u32 {\n    return 1;\n}\n\nfn main() {\n    " ++
        "let _ = read();\n}\n";

    try testing.expect_fixed(@This(), .rust, source, .unsafe, expected);
}

test "a call of a function that never returns discards no value" {
    const odin = "package p\n\nfail :: proc() -> ! {\n\tpanic(\"stop\")\n}\n\n" ++
        "one :: proc() -> int {\n\treturn 1\n}\n\nrun :: proc() {\n\tfail()\n\tone()\n}\n";

    const rust = "fn fail() -> ! {\n    panic!(\"stop\");\n}\n\nfn one() -> u32 {\n" ++
        "    return 1;\n}\n\nfn run() {\n    fail();\n    one();\n}\n";

    const python = "from typing import NoReturn\n\n\ndef fail() -> NoReturn:\n" ++
        "    raise SystemExit(1)\n\n\ndef one() -> int:\n    return 1\n\n\n" ++
        "def run() -> None:\n    fail()\n    one()\n";

    try expect_count(.odin, odin, 1);
    try expect_count(.rust, rust, 1);
    try expect_count(.python, python, 1);
}

test "a go discard names each value the callee returns" {
    const source = "package p\n\nimport \"fmt\"\n\nfunc pair() (int, error) {\n" ++
        "\treturn 1, nil\n}\n\nfunc one() int {\n\treturn 1\n}\n\nfunc run(s string) {\n" ++
        "\tpair()\n\tone()\n\tfmt.Println(s)\n}\n";

    const expected = "package p\n\nimport \"fmt\"\n\nfunc pair() (int, error) {\n" ++
        "\treturn 1, nil\n}\n\nfunc one() int {\n\treturn 1\n}\n\nfunc run(s string) {\n" ++
        "\t_, _ = pair()\n\t_ = one()\n\t_, _ = fmt.Println(s)\n}\n";

    try testing.expect_fixed(@This(), .go, source, .unsafe, expected);
}

test "an odin discard names each value the callee returns" {
    const source = "package p\n\npair :: proc() -> (int, bool) {\n\treturn 1, true\n}\n\n" ++
        "named :: proc() -> (n: int, ok: bool) {\n\treturn 1, true\n}\n\n" ++
        "one :: proc() -> (n: int) {\n\treturn 1\n}\n\n" ++
        "run :: proc() {\n\tpair()\n\tnamed()\n\tone()\n}\n";

    const expected = "package p\n\npair :: proc() -> (int, bool) {\n\treturn 1, true\n}\n\n" ++
        "named :: proc() -> (n: int, ok: bool) {\n\treturn 1, true\n}\n\n" ++
        "one :: proc() -> (n: int) {\n\treturn 1\n}\n\n" ++
        "run :: proc() {\n\t_, _ = pair()\n\t_, _ = named()\n\t_ = one()\n}\n";

    try testing.expect_fixed(@This(), .odin, source, .unsafe, expected);
}

test "a go method the value table names reports without a fix" {
    const source = "package p\n\nimport \"strings\"\n\n" ++
        "func run(builder *strings.Builder, s string) {\n\tbuilder.WriteString(s)\n}\n";

    try expect_count(.go, source, 1);
    try testing.expect_fixed(@This(), .go, source, .unsafe, source);
}

test "a go method call never takes its arity from a same-named function of the file" {
    const source = "package p\n\ntype pair struct{}\n\n" ++
        "func (p pair) String() (string, error) {\n" ++
        "\treturn \"\", nil\n}\n\nfunc run(command *Command) {\n" ++
        "\tcommand.Flags().String(\"name\", \"\", \"usage\")\n}\n";

    try expect_count(.go, source, 1);
    try testing.expect_fixed(@This(), .go, source, .unsafe, source);
}
