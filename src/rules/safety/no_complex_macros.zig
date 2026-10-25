const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const safety = @import("../safety.zig");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const Rule = scylla.rule.Rule;
const Settings = @import("../../settings.zig");
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const TestScope = @import("../test_scope.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 8: \"The use of the preprocessor must be limited to the " ++
                "inclusion of header files and simple macro definitions. Token pasting, " ++
                "variable argument lists (ellipses), and recursive macro calls are not allowed. " ++
                "All macros must expand into complete syntactic units.\"",
        },
    },
    .code = "TS018",
    .default_on = false,
    .description = "A macro stays small, because a reader cannot step through an expansion.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-complex-macros",
    .severity = .warning,
    .summary = "A macro must not hide control flow from static analysis",
    .url = "",
};

const Macro = struct {
    body: Span,
    declares_tests: bool,
    name: Span,
};

const Table = struct {
    count: u32,
    macros: [macro_count_max]Macro,

    fn held(table: *const Table) []const Macro {
        assert(table.count <= macro_count_max);

        const macros = table.macros[0..table.count];

        assert(macros.len == table.count);

        return macros;
    }
};

const crate_roots = [_][]const u8{ "$crate", "crate", "self", "super" };
const macro_count_max: u32 = 64;
const macro_word = "macro_rules";
const pasting_macros = [_][]const u8{ "concat_idents", "paste" };
const path_segment_max: u32 = 8;
const path_separator = "::";

const procedural_attributes = [_][]const u8{
    "proc_macro",
    "proc_macro_attribute",
    "proc_macro_derive",
};

const test_attributes = [_][]const u8{ "#[bench]", "#[test]" };

pub fn run(context: *const Context, sink: *Sink) void {
    var table: Table = .{ .count = 0, .macros = undefined };

    macros_collect(context, &table);

    assert(table.count <= macro_count_max);

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.kind != .identifier) continue;

        const name = context.text(token);

        if (names_a_procedural_macro(context, index, name)) {
            sink.report(token.span(), "the procedural macro is an unrestricted expansion");

            continue;
        }

        if (index + 1 >= context.tokens.len) continue;
        if (!context.tokens[index + 1].is_punctuation(.bang)) continue;

        if (scan.word_in(&pasting_macros, name)) {
            sink.report(token.span(), "the macro pastes tokens into new names");

            continue;
        }

        if (!std.mem.eql(u8, name, macro_word)) continue;
        if (!complex(context, table.held(), index)) continue;
        if (tabulates_tests(context, table.held(), index)) continue;

        assert(index + 1 < context.tokens.len);

        sink.report(
            token.span(),
            "the macro is long or repeats; keep an expansion small enough to read",
        );
    }
}

fn complex(context: *const Context, table: []const Macro, index: u32) bool {
    assert(index < context.tokens.len);
    assert(table.len <= macro_count_max);

    const frame = enclosing_block(context, index) orelse return false;
    const span = frame.span(context.tokens);
    const lines = context.lines_of(span);
    const body = context.span_text(span);

    assert(span.end() <= context.source.len);

    if (lines > context.settings.thresholds.function_lines_max) return true;
    if (scan.find(body, "$(") != null) return true;
    if (invokes_itself(context, index, body)) return true;
    return reaches_itself(context, table, index);
}

fn tabulates_tests(context: *const Context, table: []const Macro, index: u32) bool {
    assert(index < context.tokens.len);
    assert(table.len <= macro_count_max);

    const origin = held_at(context, table, index) orelse return false;

    assert(origin < table.len);

    if (!expands_to_tests(context, table, origin)) return false;
    return TestScope.holds(context, context.tokens[index].offset);
}

fn expands_to_tests(context: *const Context, table: []const Macro, origin: usize) bool {
    assert(origin < table.len);
    assert(table.len <= macro_count_max);

    if (table[origin].declares_tests) return true;

    const declared = for (table) |held| {
        if (held.declares_tests) break true;
    } else false;

    if (!declared) return false;

    const reached = reached_from(context, table, origin);

    for (table, reached[0..table.len]) |held, touched| {
        if (!touched) continue;
        if (held.declares_tests) return true;
    }

    return false;
}

fn holds_a_test(body: []const u8) bool {
    assert(body.len > 0);

    for (test_attributes) |attribute| {
        assert(attribute.len > 0);

        if (scan.find(body, attribute) != null) return true;
    }

    return false;
}

