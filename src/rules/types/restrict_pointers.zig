const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const types = @import("../types.zig");
const Context = @import("../context.zig");
const HandOvers = @import("../hand_overs.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Token = scylla.Token;
const is_identifier_part = scan.is_identifier_part;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 9: \"The use of pointers should be restricted. Specifically, " ++
                "no more than one level of dereferencing is allowed. Pointer dereference " ++
                "operations may not be hidden in macro definitions or inside typedef " ++
                "declarations. Function pointers are not permitted.\"",
        },
        .{
            .standard = "TigerStyle",
            .text = "\"Callbacks go last in the list of parameters. This mirrors control flow: " ++
                "callbacks are also _invoked_ last.\"",
        },
    },
    .code = "TS019",
    .default_on = false,
    .description = "A raw pointer takes the lifetime out of the type, so nothing checks the " ++
        "access that follows.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "restrict-pointers",
    .severity = .@"error",
    .summary = "A raw pointer bypasses the type system",
    .url = "",
};

const brace_words = [_][]const u8{ "{", "}" };
const configuration_prefix = "cfg";
const context_lookbehind_max: u32 = 8;
const context_names = [_][]const u8{ "context", "ctx", "user_data", "userdata" };
const context_type_sigils = [_][]const u8{ "&", "*", "?", "^" };
const context_type_words = [_][]const u8{ "const", "mut", "volatile" };
const pointer_qualifiers = [_][]const u8{ "const ", "volatile " };
const raw_message = "the type is a raw pointer; take a reference the compiler can check";
const signature_scan_max: u32 = 256;

const unsafe_message = "the declaration widens the unchecked surface; confine it to the block " ++
    "that needs it";

pub fn run(context: *const Context, sink: *Sink) void {
    var hand_overs: HandOvers = undefined;

    assert(context.tokens.len <= std.math.maxInt(u32));

    hand_overs.begin();

    report_pointer_types(context, sink, &hand_overs);
    report_pointer_tokens(context, sink, &hand_overs);
    report_wide_unsafe(context, sink);
}

fn report_pointer_types(
    context: *const Context,
    sink: *Sink,
    hand_overs: *HandOvers,
) void {
    var held_types = context.views(.type);

    for (0..held_types.remaining) |_| {
        const held = held_types.next() orelse break;
        const span = held.span();

        assert(held.category() == .type);
        assert(span.end() <= context.source.len);

        if (!names_a_pointer(context, held.text(context.source))) continue;

        const index = context.lexer_index_from(span.offset);
        if (index >= context.tokens.len) continue;

        assert(context.tokens[index].offset >= span.offset);

        if (crosses_a_boundary(context, hand_overs, index)) continue;

        sink.report(span, raw_message);
    }
}

fn report_pointer_tokens(
    context: *const Context,
    sink: *Sink,
    hand_overs: *HandOvers,
) void {
    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);
        const rest = rest_of_line(context, token);
        if (!points_raw(context, index, rest)) continue;

        assert(rest.len > 0);

        if (points_at_a_function(context, rest)) continue;
        if (opens_a_multilevel_pointer(context, rest)) continue;
        if (follows_a_raw_prefix(context, token)) continue;
        if (crosses_a_boundary(context, hand_overs, index)) continue;

        assert(token.end() <= context.source.len);

        sink.report(token.span(), raw_message);
    }
}

fn report_wide_unsafe(context: *const Context, sink: *Sink) void {
    const word = context.conventions.unsafe_word;
    if (word.len == 0) return;

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (!std.mem.eql(u8, context.text(token), word)) continue;

        assert(token.length == word.len);

        if (opens_a_block(context, index)) continue;
        if (!declares(context, index)) continue;

        const first = stream.modifier_start(
            context.pairs,
            context.tokens,
            context.source,
            index,
            stream.modifier_count_max,
        );

        assert(first <= index);

        sink.report(context.tokens[first].span(), unsafe_message);
    }
}

