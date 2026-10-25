const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const types = @import("../types.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const is_identifier_part = scan.is_identifier_part;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use simpler function signatures and return types to reduce " ++
                "dimensionality at the call site, the number of branches that need to be " ++
                "handled at the call site, because this dimensionality can also be viral, " ++
                "propagating through the call chain. For example, as a return type, `void` " ++
                "trumps `bool`, `bool` trumps `u64`, `u64` trumps `?u64`, and `?u64` trumps " ++
                "`!u64`.\"",
        },
    },
    .code = "TS041",
    .default_on = true,
    .description = "A return type carries one layer of optionality, because every layer is a " ++
        "case each caller has to handle.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "simple-return-type",
    .severity = .warning,
    .summary = "Keep the return type simple",
    .url = "",
};

const Stack = struct {
    along: [return_type_depth_max]u32,
    base: [return_type_depth_max]u32,
    deepest: u32,
    depth: u32,

    const empty: Stack = .{ .along = @splat(0), .base = @splat(0), .deepest = 0, .depth = 0 };

    fn ascend(stack: *Stack) void {
        assert(stack.depth < return_type_depth_max);

        stack.depth -|= 1;

        assert(stack.depth < return_type_depth_max - 1);
    }

    fn descend(stack: *Stack, carried: u32) void {
        assert(stack.depth < return_type_depth_max);
        assert(carried <= stack.deepest);

        if (stack.depth + 1 >= return_type_depth_max) return;

        stack.depth += 1;
        stack.base[stack.depth] = carried;
        stack.along[stack.depth] = carried;
    }

    fn mark(stack: *Stack) void {
        assert(stack.depth < return_type_depth_max);

        stack.along[stack.depth] += 1;
        stack.deepest = @max(stack.deepest, stack.along[stack.depth]);

        assert(stack.deepest >= stack.along[stack.depth]);
    }

    fn step(stack: *Stack, text: []const u8, offset: u32) void {
        assert(offset < text.len);
        assert(stack.depth < return_type_depth_max);

        switch (text[offset]) {
            '(' => stack.descend(stack.along[stack.depth]),
            '<', '[', '{' => stack.descend(0),
            ')', '>', '}' => stack.ascend(),
            ']' => {
                stack.ascend();

                if (continues_a_type(text, offset + 1)) stack.along[stack.depth] = 0;
            },
            ',' => stack.along[stack.depth] = stack.base[stack.depth],
            else => {},
        }
    }
};

const result_count_max: u32 = 16;
const return_type_depth_max: u32 = 16;
const return_type_layers_max: u32 = 2;
const transparent_openers = [_][]const u8{ "Promise<", "Union[" };

pub fn run(context: *const Context, sink: *Sink) void {
    const markers = context.conventions.optional_markers;

    if (markers.len == 0) {
        if (!reads_results(context)) return;
    }

    var functions = context.views(.function);

    for (0..functions.remaining) |_| {
        const function = functions.next() orelse break;
        const held = function.as_function() orelse continue;
        const returns = held.returns_span() orelse continue;
        const text = context.span_text(returns);
        const layers = layers_of(text, markers) + flag_layers(context, text);

        assert(text.len == returns.length);

        if (layers < return_type_layers_max) continue;

        assert(returns.end() <= context.source.len);

        sink.report_formatted(
            returns,
            "{s} stacks {d} layers of optionality; every layer is a case each caller has to " ++
                "handle",
            .{ scan.utf8_or(shown_of(text), "the type"), layers },
        );
    }
}

fn reads_results(context: *const Context) bool {
    const conventions = context.conventions;
    if (conventions.result_flag_types.len > 0) return true;
    return conventions.result_nil_prefixes.len > 0;
}

fn shown_of(text: []const u8) []const u8 {
    const trimmed = scan.trim_ascii(text);
    const stripped = if (std.mem.startsWith(u8, trimmed, ":")) trimmed[1..] else text;
    const shown = scan.trim_ascii(stripped);

    assert(trimmed.len <= text.len);
    assert(shown.len <= trimmed.len);

    return shown;
}

fn layers_of(text: []const u8, markers: []const []const u8) u32 {
    var stack: Stack = .empty;
    var offset: u32 = 0;

    for (0..text.len) |_| {
        if (offset >= text.len) break;

        if (opener_at(text, offset, markers)) |marker| {
            stack.mark();
            offset += @intCast(marker.len);

            if (opens(marker[marker.len - 1])) stack.descend(stack.along[stack.depth]);

            continue;
        }

        if (opener_at(text, offset, &transparent_openers)) |marker| {
            stack.descend(stack.along[stack.depth]);
            offset += @intCast(marker.len);

            continue;
        }

        stack.step(text, offset);
        offset += 1;
    }

    assert(offset >= text.len);
    assert(stack.depth < return_type_depth_max);
    assert(stack.deepest <= text.len);

    return stack.deepest;
}