fn names_a_procedural_macro(context: *const Context, index: u32, name: []const u8) bool {
    assert(index < context.tokens.len);

    if (!scan.word_in(&procedural_attributes, name)) return false;
    if (index == 0) return false;

    const bracket = context.tokens[index - 1];
    if (!bracket.is_punctuation(.bracket_open)) return false;

    assert(bracket.offset <= context.tokens[index].offset);

    return safety.attribute_marked(context, bracket.offset);
}

fn macros_collect(context: *const Context, table: *Table) void {
    assert(table.count == 0);

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (table.count == macro_count_max) break;
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), macro_word)) continue;
        if (index + 2 >= context.tokens.len) continue;

        const named = context.tokens[index + 2];
        if (named.kind != .identifier) continue;

        const frame = enclosing_block(context, index) orelse continue;
        const body = frame.span(context.tokens);

        table.macros[table.count] = .{
            .body = body,
            .declares_tests = holds_a_test(context.span_text(body)),
            .name = named.span(),
        };

        table.count += 1;
    }

    assert(table.count <= macro_count_max);
}

fn reaches_itself(context: *const Context, table: []const Macro, index: u32) bool {
    assert(index < context.tokens.len);
    assert(table.len <= macro_count_max);

    const origin = held_at(context, table, index) orelse return false;

    assert(origin < table.len);

    return reached_from(context, table, origin)[origin];
}

fn held_at(context: *const Context, table: []const Macro, index: u32) ?usize {
    assert(index < context.tokens.len);
    assert(table.len <= macro_count_max);

    if (index + 2 >= context.tokens.len) return null;

    const name = context.text(context.tokens[index + 2]);

    for (table, 0..) |held, position| {
        if (std.mem.eql(u8, context.span_text(held.name), name)) return position;
    }

    return null;
}

fn reached_from(
    context: *const Context,
    table: []const Macro,
    origin: usize,
) [macro_count_max]bool {
    assert(origin < table.len);
    assert(table.len <= macro_count_max);

    var reached: [macro_count_max]bool = @splat(false);
    var stack: [macro_count_max]usize = @splat(0);
    var depth: u32 = 1;

    stack[0] = origin;

    for (0..macro_count_max * macro_count_max) |_| {
        if (depth == 0) break;

        depth -= 1;

        const body = context.span_text(table[stack[depth]].body);

        for (table, 0..) |held, target| {
            if (reached[target]) continue;
            if (!invokes(body, context.span_text(held.name))) continue;

            assert(depth < macro_count_max);

            reached[target] = true;
            stack[depth] = target;
            depth += 1;
        }
    }

    return reached;
}

fn invokes_itself(context: *const Context, index: u32, body: []const u8) bool {
    assert(index < context.tokens.len);

    if (index + 2 >= context.tokens.len) return false;

    const named = context.tokens[index + 2];
    if (named.kind != .identifier) return false;

    assert(named.length > 0);

    return invokes(body, context.text(named));
}

fn invokes(body: []const u8, name: []const u8) bool {
    var cursor: usize = 0;

    for (0..body.len) |_| {
        assert(cursor <= body.len);

        const found = scan.find(body[cursor..], name) orelse return false;
        const start = cursor + found;
        const after = start + name.len;

        assert(after <= body.len);

        const whole = start == 0 or !scan.is_identifier_part(body[start - 1]);
        cursor = after;

        if (!whole) continue;
        if (after >= body.len) continue;
        if (body[after] != '!') continue;
        if (!rooted_elsewhere(body, start)) return true;
    }

    return false;
}

fn rooted_elsewhere(body: []const u8, start: usize) bool {
    assert(start <= body.len);

    var cursor = start;
    var root: []const u8 = "";

    for (0..path_segment_max) |_| {
        if (!std.mem.endsWith(u8, body[0..cursor], path_separator)) break;

        const end = cursor - path_separator.len;
        const begin = segment_start(body, end);

        root = body[begin..end];
        cursor = begin;
    }

    assert(cursor <= start);

    if (cursor == start) return false;
    return !scan.word_in(&crate_roots, root);
}

fn segment_start(body: []const u8, end: usize) usize {
    assert(end <= body.len);

    var begin = end;

    for (0..end) |_| {
        if (begin == 0) break;

        const byte = body[begin - 1];

        if (!scan.is_identifier_part(byte)) {
            if (byte != '$') break;
        }

        begin -= 1;
    }

    assert(begin <= end);

    return begin;
}

fn enclosing_block(context: *const Context, token: u32) ?Frame {
    assert(token < context.tokens.len);

    for (context.tokens[token + 1 ..], token + 1..) |held, index| {
        if (held.kind != .block_start) continue;

        assert(index > token);

        return Frame.at_block(context, @intCast(index));
    }

    return null;
}

