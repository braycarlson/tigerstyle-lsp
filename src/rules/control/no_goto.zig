const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use only very simple, explicit control flow for clarity.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 1: \"Restrict all code to very simple control flow " ++
                "constructs — do not use goto statements, setjmp or longjmp constructs, and " ++
                "direct or indirect recursion.\"",
        },
    },
    .code = "TS021",
    .default_on = true,
    .description = "Control flow is structured, so a reader follows it without a map of the " ++
        "labels.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-goto",
    .severity = .@"error",
    .summary = "Unstructured jumps cannot be analysed; use structured control flow",
    .url = "",
};

pub fn run(context: *const Context, sink: *Sink) void {
    assert(context.tokens.len <= std.math.maxInt(u32));

    for (context.tokens) |token| {
        if (!token.is_keyword(.goto)) continue;

        assert(token.length > 0);

        sink.report(
            token.span(),
            "the jump leaves the structure; use a loop, a branch, or a return",
        );
    }
}

test "a goto is reported at its keyword" {
    const source = "package main\n\nfunc f() {\nagain:\n\tgoto again\n}\n";

    try testing.expect_spans(@This(), .go, source, &.{.{ 33, 37 }});
}
