const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const control = @import("../control.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const TokenRange = Context.TokenRange;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use single-line `if` to assert an implication: `if (a) assert(b)`.\"",
        },
    },
    .code = "TS047",
    .default_on = false,
    .description = "An implication is written as a single-line branch, so the condition and the " ++
        "assertion it guards read as one statement.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "assert-implication",
    .severity = .information,
    .summary = "Write an implication as a single-line `if`",
    .url = "",
};

pub fn run(context: *const Context, sink: *Sink) void {
    var branches = context.views(.branch);

    for (0..branches.remaining) |_| {
        const branch = branches.next() orelse break;
        if (branch.is_an_arm()) continue;

        const header = Frame.header_of(context, branch);

        assert(header <= context.tokens.len);

        if (header >= context.tokens.len) continue;
        if (context.tokens[header].is_keyword(.branch_else)) continue;
        if (binds_a_pattern(context, header)) continue;

        const folds = if (Frame.of(context, branch)) |frame|
            implication_folds(context, frame)
        else
            braceless_implication_folds(context, branch, header);

        if (!folds) continue;

        assert(header < context.tokens.len);

        sink.report(
            context.tokens[header].span(),
            "the branch guards one assertion; state the implication on a single line",
        );
    }
}

fn implication_folds(context: *const Context, frame: Frame) bool {
    assert(frame.header < context.tokens.len);
    assert(frame.start < context.tokens.len);

    if (carries_an_alternative(context, frame)) return false;
    if (condition_wraps(context, .{ .end = frame.start, .start = frame.header })) return false;

    const lines = context.lines_of(frame.span(context.tokens));
    if (lines <= lines_the_formatter_needs(context, frame)) return false;

    const assertion = assertion_alone(context, frame) orelse return false;
    return folds_within_the_line_limit(context, frame.start, assertion);
}

fn braceless_implication_folds(context: *const Context, branch: View, header: u32) bool {
    assert(header < context.tokens.len);

    const span = branch.span();
    const after = context.lexer_index_from(span.end());

    assert(after <= context.tokens.len);

    if (control.significant_after(context, after)) |next| {
        if (context.tokens[next].is_keyword(.branch_else)) return false;
    }

    if (context.lines_of(span) < 2) return false;

    const children = branch.children();
    const body = children.last() orelse return false;
    const body_line = context.line_of(body.span().offset);
    if (body_line <= context.line_of(context.tokens[header].offset)) return false;
    if (context.lines_of(body.span()) != 1) return false;

    const opened = context.lexer_index_from(body.span().offset);
    if (follows_an_else(context, opened)) return false;
    if (condition_wraps(context, .{ .end = opened, .start = header })) return false;
    if (!asserts_alone(context, body)) return false;
    return folds_within_the_line_limit(context, opened, body);
}

fn folds_within_the_line_limit(context: *const Context, opened: u32, assertion: View) bool {
    assert(opened <= context.tokens.len);
    assert(assertion.span().end() <= context.source.len);

    if (context.conventions.formatter_splits_one_line_branches) return true;

    const last = stream.significant_previous(context.tokens, opened) orelse return true;
    const head_line = context.line_span(context.line_of(context.tokens[last].offset));
    const head = context.source[head_line.offset..context.tokens[last].end()];
    if (std.mem.findScalar(u8, head, '\n') != null) return false;

    const start = assertion.span().offset;
    const tail_line = context.line_span(context.line_of(start));
    const tail = scan.trim_ascii(context.source[start..tail_line.end()]);

    var columns: u32 = 0;

    for (head) |byte| columns = support.column_after(columns, byte);

    columns = support.column_after(columns, ' ');

    for (context.grammar.branch_body_word) |byte| columns = support.column_after(columns, byte);

    if (context.grammar.branch_body_word.len > 0) columns = support.column_after(columns, ' ');

    for (tail) |byte| columns = support.column_after(columns, byte);

    return columns <= context.settings.thresholds.line_length_max;
}

fn follows_an_else(context: *const Context, opened: u32) bool {
    assert(opened <= context.tokens.len);

    const before = stream.significant_previous(context.tokens, opened) orelse return false;

    assert(before < opened);

    return context.tokens[before].is_keyword(.branch_else);
}

fn condition_wraps(context: *const Context, condition: TokenRange) bool {
    assert(condition.start < context.tokens.len);
    assert(condition.end <= context.tokens.len);

    if (condition.end <= condition.start) return false;

    const tokens = context.tokens;
    const last = stream.significant_previous(tokens, condition.end) orelse return false;

    assert(last >= condition.start);

    const header_line = context.line_of(tokens[condition.start].offset);
    return context.line_of(tokens[last].offset) > header_line;
}

fn binds_a_pattern(context: *const Context, header: u32) bool {
    assert(header < context.tokens.len);

    if (header + 1 >= context.tokens.len) return false;

    assert(header + 1 < context.tokens.len);

    return context.tokens[header + 1].is_keyword(.declare);
}

fn lines_the_formatter_needs(context: *const Context, frame: Frame) u32 {
    assert(frame.start < context.tokens.len);

    if (!context.conventions.formatter_splits_one_line_branches) return 1;

    const opened = context.tokens[frame.start];
    const braced = opened.kind == .block_start and opened.length > 0;
    const lines: u32 = if (braced) 3 else 2;

    assert(lines >= 2);
    assert(lines <= 3);

    return lines;
}

fn carries_an_alternative(context: *const Context, frame: Frame) bool {
    const end = frame.end orelse return false;

    assert(end < context.tokens.len);

    const next = control.significant_after(context, end + 1) orelse return false;

    assert(next > end);

    return context.tokens[next].is_keyword(.branch_else);
}