fn macro_lines(gpa: std.mem.Allocator, opening: []const u8, line: []const u8, count: u32) ![]u8 {
    assert(count > 0);
    assert(line.len > 0);

    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(gpa);

    try source.appendSlice(gpa, opening);

    for (0..count) |_| try source.appendSlice(gpa, line);

    return source.toOwnedSlice(gpa);
}

fn expect_count(source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a long macro inside a test module is reported" {
    const gpa = std.testing.allocator;
    const opening = "#[cfg(test)]\nmod tests {\n    macro_rules! cases {\n";
    const lines = Settings.Thresholds.default.function_lines_max;
    const body = try macro_lines(gpa, opening, "        () => {};\n", lines);
    defer gpa.free(body);

    const source = try std.mem.concat(gpa, u8, &.{ body, "    }\n}\n" });
    defer gpa.free(source);

    try expect_count(source, 1);
}

test "a test table in test code is quiet" {
    const source = "#[cfg(test)]\nmod tests {\n    macro_rules! cases {\n" ++
        "        ($name:ident) => {\n            cases!($name, 1);\n        };\n" ++
        "        ($name:ident, $value:expr) => {\n            #[test]\n" ++
        "            fn $name() {\n                assert_eq!($value, 1);\n" ++
        "            }\n        };\n    }\n\n    macro_rules! each {\n" ++
        "        ($($name:ident),*) => {\n            $(cases!($name);)*\n" ++
        "        };\n    }\n\n    macro_rules! timed {\n" ++
        "        ($($name:ident),*) => {\n            $(#[bench]\n" ++
        "            fn $name(bencher: &mut Bencher) {})*\n        };\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a test table outside test code and a recursive test helper are reported" {
    const table = "macro_rules! cases {\n    ($name:ident) => {\n        cases!($name, 1);\n" ++
        "    };\n    ($name:ident, $value:expr) => {\n        #[test]\n" ++
        "        fn $name() {\n            assert_eq!($value, 1);\n        }\n    };\n}\n";

    const helper = "#[cfg(test)]\nmod tests {\n    macro_rules! check {\n" ++
        "        () => {};\n        ($head:expr $(, $rest:expr)*) => {\n" ++
        "            assert!($head);\n            check!($($rest),*);\n        };\n" ++
        "    }\n}\n";

    try expect_count(table, 1);
    try expect_count(helper, 1);
}

test "a macro within the function line budget is quiet" {
    const gpa = std.testing.allocator;
    const lines = Settings.Thresholds.default.function_lines_max / 2;
    const body = try macro_lines(gpa, "macro_rules! cases {\n", "    () => {};\n", lines);
    defer gpa.free(body);

    const source = try std.mem.concat(gpa, u8, &.{ body, "}\n" });
    defer gpa.free(source);

    try testing.expect_quiet(@This(), .rust, source);
}

test "a macro over the function line budget is reported" {
    const gpa = std.testing.allocator;
    const lines = Settings.Thresholds.default.function_lines_max;
    const body = try macro_lines(gpa, "macro_rules! cases {\n", "    () => {};\n", lines);
    defer gpa.free(body);

    const source = try std.mem.concat(gpa, u8, &.{ body, "}\n" });
    defer gpa.free(source);

    try expect_count(source, 1);
}

test "mutually recursive macros are reported" {
    const source = "macro_rules! ping {\n    () => {\n        pong!()\n    };\n}\n\n" ++
        "macro_rules! pong {\n    () => {\n        ping!()\n    };\n}\n";

    try expect_count(source, 2);
}

test "a macro invoking a namesake through another crate is quiet" {
    const source = "macro_rules! trace {\n    ($op:expr) => {\n" ++
        "        tracing::trace!(op = $op);\n        ::log::trace!(\"{}\", $op);\n    };\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a macro invoking itself through its own crate is reported" {
    const rooted = "macro_rules! count {\n    () => {\n        0\n    };\n" ++
        "    ($head:tt) => {\n        1 + $crate::count!()\n    };\n}\n";

    const relative = "macro_rules! count {\n    () => {\n        0\n    };\n" ++
        "    ($head:tt) => {\n        1 + self::count!()\n    };\n}\n";

    try expect_count(rooted, 1);
    try expect_count(relative, 1);
}

test "a macro invoking a leaf macro is quiet" {
    const source = "macro_rules! leaf {\n    () => {\n        1\n    };\n}\n\n" ++
        "macro_rules! trunk {\n    () => {\n        leaf!()\n    };\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a procedural macro is reported" {
    const source = "#[proc_macro_derive(Builder)]\npub fn builder(input: TokenStream) -> " ++
        "TokenStream {\n    input\n}\n";

    try expect_count(source, 1);
}
