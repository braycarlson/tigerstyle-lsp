const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const types = @import("../types.zig");
const Context = @import("../context.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const is_identifier_part = scan.is_identifier_part;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 9: \"The use of pointers should be restricted. Specifically, " ++
                "no more than one level of dereferencing is allowed.\"",
        },
    },
    .code = "TS051",
    .default_on = false,
    .description = "A pointer points at a value rather than at another pointer, so every access " ++
        "is one dereference a reader can follow.",
    .explanation = "",
    .fix_title = "",
    .fixable = .never,
    .group = .stable,
    .name = "pointer-depth",
    .severity = .warning,
    .summary = "A pointer must not point at a pointer",
    .url = "",
};

const caret_sigil = "^";
const dereference_suffix = ".*";

const expression_message = "the expression dereferences twice; one level of dereference is " ++
    "the limit";

const pointer_layers_max: u32 = 8;
const pointer_modifier_words = [_][]const u8{ "allowzero", "const", "mut", "volatile" };
const type_message = "the type points at a pointer; one level of dereference is the limit";

pub fn run(context: *const Context, sink: *Sink) void {
    if (context.conventions.pointer_sigils.len == 0) return;

    report_deep_types(context, sink);
    report_deep_dereferences(context, sink);
}

fn report_deep_types(context: *const Context, sink: *Sink) void {
    var held_types = context.views(.type);
    var reported_end: u32 = 0;

    for (0..held_types.remaining) |_| {
        const held = held_types.next() orelse break;
        const span = held.span();

        assert(held.category() == .type);
        assert(span.end() <= context.source.len);

        if (span.offset < reported_end) continue;
        if (pointer_layers(context, held.text(context.source)) < 2) continue;
        if (marks_a_boundary(context, span.offset)) continue;

        reported_end = span.end();

        assert(reported_end >= span.offset);

        sink.report(span, type_message);
    }
}

fn report_deep_dereferences(context: *const Context, sink: *Sink) void {
    const tokens = context.tokens;
    if (tokens.len < 2) return;

    for (1..tokens.len) |position| {
        const index: u32 = @intCast(position);
        const first = tokens[index - 1];
        const second = tokens[index];

        if (!dereferences_twice(context, index)) continue;
        if (types.starts_a_type(context, index - 1)) continue;
        if (marks_a_boundary(context, first.offset)) continue;

        assert(first.offset <= second.offset);
        assert(second.end() <= context.source.len);

        sink.report(.between(first.offset, second.end()), message_of(context, index));
    }
}

fn marks_a_boundary(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    if (types.line_marks_a_boundary(context, offset)) return true;
    if (types.signature_marks_a_boundary(context, offset)) return true;

    const index = context.lexer_index_at(offset) orelse return false;

    assert(index < context.tokens.len);

    return types.nests_a_boundary(context, index);
}

fn message_of(context: *const Context, index: u32) []const u8 {
    assert(index > 0);
    assert(index < context.tokens.len);

    if (index < 2) return expression_message;
    if (declares_a_type(context, index - 2)) return type_message;
    return expression_message;
}

fn dereferences_twice(context: *const Context, index: u32) bool {
    assert(index > 0);
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    const first = tokens[index - 1];
    const second = tokens[index];

    assert(first.offset <= second.offset);

    if (sigils_carry_a_caret(context)) {
        if (!std.mem.eql(u8, context.text(first), caret_sigil)) return false;
        return std.mem.eql(u8, context.text(second), caret_sigil);
    }

    if (first.is_punctuation(.star)) {
        if (second.is_punctuation(.star)) return !multiplies(context, index);
    }

    if (!std.mem.eql(u8, context.text(first), dereference_suffix)) return false;
    return std.mem.eql(u8, context.text(second), dereference_suffix);
}

fn sigils_carry_a_caret(context: *const Context) bool {
    const sigils = context.conventions.pointer_sigils;

    assert(sigils.len > 0);

    for (sigils) |sigil| {
        assert(sigil.len > 0);

        if (std.mem.eql(u8, sigil, caret_sigil)) return true;
    }

    return false;
}

