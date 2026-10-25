const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Compound conditions that evaluate multiple booleans make it difficult " ++
                "for the reader to verify that all cases are handled. Split compound conditions " ++
                "into simple conditions using nested `if/else` branches. Split complex " ++
                "`else if` chains into `else { if { } }` trees. This makes the branches and " ++
                "cases clear.\"",
        },
    },
    .code = "TS039",
    .default_on = true,
    .description = "A chain of else-if branches is split into a tree, so every case stays visible.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "else-if-chain",
    .severity = .warning,
    .summary = "Split an `else if` chain into a tree",
    .url = "",
};

const chain_branch_max: u32 = 1 << 10;
const else_lookbehind_max: u32 = 64;
const else_word = "else";
const if_word = "if";

pub fn run(context: *const Context, sink: *Sink) void {
    var branches = context.views(.branch);
    const allowed = context.settings.thresholds.else_if_chain_max;

    for (0..branches.remaining) |_| {
        const branch = branches.next() orelse break;

        assert(branch.category() == .branch);

        if (!opens_a_branch(context, branch)) continue;
        if (continues_a_chain(context, branch)) continue;

        const count = chain_of(context, branch);
        if (count <= allowed) continue;

        assert(count > 1);

        sink.report_formatted(
            branch.span(),
            "the chain runs {d} branches, over the {d} allowed; split it into a tree",
            .{ count, allowed },
        );
    }
}

fn opens_a_branch(context: *const Context, branch: View) bool {
    assert(branch.category() == .branch);

    var positions = branch.positions();
    const position = positions.next() orelse return false;

    assert(position < context.front.tokens().len);

    return context.front_token(position).is_keyword(.branch);
}

fn continues_a_chain(context: *const Context, branch: View) bool {
    assert(branch.category() == .branch);

    const parent = branch.parent() orelse return false;
    if (parent.category() == .branch) return true;
    if (parent.category() != .block) return false;
    if (braced(context, parent)) return false;

    const grandparent = parent.parent() orelse return false;

    assert(grandparent.index() < parent.index());

    return grandparent.category() == .branch;
}

fn braced(context: *const Context, block: View) bool {
    assert(block.category() == .block);
    assert(block.index() < context.front.node_count());

    var positions = block.positions();

    for (0..positions.remaining) |_| {
        const position = positions.next() orelse return false;
        if (context.front_token(position).kind == .block_start) return true;
    }

    return false;
}

fn chain_of(context: *const Context, branch: View) u32 {
    assert(branch.category() == .branch);

    var branches: u32 = 1;
    var current = branch;

    for (0..chain_branch_max) |_| {
        const statement = current.as_statement() orelse break;

        var clauses = statement.clauses();
        var next: ?View = null;

        for (0..clauses.count()) |_| {
            const clause = clauses.next() orelse break;

            if (clause.category() == .branch) {
                if (!links_a_branch(context, clause)) continue;

                branches += 1;
                next = clause;

                continue;
            }

            if (clause.category() != .block) continue;

            if (context.conventions.arms_open_with_else) {
                if (!follows_an_else(context, clause)) continue;
            }

            const inner = else_if_inside(context, clause) orelse continue;

            branches += 1;
            next = inner;
        }

        current = next orelse break;
    }

    assert(branches >= 1);

    return branches;
}

fn links_a_branch(context: *const Context, clause: View) bool {
    assert(clause.category() == .branch);

    if (!context.conventions.arms_open_with_else) return true;

    const first = context.lexer_index_from(clause.span().offset);
    if (first >= context.tokens.len) return false;
    if (!std.mem.eql(u8, context.text(context.tokens[first]), if_word)) return true;
    return follows_an_else(context, clause);
}

fn follows_an_else(context: *const Context, clause: View) bool {
    const tokens = context.tokens;
    const first = context.lexer_index_from(clause.span().offset);

    assert(first <= tokens.len);

    if (first < tokens.len) {
        if (std.mem.eql(u8, context.text(tokens[first]), else_word)) return true;
    }

    var index = first;

    for (0..else_lookbehind_max) |_| {
        if (index == 0) return false;

        index -= 1;

        switch (tokens[index].kind) {
            .comment, .newline => continue,
            else => break,
        }
    }

    const before = context.text(tokens[index]);
    if (std.mem.eql(u8, before, else_word)) return true;
    if (!tokens[index].is_punctuation(.colon)) return false;
    if (index == 0) return false;
    return std.mem.eql(u8, context.text(tokens[index - 1]), else_word);
}

fn else_if_inside(context: *const Context, clause: View) ?View {
    assert(clause.category() == .block);

    var children = clause.children();
    const only = children.next() orelse return null;

    if (children.next() != null) return null;
    if (only.category() != .branch) return null;
    if (braced(context, clause)) return null;

    assert(only.index() > clause.index());

    return only;
}

test "an if that is the body of an arm is not an arm" {
    const source = "fn f(a: u32, b: u32, c: u32) u32 {\n    return if (a == 1)\n        1\n" ++
        "    else if (a == 2)\n        if (b == 1)\n            2\n        else\n            3\n" ++
        "    else if (c == 1)\n        4\n    else\n        5;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a fourth conditioned arm of an expression chain still reports" {
    const source = "fn f(a: u32) u32 {\n    return if (a == 1)\n        1\n" ++
        "    else if (a == 2)\n        2\n    else if (a == 3)\n        3\n" ++
        "    else if (a == 4)\n        4\n    else\n        5;\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a bare else does not raise the chain allowance" {
    const source = "fn f(value: u32) u32 {\n    if (value == 1) {\n        return 1;\n" ++
        "} else if (value == 2) {\n        return 2;\n" ++
        "} else if (value == 3) {\n        return 3;\n" ++
        "} else if (value == 4) {\n        return 4;\n" ++
        "} else {\n        return 0;\n    }\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "4 branches") != null);
}

test "three conditioned arms and an else fit the chain" {
    const source = "fn f(value: u32) u32 {\n    if (value == 1) {\n        return 1;\n" ++
        "} else if (value == 2) {\n        return 2;\n" ++
        "} else if (value == 3) {\n        return 3;\n" ++
        "} else {\n        return 0;\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a fifth conditioned link overruns the chain" {
    const source = "fn f(value: u32) u32 {\n    if (value == 1) {\n        return 1;\n" ++
        "} else if (value == 2) {\n        return 2;\n" ++
        "} else if (value == 3) {\n        return 3;\n" ++
        "} else if (value == 4) {\n        return 4;\n" ++
        "} else if (value == 5) {\n        return 5;\n" ++
        "} else {\n        return 0;\n    }\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "5 branches") != null);
}
