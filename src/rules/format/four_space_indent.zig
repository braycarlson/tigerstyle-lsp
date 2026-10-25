const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const JavascriptKind = scylla.javascript.Kind;
const MacroBodies = @import("../macro_bodies.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use 4 spaces of indentation, rather than 2 spaces, as that is more " ++
                "obvious to the eye at a distance.\"",
        },
    },
    .code = "TS029",
    .default_on = true,
    .description = "Indentation is four spaces per level, with no tabs, so a file reads the " ++
        "same everywhere.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "four-space-indent",
    .severity = .information,
    .summary = "Indent by four spaces, not two and not tabs",
    .url = "",
};

const Openers = struct {
    count: u32,
    depth_unheld: u32,
    positions: [opener_count_max]u32,

    const empty: Openers = .{ .count = 0, .depth_unheld = 0, .positions = undefined };

    fn step(openers: *Openers, context: *const Context, index: u32) void {
        assert(index < context.tokens.len);
        assert(openers.count <= opener_count_max);

        const token = context.tokens[index];
        const classified = scylla.Brackets.classify(context.source, token) orelse return;

        if (classified.opens) {
            if (openers.count == opener_count_max) {
                openers.depth_unheld += 1;
            } else {
                openers.positions[openers.count] = index;
                openers.count += 1;
            }

            return;
        }

        if (openers.depth_unheld > 0) {
            openers.depth_unheld -= 1;
        } else if (openers.count > 0) {
            openers.count -= 1;
        } else {}
    }

    fn innermost(openers: *const Openers) ?u32 {
        assert(openers.count <= opener_count_max);

        if (openers.depth_unheld > 0) return null;
        if (openers.count == 0) return null;
        return openers.positions[openers.count - 1];
    }
};

const closure_bar = "|";
const closure_parameter_tokens_max: u32 = 256;
const indent_columns: u32 = 4;
const opener_count_max: u32 = scylla.limits.bracket_depth_max;

pub fn run(context: *const Context, sink: *Sink) void {
    const token_count: u32 = @intCast(context.tokens.len);

    var bodies: MacroBodies = .empty;
    var cursor: u32 = 0;
    var openers: Openers = .empty;
    var parameters_end: u32 = 0;

    for (0..context.line_count()) |line_index| {
        const line: u32 = @intCast(line_index);
        const span = context.line_span(line);

        while (cursor < token_count) : (cursor += 1) {
            if (context.tokens[cursor].end() > span.offset) break;

            openers.step(context, cursor);

            if (closure_parameters_end(context, cursor)) |end| {
                parameters_end = @max(parameters_end, end);
            }
        }

        assert(cursor <= token_count);

        if (raw_text_line(context, cursor, span)) continue;
        if (bodies.inside(context, cursor)) continue;
        if (continues_closure_parameters(context, cursor, parameters_end)) continue;

        const text = context.line_text(line);
        const indent = std.mem.findNone(u8, text, " \t") orelse continue;
        if (aligns_under_an_opener(context, &openers, text[0..indent])) continue;

        indent_check(context, sink, span, text[0..indent]);
    }
}

fn aligns_under_an_opener(
    context: *const Context,
    openers: *const Openers,
    leading: []const u8,
) bool {
    if (context.conventions.indent_with_tabs) return false;
    if (std.mem.findScalar(u8, leading, '\t') != null) return false;

    const open = openers.innermost() orelse return false;
    const element = open + 1;

    assert(open < context.tokens.len);

    if (element >= context.tokens.len) return false;

    const opener = context.tokens[open];
    const first = context.tokens[element];
    const between = context.source[opener.end()..first.offset];

    assert(opener.end() <= first.offset);

    if (first.kind == .comment) return false;
    if (first.kind == .newline) return false;
    if (std.mem.findScalar(u8, between, '\n') != null) return false;

    const line_start = context.line_span(context.line_of(first.offset)).offset;
    const before = context.source[line_start..first.offset];

    assert(line_start <= opener.offset);

    if (std.mem.findScalar(u8, before, '\t') != null) return false;
    return before.len == leading.len;
}

fn closure_parameters_end(context: *const Context, index: u32) ?u32 {
    const tokens = context.tokens;

    assert(index < tokens.len);

    if (!tokens[index].is_keyword(.lambda)) return null;
    if (!std.mem.eql(u8, context.text(tokens[index]), closure_bar)) return null;

    var cursor = index + 1;

    for (0..closure_parameter_tokens_max) |_| {
        if (cursor >= tokens.len) return null;

        const token = tokens[cursor];

        if (token.opens_a_group_or_block()) {
            const partner = context.pairs.partner_of(cursor) orelse return null;

            assert(partner > cursor);

            cursor = partner + 1;

            continue;
        }

        if (std.mem.eql(u8, context.text(token), closure_bar)) return token.offset;

        cursor += 1;
    }

    return null;
}

fn continues_closure_parameters(context: *const Context, cursor: u32, end: u32) bool {
    assert(cursor <= context.tokens.len);
    assert(end <= context.source.len);

    if (cursor == context.tokens.len) return false;
    return context.tokens[cursor].offset <= end;
}