fn opener_at(text: []const u8, offset: u32, markers: []const []const u8) ?[]const u8 {
    assert(offset < text.len);

    const rest = text[offset..];

    for (markers) |marker| {
        assert(marker.len > 0);

        if (!std.mem.startsWith(u8, rest, marker)) continue;
        if (!bounded_before(text, offset, marker)) continue;
        if (!bounded_after(rest, marker)) continue;

        assert(offset + marker.len <= text.len);

        return marker;
    }

    return null;
}

fn bounded_before(text: []const u8, offset: u32, marker: []const u8) bool {
    assert(offset < text.len);
    assert(marker.len > 0);

    if (!is_identifier_part(marker[0])) return true;
    if (offset == 0) return true;
    return !is_identifier_part(text[offset - 1]);
}

fn bounded_after(rest: []const u8, marker: []const u8) bool {
    assert(marker.len > 0);
    assert(marker.len <= rest.len);

    if (!is_identifier_part(marker[marker.len - 1])) return true;
    if (rest.len == marker.len) return true;
    return !is_identifier_part(rest[marker.len]);
}

fn opens(byte: u8) bool {
    const opened = switch (byte) {
        '(', '<', '[', '{' => true,
        else => false,
    };

    if (opened) assert(!closes(byte));
    if (opened) assert(!is_identifier_part(byte));

    return opened;
}

fn closes(byte: u8) bool {
    const closed = switch (byte) {
        ')', '>', ']', '}' => true,
        else => false,
    };

    if (closed) assert(!is_identifier_part(byte));
    if (closed) assert(!scan.is_ascii_whitespace(byte));

    return closed;
}

fn continues_a_type(text: []const u8, offset: u32) bool {
    assert(offset <= text.len);

    const rest = std.mem.trimStart(u8, text[offset..], scan.ascii_whitespace);
    if (rest.len == 0) return false;

    assert(!scan.is_ascii_whitespace(rest[0]));

    if (is_identifier_part(rest[0])) return true;

    return switch (rest[0]) {
        '!', '*', '?', '[' => true,
        else => false,
    };
}

fn flag_layers(context: *const Context, text: []const u8) u32 {
    if (!reads_results(context)) return 0;

    const inner = tuple_inner(scan.trim_ascii(text)) orelse text;
    var depth: u32 = 0;
    var layers: u32 = 0;
    var ordinal: u32 = 0;
    var start: u32 = 0;

    for (inner, 0..) |byte, position| {
        if (opens(byte)) {
            depth += 1;

            continue;
        }

        if (closes(byte)) {
            depth -|= 1;

            continue;
        }

        if (byte != ',') continue;
        if (depth > 0) continue;
        if (ordinal >= result_count_max) continue;

        layers += result_layer(context, inner[start..position], ordinal);
        ordinal += 1;
        start = @intCast(position + 1);
    }

    assert(ordinal <= result_count_max);
    assert(start <= inner.len);
    assert(layers <= ordinal);

    const total = layers + result_layer(context, inner[start..], ordinal);

    assert(total <= ordinal + 1);

    return total;
}

fn tuple_inner(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, "(")) return null;

    const rest = text[1..];
    var depth: u32 = 1;

    for (rest, 0..) |byte, position| {
        if (opens(byte)) depth += 1;
        if (closes(byte)) depth -= 1;
        if (depth > 0) continue;
        if (position + 1 < rest.len) return null;

        assert(position + 1 == rest.len);

        return rest[0..position];
    }

    assert(depth > 0);

    return null;
}

fn result_layer(context: *const Context, result: []const u8, ordinal: u32) u32 {
    assert(ordinal <= result_count_max);

    const text = scan.trim_ascii(result);
    if (text.len == 0) return 0;
    if (ordinal == 0) return if (names_a_nil(context, text)) 1 else 0;

    const space = std.mem.findScalarLast(u8, text, ' ');
    const spelled = if (space) |at| text[at + 1 ..] else text;

    assert(spelled.len > 0);

    for (context.conventions.result_flag_types) |flag| {
        if (names_a_flag(spelled, flag)) return 1;
    }

    return 0;
}

fn names_a_nil(context: *const Context, text: []const u8) bool {
    assert(text.len > 0);

    const space = std.mem.findScalar(u8, text, ' ');
    const after = if (space) |at| text[at + 1 ..] else text;
    const spelled = std.mem.trimStart(u8, after, scan.ascii_whitespace);

    assert(spelled.len <= text.len);

    for (context.conventions.result_nil_prefixes) |prefix| {
        if (names_a_prefix(text, prefix)) return true;
        if (names_a_prefix(spelled, prefix)) return true;
    }

    return false;
}