fn rest_of_line(context: *const Context, token: Token) []const u8 {
    assert(token.offset <= context.source.len);

    const line = context.line_of(token.offset);
    const end = @max(context.line_span(line).end(), token.offset);

    assert(end <= context.source.len);

    return context.source[token.offset..end];
}

fn points_raw(context: *const Context, index: u32, rest: []const u8) bool {
    assert(index < context.tokens.len);
    assert(rest.len <= context.source.len - context.tokens[index].offset);

    if (names_a_pointee(context, rest)) return true;
    if (opens_with_a_raw_prefix(context, rest)) return true;
    if (follows_a_member_dot(context, index)) return false;
    if (declared_by_a_keyword(context, index)) return false;
    if (!names_a_pointer(context, rest)) return false;
    return !types.starts_a_type(context, index);
}

fn declared_by_a_keyword(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index == 0) return false;

    const before = context.tokens[index - 1];

    assert(before.offset <= context.tokens[index].offset);

    if (before.is_keyword(.function)) return true;
    return before.is_keyword(.@"struct");
}

fn follows_a_member_dot(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index == 0) return false;

    assert(context.tokens[index - 1].offset <= context.tokens[index].offset);

    return context.tokens[index - 1].is_punctuation(.dot);
}

fn crosses_a_boundary(context: *const Context, hand_overs: *HandOvers, index: u32) bool {
    assert(index < context.tokens.len);

    const offset = context.tokens[index].offset;

    assert(offset <= context.source.len);

    if (types.line_marks_a_boundary(context, offset)) return true;
    if (types.signature_marks_a_boundary(context, offset)) return true;
    if (types.nests_a_boundary(context, index)) return true;
    if (inside_a_function_type(context, index)) return true;
    if (argument_of_a_boundary_call(context, index)) return true;
    if (signs_a_function_handed_over(context, hand_overs, offset)) return true;
    if (signs_a_function_a_macro_takes(context, index)) return true;
    if (types.declares_without_a_body(context, offset)) return true;
    return binds_an_exempt_name(context, index);
}

fn signs_a_function_a_macro_takes(context: *const Context, index: u32) bool {
    const tokens = context.tokens;

    assert(index < tokens.len);

    if (!context.conventions.macros_invoke_with_bang) return false;

    const keyword = function_keyword_before(context, index) orelse return false;
    const enclosing = context.pairs.enclosing_at(tokens[keyword].offset) orelse return false;
    const opener = enclosing.open;

    assert(opener < keyword);

    if (opener < 2) return false;
    if (!tokens[opener - 1].is_punctuation(.bang)) return false;
    if (tokens[opener - 2].kind != .identifier) return false;
    return !std.mem.startsWith(u8, context.text(tokens[opener - 2]), configuration_prefix);
}

fn function_keyword_before(context: *const Context, index: u32) ?u32 {
    const tokens = context.tokens;
    var cursor = index;

    assert(index < tokens.len);

    for (0..signature_scan_max) |_| {
        if (cursor == 0) return null;

        cursor -= 1;

        const token = tokens[cursor];
        if (token.is_keyword(.function)) return cursor;
        if (token.kind == .block_start) return null;
        if (token.kind == .block_end) return null;
        if (token.is_punctuation(.semicolon)) return null;
        if (scan.word_in(&brace_words, context.text(token))) return null;
        if (!token.closes_a_group()) continue;

        cursor = context.pairs.partner_of(cursor) orelse return null;
    }

    return null;
}

fn signs_a_function_handed_over(
    context: *const Context,
    hand_overs: *HandOvers,
    offset: u32,
) bool {
    assert(offset <= context.source.len);

    const function = support.signature_owner(context, offset) orelse return false;

    assert(function.signature_covers(offset));

    return hand_overs.covers(context, function);
}