fn multiplies(context: *const Context, index: u32) bool {
    assert(index > 0);
    assert(index < context.tokens.len);

    if (index < 2) return false;
    if (!context.tokens[index - 2].ends_a_value()) return false;
    return !declares_a_type(context, index - 2);
}

fn declares_a_type(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    if (tokens[index].kind != .identifier) return false;
    if (support.in_signature(context, tokens[index].offset)) return true;
    if (index == 0) return false;

    const declares = switch (tokens[index - 1].kind) {
        .block_start, .newline => true,
        .keyword => |keyword| switch (keyword) {
            .constant, .declare, .mutable => true,
            else => false,
        },
        else => false,
    };

    if (declares) assert(tokens[index - 1].kind != .identifier);

    return declares;
}

fn pointer_layers(context: *const Context, text: []const u8) u32 {
    const sigils = context.conventions.pointer_sigils;
    var rest = text;
    var layers: u32 = 0;

    assert(sigils.len > 0);

    for (0..pointer_layers_max) |_| {
        rest = pointer_modifiers_skipped(rest);

        const sigil = sigil_at(sigils, rest) orelse break;

        rest = rest[sigil.len..];
        layers += 1;
    }

    assert(layers <= pointer_layers_max);

    return layers;
}

fn sigil_at(sigils: []const []const u8, rest: []const u8) ?[]const u8 {
    for (sigils) |sigil| {
        assert(sigil.len > 0);

        if (!std.mem.startsWith(u8, rest, sigil)) continue;

        assert(rest.len >= sigil.len);

        return sigil;
    }

    return null;
}

fn pointer_modifiers_skipped(text: []const u8) []const u8 {
    var rest = text;

    for (0..pointer_layers_max) |_| {
        const trimmed = std.mem.trimStart(u8, rest, scan.ascii_whitespace);

        if (std.mem.startsWith(u8, trimmed, "?")) {
            rest = trimmed[1..];

            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "'")) {
            rest = lifetime_skipped(trimmed[1..]);

            continue;
        }

        const word = modifier_at(trimmed) orelse {
            assert(trimmed.len <= text.len);

            return trimmed;
        };

        rest = trimmed[word.len..];
    }

    assert(rest.len <= text.len);

    return rest;
}

fn lifetime_skipped(lifetime: []const u8) []const u8 {
    const end = for (lifetime, 0..) |byte, offset| {
        if (!is_identifier_part(byte)) break offset;
    } else lifetime.len;

    const rest = lifetime[end..];

    assert(rest.len <= lifetime.len);
    if (rest.len > 0) assert(!is_identifier_part(rest[0]));

    return rest;
}

fn modifier_at(text: []const u8) ?[]const u8 {
    for (pointer_modifier_words) |word| {
        if (!types.names_exactly(text, word)) continue;

        assert(word.len > 0);
        assert(text.len >= word.len);

        return word;
    }

    return null;
}

test "a zig double dereference is reported" {
    const source = "pub fn store(entry: anytype) void {\n    entry.value_ptr.*.* = 1;\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 2, 20 }});
}

test "a zig single dereference is quiet" {
    const source = "pub fn store(entry: anytype) void {\n    entry.value_ptr.* = 1;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig out parameter of a c abi signature is at the boundary" {
    const source = "pub fn read(\n    out: **u8,\n    count: usize,\n) callconv(.c) void {\n" ++
        "    _ = out;\n    _ = count;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig double pointer of a plain signature still reports" {
    const source = "pub fn read(\n    out: **u8,\n    count: usize,\n) void {\n" ++
        "    _ = out;\n    _ = count;\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 2, 10 }});
}

test "a zig double pointer inside an opaque container is at the boundary" {
    const source = "pub const Config = opaque {\n    pub fn load(out: **Config) void {\n" ++
        "        _ = out;\n    }\n};\n";

    try testing.expect_quiet(@This(), .zig, source);
}
