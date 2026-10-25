const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 10: \"All code must be checked daily with at least one, but " ++
                "preferably more than one, state-of-the-art static source code analyzer and " ++
                "should pass the analyses with zero warnings.\"",
        },
    },
    .code = "TS007",
    .default_on = true,
    .description = "Code is not built and run at runtime, because nothing can be checked before " ++
        "it executes.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-dynamic-exec",
    .severity = .@"error",
    .summary = "Code must not be built and executed at runtime",
    .url = "",
};

pub fn run(context: *const Context, sink: *Sink) void {
    const tokens = context.tokens;

    assert(tokens.len <= std.math.maxInt(u32));

    for (tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.kind != .identifier) continue;
        if (declares_its_name(context, index)) continue;

        const called = called: {
            if (index + 1 >= tokens.len) break :called false;

            break :called tokens[index + 1].is_punctuation(.paren_open);
        };

        const head = if (called)
            dynamic_head(context, index)
        else
            dynamic_comma_head(context, index);

        const anchor = head orelse continue;

        assert(anchor.end() <= context.source.len);

        sink.report(anchor, "the call builds and runs code at runtime");
    }
}

fn declares_its_name(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index == 0) return false;
    return context.tokens[index - 1].is_keyword(.function);
}

fn dynamic_head(context: *const Context, index: u32) ?Span {
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    const token = tokens[index];
    const text = context.text(token);
    const conventions = context.conventions;

    const dotted = dotted: {
        if (index == 0) break :dotted false;

        break :dotted tokens[index - 1].is_punctuation(.dot);
    };

    if (!dotted) {
        if (scan.word_listed(conventions.dynamic_exec_names, text)) return token.span();
        if (!scan.word_listed(conventions.dynamic_exec_string_names, text)) return null;
        if (index + 2 >= tokens.len) return null;
        if (tokens[index + 2].kind != .string) return null;
        return token.span();
    }

    if (index < 2) return null;

    const module = tokens[index - 2];
    if (module.kind != .identifier) return null;

    if (index >= 3) {
        if (tokens[index - 3].is_punctuation(.dot)) return null;
    }

    const path = context.source[module.offset..token.end()];

    assert(path.len >= token.length);

    if (!scan.word_listed(conventions.dynamic_exec_paths, path)) return null;
    return module.span();
}

fn dynamic_comma_head(context: *const Context, index: u32) ?Span {
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    const token = tokens[index];

    if (!scan.word_listed(context.conventions.dynamic_exec_names, context.text(token))) {
        return null;
    }

    if (index == 0) return null;
    if (index + 2 >= tokens.len) return null;
    if (!tokens[index - 1].is_punctuation(.comma)) return null;
    if (!tokens[index + 1].is_punctuation(.paren_close)) return null;
    if (!tokens[index + 2].is_punctuation(.paren_open)) return null;

    assert(token.kind == .identifier);

    return token.span();
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a dotted compile is not dynamic execution" {
    try testing.expect_quiet(@This(), .python, "import re\n\nPATTERN = re.compile(r\"a\")\n");
}

test "a builtins qualified exec is dynamic execution" {
    try expect_count(.python, "import builtins\n\n\ndef f(text):\n    builtins.exec(text)\n", 1);
}

test "a dunder import is dynamic execution" {
    try expect_count(.python, "def f(name):\n    __import__(name)\n", 1);
}

test "a host qualified eval is dynamic execution" {
    const source = "globalThis.eval(text);\nwindow.eval(text);\n(0, eval)(text);\nvm." ++
        "runInThisContext(text);\nconst script = new vm.Script(text);\n";

    try expect_count(.javascript, source, 5);
}

test "a timer given a string is dynamic execution" {
    const source = "setTimeout(\"run()\", 0);\nsetInterval(`run()`, 0);\nsetTimeout(() => " ++
        "run(), 0);\nsetTimeout(run, 0);\n";

    try expect_count(.typescript, source, 2);
}

test "an import module is dynamic execution" {
    const source = "import importlib\n\nimportlib.import_module(name)\n" ++
        "importlib.__import__(name)\njson.loads(data)\n";

    try expect_count(.python, source, 2);
}

test "a pickle load restores data rather than running code" {
    const source = "import pickle\n\n\ndef test_dumps(zs):\n    assert_equal(zs, " ++
        "pickle.loads(zs.dumps()))\n    with open(path, \"rb\") as handle:\n" ++
        "        return pickle.load(handle)\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "an eval of a repr or of a v8 intrinsic is still dynamic execution" {
    const python = "def test_view(xx):\n    assert_array_equal(eval(repr(xx), " ++
        "dict(array=np.array)), xx)\n";

    const typescript = "const hasFast: (o: object) => boolean = eval(\"(o) => " ++
        "%HasFastProperties(o)\");\n";

    try expect_count(.python, python, 1);
    try expect_count(.typescript, typescript, 1);
}

test "a dynamic call inside a test is still reported" {
    try expect_count(.python, "def test_run():\n    exec(text)\n", 1);
}

test "a method named like a dynamic call is a definition" {
    const source = "class Literal:\n    def eval(self, context):\n        return self.value\n\n" ++
        "    def compile(self, side):\n        return exec(side)\n";

    try expect_count(.python, source, 1);
}

test "a dynamic call is reported" {
    try expect_count(.python, "def f(text):\n    return eval(text)\n", 1);
}