fn binds_an_exempt_name(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    var cursor = index;

    for (0..context_lookbehind_max) |_| {
        if (cursor == 0) return false;

        cursor -= 1;

        const token = context.tokens[cursor];
        if (token.kind == .identifier) return exempts_the_name(context, context.text(token));
        if (!precedes_a_type(context, token)) return false;
    }

    assert(cursor < index);

    return false;
}

fn exempts_the_name(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    if (support.names_the_discard(context, name)) return true;
    return ends_with_a_context_word(name);
}

fn precedes_a_type(context: *const Context, token: Token) bool {
    assert(token.end() <= context.source.len);

    if (token.is_punctuation(.colon)) return true;
    if (token.is_punctuation(.star)) return true;

    const text = context.text(token);

    assert(text.len == token.length);

    if (scan.word_in(&context_type_words, text)) return true;
    if (!token.is_punctuation(.other)) return false;
    return scan.word_in(&context_type_sigils, text);
}

fn ends_with_a_context_word(name: []const u8) bool {
    for (context_names) |word| {
        assert(word.len > 0);

        if (std.mem.eql(u8, name, word)) return true;
        if (name.len <= word.len) continue;
        if (!std.mem.endsWith(u8, name, word)) continue;
        if (name[name.len - word.len - 1] != '_') continue;

        assert(name.len >= word.len + 1);

        return true;
    }

    return false;
}

fn inside_a_function_type(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const markers = context.conventions.pointer_function_markers;
    if (markers.len == 0) return false;

    const cursor = types.enclosing_group_opener(context, index) orelse return false;
    if (cursor == 0) return false;
    if (!context.tokens[cursor].is_punctuation(.paren_open)) return false;

    assert(cursor < index);
    assert(context.tokens[cursor - 1].offset <= context.tokens[cursor].offset);

    const convention = context.tokens[cursor - 1].kind == .string and cursor > 1;
    const before = if (convention) cursor - 2 else cursor - 1;
    const opener = context.text(context.tokens[before]);

    for (markers) |marker| {
        if (std.mem.eql(u8, function_word(marker), opener)) return true;
    }

    return false;
}

fn function_word(marker: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, marker, scan.ascii_whitespace);
    const opened = std.mem.endsWith(u8, trimmed, "(");
    const stripped = if (opened) trimmed[0 .. trimmed.len - 1] else trimmed;
    const word = std.mem.trimEnd(u8, stripped, scan.ascii_whitespace);

    assert(word.len > 0);
    assert(word.len <= marker.len);

    return word;
}

fn argument_of_a_boundary_call(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (context.conventions.pointer_boundary_markers.len == 0) return false;

    const opener = types.enclosing_group_opener(context, index) orelse return false;
    const token = context.tokens[opener];

    assert(opener < index);

    if (!token.is_punctuation(.paren_open)) return false;
    return types.line_marks_a_boundary(context, token.offset);
}

fn points_at_a_function(context: *const Context, rest: []const u8) bool {
    const pointee = pointee_of(rest) orelse return false;

    assert(rest[0] == '*');
    assert(pointee.len < rest.len);

    for (context.conventions.pointer_function_markers) |marker| {
        const word = function_word(marker);
        if (!std.mem.startsWith(u8, pointee, word)) continue;
        if (pointee.len == word.len) return true;
        if (!is_identifier_part(pointee[word.len])) return true;
    }

    return false;
}

fn names_a_pointer(context: *const Context, text: []const u8) bool {
    for (context.conventions.pointer_unsafe_names) |name| {
        assert(name.len > 0);

        if (!types.names_exactly(text, name)) continue;

        assert(text.len >= name.len);

        return true;
    }

    return false;
}

fn opens_with_a_raw_prefix(context: *const Context, rest: []const u8) bool {
    for (context.conventions.pointer_raw_prefixes) |prefix| {
        assert(prefix.len > 0);

        if (!std.mem.startsWith(u8, rest, prefix)) continue;

        assert(rest.len >= prefix.len);

        return true;
    }

    return false;
}