fn assertion_alone(context: *const Context, frame: Frame) ?View {
    assert(frame.header < context.tokens.len);

    var header = frame.header;

    if (context.tokens[header].is_keyword(.branch_else)) {
        if (header + 1 < context.tokens.len) {
            if (context.tokens[header + 1].is_keyword(.branch)) header += 1;
        }
    }

    assert(header < context.tokens.len);

    const opened = context.tokens[header].offset;
    const branch = context.view_at(.branch, opened) orelse return null;
    const statement = branch.as_statement() orelse return null;
    const body = statement.body() orelse return null;

    assert(body.index() >= branch.index());

    var statements = body.children();

    const only = statements.next() orelse {
        if (context.lines_of(body.span()) != 1) return null;
        if (!asserts_alone(context, body)) return null;
        return body;
    };

    if (statements.next() != null) return null;
    if (context.lines_of(only.span()) != 1) return null;
    if (!asserts_alone(context, only)) return null;
    return only;
}

fn asserts_alone(context: *const Context, statement: View) bool {
    assert(statement.parent() != null);
    assert(statement.span().end() <= context.source.len);

    return switch (statement.category()) {
        .branch, .loop, .match => false,
        else => context.is_assertion(statement),
    };
}

test "a three line rust branch is the form rustfmt leaves" {
    const source = "fn f() {\n    if ready {\n        assert!(value);\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a padded rust branch is reported" {
    const source = "fn f() {\n    if ready {\n        // why\n        assert!(value);\n    }\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a rust if let is not an implication" {
    const source = "fn f() {\n    if let Some(x) = held {\n        // why\n        assert!(x);\n" ++
        "}\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a multiline zig assert branch is reported" {
    const source = "fn f() void {\n    if (ready) {\n        assert(value);\n    }\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a braceless two line implication is reported" {
    const source = "function f(a, b) {\n    if (a)\n        assert(b);\n}\n";

    var findings = try testing.analyze(@This(), .javascript, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a nested implication is control flow rather than one assertion" {
    const source = "fn f(held: ?u32, ready: bool) void {\n    if (held) |index| {\n" ++
        "        if (ready) assert(index > 0);\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a loop around an assertion is control flow rather than one assertion" {
    const source = "fn f(ready: bool, items: []const u32, count: u32) void {\n" ++
        "    if (ready) {\n        for (items) |item| assert(item > 0);\n    }\n\n" ++
        "    if (ready) {\n        while (count > 0) assert(count > 1);\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an else if branch anchors at the if" {
    const source = "fn f(a: u32, b: u32) void {\n    if (a > 0) {\n        assert(a > 0);\n" ++
        "} else if (b > 0) {\n        assert(b > 0);\n    }\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 4, 8 }});
}

test "a branch whose condition wraps cannot fold onto one line" {
    const source = "fn f(key_size: u32, value_size: u32, padding: u32) void {\n" ++
        "    if ((key_size == 8 and value_size == 128) or\n" ++
        "        (key_size == 16 and value_size == 16))\n" ++
        "    {\n        assert(padding == 0);\n    }\n}\n";

    const braceless = "function f(a, b, c) {\n    if (a &&\n        b)\n        assert(c);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
    try testing.expect_quiet(@This(), .javascript, braceless);
}

test "an implication too wide to fold keeps its braces" {
    const source = "fn f(header: Header, self: *Replica) void {\n" ++
        "    if (header.op <= self.op_prepare_max()) {\n" ++
        "        assert(header.checkpoint_id == self.checkpoint_id_for_op(header.op).?);\n" ++
        "    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an implication folds only where the folded line fits the column limit" {
    const gpa = std.testing.allocator;
    const fits: [71]u8 = @splat('b');
    const wide: [72]u8 = @splat('b');

    const source = try gpa.print("fn f(a: bool, value: u32) void {{\n    if (a) {{\n" ++
        "        assert(value == {s});\n    }}\n\n    if (a) {{\n        assert(value == " ++
        "{s});\n    }}\n}}\n", .{ &fits, &wide });

    defer gpa.free(source);

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 2, 5 }});
}

test "an odin implication folds with its do word inside the column limit" {
    const source = "package probe\n\nlocked :: proc(a: ^Allocator) {\n" ++
        "\twhen intrinsics.has_target_feature(\"atomics\") {\n" ++
        "\t\tassert(intrinsics.atomic_load(&a.mu) != .Unlocked)\n\t}\n\n" ++
        "\twhen ODIN_DEBUG {\n\t\tassert(a != nil)\n\t}\n}\n";

    try testing.expect_anchors(@This(), .odin, source, &.{.{ 8, 2 }});
}

test "an odin panic is the assertion idiom rather than an implication" {
    const source = "package probe\n\ncheck :: proc(ok: bool, count: int) {\n" ++
        "\tif !ok || count > 0 {\n\t\tpanic(\"parser error\")\n\t}\n\n" ++
        "\tif !ok || count > 0 {\n\t\tassert(count == 0)\n\t}\n}\n";

    try testing.expect_anchors(@This(), .odin, source, &.{.{ 8, 2 }});
}

test "an if expression whose last arm is an else is a case split" {
    const source = "fn f(comptime name: []const u8) type {\n    return if (comptime " ++
        "eql(name, \"Account\"))\n        AccountFlags\n    else if (comptime eql(name, " ++
        "\"QueryFilter\"))\n        QueryFilterFlags\n    else\n        unreachable;\n}\n\n" ++
        "fn g(ready: bool) u32 {\n    return if (ready)\n        remove(key)\n    else\n" ++
        "        unreachable;\n}\n\nfn h(ready: bool) u32 {\n    return if (ready) " ++
        "remove(key) else\n        unreachable;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}