fn raw_text_line(context: *const Context, cursor: u32, span: Span) bool {
    assert(cursor <= context.tokens.len);

    for (context.tokens[cursor..]) |token| {
        if (token.offset > span.end()) return false;
        if (jsx_text(context, token)) continue;

        switch (token.kind) {
            .comment, .string => return true,
            else => {},
        }
    }

    return false;
}

fn jsx_text(context: *const Context, token: Token) bool {
    assert(token.end() <= context.source.len);

    switch (context.front.language) {
        .javascript, .typescript => {},
        else => return false,
    }

    const kind = token.exact_kind(JavascriptKind) orelse return false;
    return kind == .jsx_chars or kind == .jsx_entity;
}

fn indent_check(context: *const Context, sink: *Sink, span: Span, leading: []const u8) void {
    assert(leading.len <= span.length);

    if (context.conventions.indent_with_tabs) {
        if (std.mem.findScalar(u8, leading, ' ') != null) {
            sink.report(
                .{ .offset = span.offset, .length = @intCast(leading.len) },
                "the line indents with spaces where the language's formatter indents with tabs",
            );
        }

        return;
    }

    if (std.mem.findScalar(u8, leading, '\t')) |at| {
        const tab: Span = .{ .offset = span.offset + @as(u32, @intCast(at)), .length = 1 };

        sink.report(tab, "the line indents with a tab");

        return;
    }

    const columns: u32 = @intCast(leading.len);
    if (columns % indent_columns == 0) return;

    sink.report_formatted(
        .{ .offset = span.offset, .length = columns },
        "the line indents {d} columns, which is not a multiple of {d}",
        .{ columns, indent_columns },
    );
}

test "a whitespace only line is quiet under crlf" {
    const source = "fn f() {\r\n    let value = 1;\r\n \r\n    let other = 2;\r\n}\r\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a tab indent is reported" {
    var findings = try testing.analyze(@This(), .rust, "fn f() {\n\tlet value = 1;\n}\n");
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "every offending line is reported after a tab" {
    const source = "fn f() {\n\tlet value = 1;\n  let other = 2;\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 2), findings.count());
}

test "a tab language reports spaces and keeps tabs" {
    const spaced = "package main\n\nfunc f() {\n    return\n}\n";

    var findings = try testing.analyze(@This(), .go, spaced);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "spaces") != null);

    const tabbed = "package main\n\nfunc f() {\n\tif true {\n\t\treturn\n\t}\n}\n";

    try testing.expect_quiet(@This(), .go, tabbed);
}

test "a three space indent is reported" {
    var findings = try testing.analyze(@This(), .rust, "fn f() {\n   let value = 1;\n}\n");
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "3 columns") != null);
}

test "a four space indent is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn f() {\n    let value = 1;\n}\n");
}

test "an indent inside text is not an indent" {
    try testing.expect_quiet(@This(), .rust, "fn helper() {\n    let a = \"\n  x\n\";\n}\n");

    const comment = "fn helper() {\n    /*\n  x\n    */\n    let a = 1;\n}\n";

    try testing.expect_quiet(@This(), .rust, comment);
}

test "a comment further down does not excuse this line" {
    const source = "fn helper() {\n  let a = 1;\n    // Note here.\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a line aligned under an open bracket's first element is a continuation" {
    const aligned = "def attrib(default: None = ...,\n           validator: None = ...,\n" ++
        "           repr: bool = ...) -> Any: ...\n";

    const rust = "extern \"C\" {\n    pub fn getsockopt(sockfd: c_int,\n" ++
        "                      level: c_int) -> c_int;\n}\n";

    const short = "def attrib(default: None = ...,\n" ++
        "          validator: None = ...) -> Any: ...\n";

    const hanging = "def run():\n    value = call(\n      first,\n    )\n";

    try testing.expect_quiet(@This(), .python, aligned);
    try testing.expect_quiet(@This(), .rust, rust);
    try testing.expect_anchors(@This(), .python, short, &.{.{ 2, 1 }});
    try testing.expect_anchors(@This(), .python, hanging, &.{.{ 3, 1 }});
}

test "a closure parameter pattern spanning lines is a continuation" {
    const aligned = "fn release() {\n    CURRENT.with(\n        |LocalData {\n" ++
        "             ctx,\n             wake,\n         }| {\n            ctx.set(1);\n" ++
        "        },\n    );\n}\n";

    const body = "fn release() {\n    CURRENT.with(|value| {\n         value.set(1);\n" ++
        "    });\n}\n";

    try testing.expect_quiet(@This(), .rust, aligned);
    try testing.expect_anchors(@This(), .rust, body, &.{.{ 3, 1 }});
}

test "a tab is reported where it stands" {
    const source = "fn helper() {\n    \tlet a = 1;\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());

    const at = findings.span(0);

    try std.testing.expectEqualStrings("\t", source[at.offset..at.end()]);
}

test "a line of jsx text is checked" {
    const source = "function view() {\n    return (\n        <p>\n          Some text\n" ++
        "        </p>\n    );\n}\n";

    try testing.expect_anchors(@This(), .javascript, source, &.{.{ 4, 1 }});
}