fn opens_a_multilevel_pointer(context: *const Context, rest: []const u8) bool {
    for (context.conventions.pointer_raw_prefixes) |prefix| {
        assert(prefix.len > 0);

        if (!std.mem.startsWith(u8, rest, prefix)) continue;

        const pointee = std.mem.trimStart(u8, rest[prefix.len..], scan.ascii_whitespace);

        assert(pointee.len < rest.len);

        return opens_with_a_raw_prefix(context, pointee);
    }

    return false;
}

fn follows_a_raw_prefix(context: *const Context, token: Token) bool {
    const line = context.line_span(context.line_of(token.offset));
    const before = context.source[line.offset..token.offset];
    const trimmed = std.mem.trimEnd(u8, before, scan.ascii_whitespace);

    assert(line.offset <= token.offset);
    assert(trimmed.len <= before.len);

    for (context.conventions.pointer_raw_prefixes) |prefix| {
        if (std.mem.endsWith(u8, trimmed, prefix)) return true;
    }

    return false;
}

fn names_a_pointee(context: *const Context, rest: []const u8) bool {
    const markers = context.conventions.pointer_pointee_markers;
    if (markers.len == 0) return false;

    const pointee = pointee_of(rest) orelse return false;

    assert(rest[0] == '*');
    assert(pointee.len < rest.len);

    for (markers) |marker| {
        if (std.mem.startsWith(u8, pointee, marker)) return true;
    }

    return false;
}

fn pointee_of(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, "*")) return null;

    assert(text[0] == '*');

    var rest = text[1..];

    for (pointer_qualifiers) |qualifier| {
        rest = std.mem.trimStart(u8, rest, scan.ascii_whitespace);

        if (std.mem.startsWith(u8, rest, qualifier)) rest = rest[qualifier.len..];
    }

    const pointee = std.mem.trimStart(u8, rest, scan.ascii_whitespace);

    assert(pointee.len < text.len);

    return pointee;
}

fn opens_a_block(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index + 1 >= context.tokens.len) return false;

    assert(context.tokens[index + 1].offset >= context.tokens[index].offset);

    return context.tokens[index + 1].kind == .block_start;
}

fn declares(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);
    assert(context.tokens[index].length > 0);

    for (context.tokens[index + 1 ..]) |token| {
        if (token.is_keyword(.function)) return true;
        if (token.is_keyword(.@"struct")) return true;
        if (token.is_keyword(.import)) return true;
        if (!token.is_keyword(.other)) return false;
    }

    return false;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a pointer reports the same under crlf as under lf" {
    const unix = "package fixture\n\nfunc read() int {\n\tvar address uintptr\n\treturn 0\n}\n";

    const windows = "package fixture\r\n\r\nfunc read() int {\r\n\tvar address uintptr\r\n" ++
        "\treturn 0\r\n}\r\n";

    var unix_findings = try testing.analyze(@This(), .go, unix);
    defer unix_findings.deinit();

    var windows_findings = try testing.analyze(@This(), .go, windows);
    defer windows_findings.deinit();

    try std.testing.expect(unix_findings.count() > 0);
    try std.testing.expectEqual(unix_findings.count(), windows_findings.count());

    for (0..unix_findings.count()) |index| {
        const unix_message = unix_findings.message(@intCast(index));

        try std.testing.expectEqualStrings(unix_message, windows_findings.message(@intCast(index)));
    }
}

