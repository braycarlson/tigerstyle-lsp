const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const shape = @import("../shape.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Category = scylla.View.Category;
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use only very simple, explicit control flow for clarity.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 1: \"Restrict all code to very simple control flow " ++
                "constructs.\"",
        },
    },
    .code = "TS008",
    .default_on = true,
    .description = "A block nests at most four levels inside its function, so control flow " ++
        "stays readable without a map.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "nesting-depth",
    .severity = .warning,
    .summary = "Control flow must not nest deeper than `nesting_depth_max`",
    .url = "",
};

const control_parents = [_]Category{
    .block,
    .branch,
    .except,
    .function,
    .lambda,
    .loop,
    .match,
    .@"try",
};

const handler_parents = [_]Category{ .branch, .except, .loop, .match, .@"try" };
const nesting_categories = [_]Category{ .block, .branch, .except, .loop, .match, .@"try" };
const position_none: u32 = std.math.maxInt(u32);

pub fn run(context: *const Context, sink: *Sink) void {
    const allowed = context.settings.thresholds.nesting_depth_max;

    var cursors: [nesting_categories.len]u32 = @splat(0);

    for (0..context.front.node_count()) |_| {
        const index = nesting_next(context, &cursors) orelse break;
        const view = context.view(index);

        assert(listed(&nesting_categories, view.category()));

        if (!nests(context, view)) continue;
        if (continues_a_chain(context, view)) continue;

        const depth = nesting_of(context, view) orelse continue;
        if (depth <= allowed) continue;

        assert(depth > 1);

        sink.report_formatted(
            marker_modified(context, view),
            "the branch nests {d} levels deep, over the {d} level limit",
            .{ depth, allowed },
        );
    }
}

fn nesting_next(context: *const Context, cursors: *[nesting_categories.len]u32) ?u32 {
    var found: u32 = position_none;
    var chosen: usize = 0;

    for (nesting_categories, cursors, 0..) |category, cursor, slot| {
        const positions = context.front.nodes_of(category);
        if (cursor == positions.len) continue;
        if (positions[cursor] > found) continue;

        found = positions[cursor];
        chosen = slot;
    }

    if (found == position_none) return null;

    assert(found < context.front.node_count());

    cursors[chosen] += 1;

    return found;
}

fn listed(categories: []const Category, category: Category) bool {
    assert(categories.len > 0);

    const found = std.mem.findScalar(Category, categories, category);

    if (found) |index| assert(categories[index] == category);

    return found != null;
}

fn marker_modified(context: *const Context, view: View) Span {
    const header = shape.header_of(context, view) orelse return view.span();

    const first = stream.modifier_start(
        context.pairs,
        context.tokens,
        context.source,
        header,
        stream.modifier_count_max,
    );

    assert(first <= header);
    assert(context.tokens[first].end() <= context.source.len);

    return context.tokens[first].span();
}

fn nests(context: *const Context, view: View) bool {
    const category = view.category();

    assert(view.span().end() <= context.source.len);

    if (category == .branch) {
        if (view.is_an_arm()) return false;
        return stands_as_control(context, view);
    }

    const controls = category == .loop or category == .match;
    if (controls) return stands_as_control(context, view);
    if (category == .@"try") return Frame.of(context, view) != null;

    const handles = category == .block or category == .except;
    if (!handles) return false;

    const header = shape.header_of(context, view) orelse return false;

    assert(header < context.tokens.len);

    if (holds_its_header_in_a_child(context, view, header)) return false;
    if (shares_its_parents_header(context, view, header)) return false;

    return scan.word_listed(
        context.conventions.nesting_words,
        context.text(context.tokens[header]),
    );
}

fn shares_its_parents_header(context: *const Context, view: View, header: u32) bool {
    assert(header < context.tokens.len);

    const parent = view.parent() orelse return false;
    const held = shape.header_of(context, parent) orelse return false;

    assert(parent.index() < view.index());

    if (held != header) return false;
    return !holds_its_header_in_a_child(context, parent, held);
}

fn holds_its_header_in_a_child(context: *const Context, view: View, header: u32) bool {
    assert(header < context.tokens.len);

    var children = view.children();

    for (0..children.remaining) |_| {
        const child = children.next() orelse return false;

        assert(child.index() > view.index());

        if (context.lexer_index_from(child.span().offset) == header) return true;
    }

    return false;
}

fn stands_as_control(context: *const Context, view: View) bool {
    if (Frame.of(context, view) != null) return true;

    const header = shape.header_of(context, view) orelse return false;

    assert(header < context.tokens.len);

    if (context.tokens[header].kind != .keyword) return false;

    const parent = view.parent() orelse return false;

    assert(parent.index() < view.index());

    return listed(&control_parents, parent.category());
}

