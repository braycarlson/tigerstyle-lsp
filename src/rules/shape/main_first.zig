const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const support = @import("../support.zig");
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
                "top. The `main` function goes first.\"",
        },
    },
    .code = "TS048",
    .default_on = false,
    .description = "The entry point comes first in the file, so a reader meets the top of the " ++
        "call graph before its parts.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "main-first",
    .severity = .information,
    .summary = "Put `main` first",
    .url = "",
};

const Entry = struct {
    named: u32,
    offset: u32,
};

const entry_name = "main";

pub fn run(context: *const Context, sink: *Sink) void {
    var nodes = support.functions_and_bound_lambdas(context);
    var entry: ?Entry = null;
    var earliest_other: ?u32 = null;

    for (0..context.front.node_count()) |_| {
        const node = nodes.next() orelse break;
        if (is_nested(node)) continue;

        const named = support.bound_name_of(node) orelse continue;
        const offset = context.front_token(named).offset;

        assert(offset < context.source.len);

        if (!std.mem.eql(u8, context.front_text(named), entry_name)) {
            earliest_other = @min(earliest_other orelse offset, offset);

            continue;
        }

        if (entry) |held| {
            if (offset >= held.offset) continue;
        }

        entry = .{ .named = named, .offset = offset };
    }

    const found = entry orelse return;
    const other = earliest_other orelse return;
    if (other > found.offset) return;

    assert(other < found.offset);

    sink.report(
        context.front_token(found.named).span(),
        "the entry point comes after another function; put main first",
    );
}

fn is_nested(node: View) bool {
    var ancestors = node.ancestors();

    assert(node.index() > 0);

    for (0..ancestors.remaining + 1) |_| {
        const parent = ancestors.next() orelse return false;

        assert(parent.index() < node.index());

        switch (parent.category()) {
            .function, .lambda, .@"struct" => return true,
            .block => if (opens_a_scope(parent)) return true,
            else => {},
        }
    }

    return false;
}

fn opens_a_scope(block: View) bool {
    const owner = block.parent() orelse return false;

    assert(block.category() == .block);
    assert(owner.index() < block.index());

    return switch (owner.category()) {
        .branch, .except, .loop, .match, .@"try" => false,
        else => true,
    };
}

test "main after another function is reported" {
    const source = "fn helper() {\n}\n\nfn main() {\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "main first is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn main() {\n}\n\nfn helper() {\n}\n");
}

test "main bound as an arrow function is the entry point" {
    const source = "function helper() {\n}\n\nconst main = () => {\n    helper();\n};\n";

    var findings = try testing.analyze(@This(), .javascript, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "main bound as an arrow function first is quiet" {
    const source = "const main = () => {\n    helper();\n};\n\nfunction helper() {\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "a function inside a module is not top level" {
    const sources = [_]struct { scylla.Language, []const u8 }{
        .{ .rust, "mod w {\n    pub fn helper() {\n    }\n}\n\nfn main() {\n}\n" },
        .{ .rust, "mod a {\n    mod b {\n        fn helper() {}\n    }\n}\n\nfn main() {}\n" },
        .{ .typescript, "namespace N {\n    function helper() {}\n}\n\nfunction main() {}\n" },
    };

    for (sources) |held| {
        try testing.expect_quiet(@This(), held[0], held[1]);
    }
}

test "a function a top level branch declares is still top level" {
    const sources = [_]struct { scylla.Language, []const u8 }{
        .{ .python, "if X:\n    def helper():\n        pass\n\ndef main():\n    pass\n" },
        .{ .odin, "package p\n\nwhen ODIN_OS == .Windows {\n    helper :: proc() {}\n}\n\n" ++
            "main :: proc() {}\n" },
    };

    for (sources) |held| {
        var findings = try testing.analyze(@This(), held[0], held[1]);
        defer findings.deinit();

        try std.testing.expectEqual(@as(u32, 1), findings.count());
    }
}

test "a top level function below a module still precedes main" {
    const source = "mod w {\n    pub fn helper() {\n    }\n}\n\nfn other() {\n}\n\n" ++
        "fn main() {\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}