test "an audited unsafe block is quiet" {
    const source = "fn read() {\n    // SAFETY: the pointer comes from a Vec.\n" ++
        "                       let value = unsafe {\n        get()\n    };\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "an opaque pointer at a platform boundary is quiet" {
    const source = "const Env = opaque {\n    pub fn take(address: *anyopaque) void {\n" ++
        "    }\n};\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a pointer in a multi-line c abi signature is at the boundary" {
    const source = "pub fn write(\n    target: [*]u8,\n    count: usize,\n" ++
        ") callconv(.c) void {\n    _ = target;\n    _ = count;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an opaque pointer outside a platform boundary is reported" {
    try expect_count(.zig, "const Env = struct {\n    address: *anyopaque,\n};\n", 1);
}

test "an opaque pointer parameter is reported off a boundary" {
    const source = "const Env = struct {\n    pub fn take(address: *anyopaque) void {\n" ++
        "    }\n};\n";

    const exported = "export fn take(address: *anyopaque) void {\n}\n";

    try expect_count(.zig, source, 1);
    try testing.expect_quiet(@This(), .zig, exported);
}

test "a raw pointer local is reported" {
    const source = "fn read() -> u32 {\n    let buffer: *const u8 = core::ptr::null();\n" ++
        "    return 0;\n}\n";

    try expect_count(.rust, source, 1);
}

test "a function a macro takes as input has the signature the macro gives it" {
    const source = "ffi_fn! {\n    fn take(pattern: *const c_char) -> *const Regex {\n" ++
        "        work()\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a pointer in the body of a macro input or under a configuration gate reports" {
    const body = "ffi_fn! {\n    fn take(pattern: Pattern) -> u32 {\n        let held = " ++
        "pattern as *const u8;\n        0\n    }\n}\n";

    const gated = "cfg_io! {\n    fn take(pattern: *const u8) -> u32 {\n        0\n    }\n}\n";

    try expect_count(.rust, body, 1);
    try expect_count(.rust, gated, 1);
}

test "a raw pointer parameter is reported off an extern boundary" {
    const source = "fn read(buffer: *const u8) -> u32 {\n    return 0;\n}\n";
    const foreign = "extern \"C\" fn read(buffer: *const u8) -> u32 {\n    return 0;\n}\n";

    try expect_count(.rust, source, 1);
    try testing.expect_quiet(@This(), .rust, foreign);
}

test "a local typed as the return type is still reported" {
    const source = "fn read() -> *const u8 {\n    let held: *const u8 = core::ptr::null();\n" ++
        "held\n}\n";

    try expect_count(.rust, source, 2);
}

test "a callback context is the other half of a callback" {
    const source = "const Env = struct {\n    user_data: ?*anyopaque,\n    ctx: *anyopaque,\n};\n";
    const named = "const Env = struct {\n    buffer: *anyopaque,\n};\n";

    try testing.expect_quiet(@This(), .zig, source);
    try expect_count(.zig, named, 1);
}

test "an odin procedure without a body declares a signature defined elsewhere" {
    const declared = "offset_of :: proc{offset_of_selector}\n\n" ++
        "offset_of_selector :: proc(selector: $T) -> uintptr ---\n\n" ++
        "raw_data :: proc(\n    value: []$E,\n) -> [^]E ---\n";

    const defined = "raw_data :: proc(value: []u8) -> [^]u8 {\n    return nil\n}\n";

    try testing.expect_quiet(@This(), .odin, declared);
    try expect_count(.odin, defined, 1);
}

test "a function handed to a vtable takes the vtable's pointer types" {
    const vtable = "fn allocator(arena: *Arena) Allocator {\n" ++
        "    return .{ .ptr = arena, .vtable = &.{ .alloc = alloc } };\n}\n\n" ++
        "fn alloc(context: *anyopaque, length: usize) ?[*]u8 {\n    return null;\n}\n";

    const called = "fn read(arena: *Arena) void {\n    _ = alloc(arena, 1);\n}\n\n" ++
        "fn alloc(context: *anyopaque, length: usize) ?[*]u8 {\n    return null;\n}\n";

    try testing.expect_quiet(@This(), .zig, vtable);
    try expect_count(.zig, called, 1);
}

test "a discarded parameter fills the signature it is handed" {
    const discarded = "fn seek(_: ?*anyopaque, offset: i64) void {\n    _ = offset;\n}\n";

    const named = "fn seek(handle: ?*anyopaque, offset: i64) void {\n    _ = handle;\n" ++
        "    _ = offset;\n}\n";

    try testing.expect_quiet(@This(), .zig, discarded);
    try expect_count(.zig, named, 1);
}

test "a prong of a switch that fills a field hands the function over" {
    const field = "fn benchmark(mode: Mode) Benchmark {\n    return .init(.{\n" ++
        "        .step = switch (mode) {\n            .simd => step_simd,\n" ++
        "            .table => step_table,\n        },\n    });\n}\n\n" ++
        "fn step_simd(ptr: *anyopaque) void {\n    _ = ptr;\n}\n\n" ++
        "fn step_table(ptr: *anyopaque) void {\n    _ = ptr;\n}\n";

    const aliased = "fn run(mode: Mode) void {\n    const step = switch (mode) {\n" ++
        "        .simd => step_simd,\n    };\n    _ = step;\n}\n\n" ++
        "fn step_simd(ptr: *anyopaque) void {\n    _ = ptr;\n}\n";

    try testing.expect_quiet(@This(), .zig, field);
    try expect_count(.zig, aliased, 1);
}

test "a prong of a switch nested in a prong hands the function over" {
    const field = "fn benchmark(mode: Mode, width: Width) Benchmark {\n    return .init(.{\n" ++
        "        .step = switch (mode) {\n            .simd => switch (width) {\n" ++
        "                .wide => step_simd,\n                .narrow => step_simd,\n" ++
        "            },\n        },\n    });\n}\n\n" ++
        "fn step_simd(ptr: *anyopaque) void {\n    _ = ptr;\n}\n";

    const aliased = "fn run(mode: Mode, width: Width) void {\n    const step = switch (mode) {\n" ++
        "        .simd => switch (width) {\n            .wide => step_simd,\n        },\n" ++
        "    };\n    _ = step;\n}\n\n" ++
        "fn step_simd(ptr: *anyopaque) void {\n    _ = ptr;\n}\n";

    try testing.expect_quiet(@This(), .zig, field);
    try expect_count(.zig, aliased, 1);
}

test "a function named through its anonymous container is handed over" {
    const handed = "fn open(grid: *Grid) void {\n    grid.open(struct {\n" ++
        "        fn ready(ptr: *anyopaque) void {\n            _ = ptr;\n        }\n" ++
        "    }.ready);\n}\n";

    const called = "const Ready = struct {\n    fn ready(ptr: *anyopaque) void {\n" ++
        "        _ = ptr;\n    }\n};\n\nfn open(grid: *Grid) void {\n" ++
        "    Ready.ready(grid);\n}\n";

    try testing.expect_quiet(@This(), .zig, handed);
    try expect_count(.zig, called, 1);
}

test "a function named through its parenthesized anonymous container is handed over" {
    const field = "fn open(loop: *Loop) void {\n    loop.add(.{\n        .callback = (struct {\n" ++
        "            fn ready(ud: ?*anyopaque) void {\n                _ = ud;\n" ++
        "            }\n        }).ready,\n    });\n}\n";

    const typed = "fn open(loop: *Loop) void {\n    const callback: Callback = (struct {\n" ++
        "        fn ready(ud: ?*anyopaque) void {\n            _ = ud;\n        }\n" ++
        "    }).ready;\n    loop.add(callback);\n}\n";

    const argument = "fn open(loop: *Loop) void {\n    loop.timer(1, (extern struct {\n" ++
        "        fn ready(ud: ?*anyopaque) void {\n            _ = ud;\n        }\n" ++
        "    }).ready);\n}\n";

    try testing.expect_quiet(@This(), .zig, field);
    try testing.expect_quiet(@This(), .zig, typed);
    try testing.expect_quiet(@This(), .zig, argument);
}

test "a function named through its container by an untyped alias or a call is not handed over" {
    const aliased = "fn open(loop: *Loop) void {\n    const callback = (struct {\n" ++
        "        fn ready(ud: ?*anyopaque) void {\n            _ = ud;\n        }\n" ++
        "    }).ready;\n    loop.add(callback);\n}\n";

    const bare = "fn open(loop: *Loop) void {\n    const callback = struct {\n" ++
        "        fn ready(ud: ?*anyopaque) void {\n            _ = ud;\n        }\n" ++
        "    }.ready;\n    loop.add(callback);\n}\n";

    const called = "fn open(loop: *Loop) void {\n    (struct {\n" ++
        "        fn ready(ud: ?*anyopaque) void {\n            _ = ud;\n        }\n" ++
        "    }).ready(loop);\n}\n";

    try expect_count(.zig, aliased, 1);
    try expect_count(.zig, bare, 1);
    try expect_count(.zig, called, 1);
}

test "an odin procedure type that names its calling convention is a function pointer" {
    const source = "package p\n\nVTable :: struct {\n" ++
        "\tquery: proc \"system\" (this: ^Unknown, out: ^rawptr) -> i32,\n" ++
        "\tdata: ^rawptr,\n}\n";

    try expect_count(.odin, source, 1);
}

test "an odin transmute to a pointer is reported" {
    const source = "package fixture\n\nread :: proc(e: int) -> int {\n" ++
        "    p := transmute(^int)e\n    return p^\n}\n";

    try expect_count(.odin, source, 1);
}

test "a python ctypes pointer is reported" {
    const source = "import ctypes\n\n\ndef read(value: int) -> int:\n" ++
        "    address = ctypes.c_void_p(value)\n    return address.value\n";

    try expect_count(.python, source, 1);
}

test "a python name a def or class declares is no pointer use" {
    const declared = "def POINTER(cls: type) -> type: ...\n\n\nclass c_void_p(object):\n    pass\n";

    const used = "from ctypes import POINTER\n\n\ndef make(cls: type) -> type:\n" ++
        "    return POINTER(cls)\n";

    try testing.expect_quiet(@This(), .python, declared);
    try expect_count(.python, used, 2);
}

test "a go pointer is quiet and an unsafe one is not" {
    const plain = "func read() int {\n\tvar buffer *byte\n\treturn 0\n}\n";
    const unchecked = "func read() int {\n\tvar buffer unsafe.Pointer\n\treturn 0\n}\n";

    try testing.expect_quiet(@This(), .go, plain);
    try expect_count(.go, unchecked, 1);
}

test "a zig pointer reports only where it erases the type" {
    const plain = "const Env = struct {\n    buffer: *const u8,\n};\n";
    const opaque_pointer = "const Env = struct {\n    buffer: *anyopaque,\n};\n";
    const many = "const Env = struct {\n    buffer: [*]u8,\n};\n";

    try testing.expect_quiet(@This(), .zig, plain);
    try expect_count(.zig, opaque_pointer, 1);
    try expect_count(.zig, many, 1);
}

test "an unsafe block and an unsafe declaration read apart" {
    const block = "fn read() {\n    unsafe {\n        step();\n    }\n}\n";
    const declaration = "unsafe impl Send for Reader {\n}\n";

    try testing.expect_quiet(@This(), .rust, block);

    var findings = try testing.analyze(@This(), .rust, declaration);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "declaration") != null);
}

test "a multi-level raw pointer is the pointer depth rule's" {
    const source = "const _: () = assert!(align_of::<*const *const str>() == 8);\n\n" ++
        "fn read(cell: *mut *mut u8, held: *const u8) -> u8 {\n    0\n}\n";

    try expect_count(.rust, source, 1);
}

test "a reference is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn read(buffer: &[u8]) -> u32 {\n    return 0;\n}\n");
}

test "an unsafe declaration anchors past its visibility" {
    const source = "pub(crate) unsafe fn f(p: u32) -> u32 {\n    p\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 1, 1 }});
}