fn continues_a_chain(context: *const Context, view: View) bool {
    if (view.category() != .branch) return false;

    const header = shape.header_of(context, view) orelse return false;

    assert(header < context.tokens.len);

    if (context.tokens[header].is_keyword(.branch_else)) return true;

    const previous = stream.significant_previous(context.tokens, header) orelse return false;

    assert(previous < header);

    return context.tokens[previous].is_keyword(.branch_else);
}

fn nesting_of(context: *const Context, view: View) ?u32 {
    var depth: u32 = 1;
    var chained = false;
    var handled = view.category() == .block or view.category() == .except;
    var ancestors = view.ancestors();
    const depth_max = ancestors.remaining + 1;

    assert(listed(&nesting_categories, view.category()));

    for (0..depth_max) |_| {
        const held = ancestors.next() orelse return null;
        const category = held.category();

        assert(held.index() < view.index());
        assert(depth <= depth_max);

        if (category == .function) return depth;
        if (opens_a_scope(context, held)) return depth;
        if (held.is_an_arm()) continue;

        const counts = nests(context, held);

        switch (category) {
            .branch => {
                if (!chained) {
                    if (counts) depth += 1;
                }

                chained = continues_a_chain(context, held);
            },
            .@"try" => {
                if (!handled) {
                    if (counts) depth += 1;
                }
            },
            else => {
                if (counts) depth += 1;
            },
        }

        const handles = category == .block or category == .except;

        handled = counts and handles;
    }

    return null;
}

fn opens_a_scope(context: *const Context, view: View) bool {
    if (view.category() != .block) return false;

    const parent = view.parent();

    if (parent) |above| assert(above.index() < view.index());

    const held = if (parent) |above| listed(&handler_parents, above.category()) else false;

    if (held) {
        if (follows_a_condition(context, view)) return false;
    }

    const frame = Frame.of(context, view) orelse return false;

    assert(frame.header < context.tokens.len);

    return support.opens_with_a_word(context, frame, context.conventions.scope_words);
}

fn follows_a_condition(context: *const Context, view: View) bool {
    const header = shape.header_of(context, view) orelse return false;
    const previous = stream.significant_previous(context.tokens, header) orelse return false;

    assert(previous < header);
    assert(header < context.tokens.len);

    const token = context.tokens[previous];
    if (token.is_punctuation(.paren_close)) return true;
    return token.is_keyword(.branch_else);
}

test "a view that opens past the last token reports nothing" {
    try testing.expect_quiet(@This(), .javascript, "##?");
}

test "a switch operand does not add a level per branch" {
    const source = "fn f() void {\n    switch (pick(Action, .{\n" ++
        ".a = if (ready) 2 else 0,\n        .b = if (ready) 4 else 0,\n" ++
        "})) {\n        else => {},\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a format literal is not a branch body" {
    const source = "fn f() void {\n    if (ready) try writer.print(\"{s}\", .{\n" ++
        "name,\n    });\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "deep nesting is reported at the first level over" {
    const source = "fn deep() {\n    if a {\n        if b {\n            if c {\n" ++
        "if d {\n                    if e {\n                    }\n" ++
        "}\n            }\n        }\n    }\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "5 levels") != null);
}

test "a python with block adds a level" {
    const gpa = std.testing.allocator;

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    try source.appendSlice(gpa, "def deep(a):\n");

    for (1..6) |depth| {
        try source.appendNTimes(gpa, ' ', depth * 4);
        try source.appendSlice(gpa, "with a:\n");
    }

    try source.appendSlice(gpa, "                        pass\n");

    var findings = try testing.analyze(@This(), .python, source.items);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a python with beside another with is a sibling rather than a level" {
    const siblings = "def run(self):\n    for combinator in combinators:\n" ++
        "        for operator, function in operators:\n" ++
        "            with self.subTest(combinator=combinator):\n" ++
        "                with self.assertRaises(TypeError):\n                    function(1)\n" ++
        "                with self.assertRaises(TypeError):\n                    function(2)\n" ++
        "                if ready:\n                    function(3)\n";

    const deeper = "def run(self):\n    for combinator in combinators:\n" ++
        "        for operator, function in operators:\n" ++
        "            with self.subTest(combinator=combinator):\n" ++
        "                with self.assertRaises(TypeError):\n                    function(1)\n" ++
        "                with self.assertRaises(TypeError):\n" ++
        "                    with deeper:\n                        function(2)\n";

    try testing.expect_quiet(@This(), .python, siblings);

    var findings = try testing.analyze(@This(), .python, deeper);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a zig labelled block does not reset the count" {
    const source = "fn deep() void {\n    if (a) {\n        if (b) {\n            blk: {\n" ++
        "if (c) {\n                    if (d) {\n                        if (e) " ++
        "{}\n                    }\n                }\n            }\n        }\n" ++
        "}\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}