fn names_a_prefix(text: []const u8, prefix: []const u8) bool {
    assert(prefix.len > 0);

    if (is_identifier_part(prefix[prefix.len - 1])) return types.names_exactly(text, prefix);

    const named = std.mem.startsWith(u8, text, prefix);

    if (named) assert(text.len >= prefix.len);

    return named;
}

fn names_a_flag(spelled: []const u8, flag: []const u8) bool {
    assert(flag.len > 0);

    if (!std.mem.endsWith(u8, spelled, flag)) return false;

    const head = spelled[0 .. spelled.len - flag.len];

    assert(head.len < spelled.len);

    if (head.len == 0) return true;
    return !std.ascii.isAlphanumeric(head[head.len - 1]);
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a stacked return type is reported" {
    const source = "fn read() -> Option<Option<u32>> {\n    return None;\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "2 layers") != null);
}

test "two different wrappers on one path are reported" {
    try expect_count(.rust, "fn read() -> Result<Option<u32>, Error> {\n    Ok(None)\n}\n", 1);
    try expect_count(.rust, "fn read() -> Option<Result<u32, Error>> {\n    None\n}\n", 1);
    try expect_count(.zig, "fn read() !?u32 {\n    return null;\n}\n", 1);
    try expect_count(.zig, "fn read() anyerror!?u32 {\n    return null;\n}\n", 1);
}

test "a wrapper inside a tuple is the same path" {
    const source = "fn read() -> Option<(String, Option<String>)> {\n    None\n}\n";

    try expect_count(.rust, source, 1);
    try testing.expect_quiet(@This(), .rust, "fn read() -> Option<(u32, u32)> {\n    None\n}\n");
}

test "a wrapper inside a container is another path" {
    const source = "fn read() -> Option<Vec<Option<u32>>> {\n    None\n}\n";
    const python = "def read() -> Optional[list[Optional[int]]]:\n    return None\n";
    const odin = "package fixture\n\nread :: proc() -> Maybe([]Maybe(int)) {\n    return nil\n}\n";
    const zig = "fn read() ?struct { a: ?u32 } {\n    return null;\n}\n";
    const sliced = "fn read() ?[]?u32 {\n    return null;\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try testing.expect_quiet(@This(), .python, python);
    try testing.expect_quiet(@This(), .odin, odin);
    try testing.expect_quiet(@This(), .zig, zig);
    try testing.expect_quiet(@This(), .zig, sliced);
}

test "a python none union stacks on an optional" {
    const source = "def read() -> Optional[int] | None:\n    return None\n";
    const nested = "def read() -> Optional[Union[int, None]]:\n    return None\n";
    const single = "def read() -> int | None:\n    return None\n";

    try expect_count(.python, source, 1);
    try expect_count(.python, nested, 1);
    try testing.expect_quiet(@This(), .python, single);
}

test "an odin flag result counts as a layer" {
    const source = "package fixture\n\nread :: proc() -> (Maybe(int), Error) {\n" ++
        "    return nil, nil\n}\n";

    const flagged = "package fixture\n\nread :: proc() -> (int, bool, Error) {\n" ++
        "    return 0, false, nil\n}\n";

    const single = "package fixture\n\nread :: proc() -> (int, bool) {\n    return 0, false\n}\n";

    try expect_count(.odin, source, 1);
    try expect_count(.odin, flagged, 1);
    try testing.expect_quiet(@This(), .odin, single);
}

test "a go result list counts its optional dimensions" {
    const source = "package fixture\n\nfunc read() (*int, bool, error) {\n" ++
        "\treturn nil, false, nil\n}\n";

    const pointer = "package fixture\n\nfunc read() (*int, error) {\n\treturn nil, nil\n}\n";
    const value = "package fixture\n\nfunc read() (int, error) {\n\treturn 0, nil\n}\n";
    const sliced = "package fixture\n\nfunc read() ([]int, error) {\n\treturn nil, nil\n}\n";

    try expect_count(.go, source, 1);
    try expect_count(.go, pointer, 1);
    try testing.expect_quiet(@This(), .go, value);
    try testing.expect_quiet(@This(), .go, sliced);
}

test "a typescript union counts its absent members" {
    const source = "function read(): number | null | undefined {\n    return null;\n}\n";

    const promised = "async function read(): Promise<number | null | undefined> {\n" ++
        "    return null;\n}\n";

    const single = "function read(): number | null {\n    return null;\n}\n";
    const named = "function read(): Nullable<number> {\n    return null;\n}\n";

    try expect_count(.typescript, source, 1);
    try expect_count(.typescript, promised, 1);
    try testing.expect_quiet(@This(), .typescript, single);
    try testing.expect_quiet(@This(), .typescript, named);
}

test "one layer is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn read() -> Option<u32> {\n    return None;\n}\n");
}

test "a zig error option is reported" {
    try expect_count(.zig, "fn read() !!u32 {\n    return 0;\n}\n", 1);
}
