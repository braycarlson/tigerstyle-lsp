const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const support = @import("support.zig");
const Bindings = scylla.Front.Bindings;
const JavascriptKind = scylla.javascript.Kind;
const Language = scylla.Language;
const PythonKind = scylla.python.Kind;
const Token = scylla.Token;
const scan = scylla.scan;
const alias_binder = " = ";
const alias_opener = "const ";
const alias_stem = alias_opener ++ expectation_stem;
const comment_bytes_max: u32 = 4_096;
const expectation_stem = "expect";
const odin_assert_names = [_][]const u8{ "assert", "ensure" };
const python_declarers = [_][]const u8{ "class", "def" };
const python_fail_declaration = "def fail(";
const python_fail_word = "fail";
const python_receiver = "self.";
const python_test_case_stems = [_][]const u8{ "assert", "fail" };
const python_soft_word = "match";
const testing_prefix = "testing.";
const trivia_count_max: u32 = 8;

const expectation_hashes: [zig_expectations.len]u32 = hashes: {
    var held: [zig_expectations.len]u32 = undefined;

    for (zig_expectations, &held) |name, *hash| hash.* = std.hash.Fnv1a_32.hash(name);

    break :hashes held;
};

const expectation_hash_bits: u64 = bits: {
    var mask: u64 = 0;

    for (expectation_hashes) |hash| mask |= @as(u64, 1) << (hash >> 26);

    break :bits mask;
};

const expectation_lengths: u64 = lengths: {
    var mask: u64 = 0;

    for (zig_expectations) |name| {
        assert(std.mem.startsWith(u8, name, expectation_stem));
        assert(name.len < 64);

        mask |= @as(u64, 1) << name.len;
    }

    break :lengths mask;
};

const zig_expectations = [_][]const u8{
    "expect",
    "expectApproxEqAbs",
    "expectApproxEqRel",
    "expectEqual",
    "expectEqualDeep",
    "expectEqualSentinel",
    "expectEqualSlices",
    "expectEqualStrings",
    "expectError",
    "expectFmt",
    "expectStringEndsWith",
    "expectStringStartsWith",
};

fn calls_after_spaces(source: []const u8, end: u32) bool {
    assert(end <= source.len);

    const call = run_scan(source, end, is_space);

    assert(call >= end);

    return scan.byte_at(source, call) == '(';
}

fn comment_open_before(source: []const u8, end: u32) ?u32 {
    assert(end >= 2);
    assert(end <= source.len);

    const floor = end -| comment_bytes_max;
    const found = std.mem.findLast(u8, source[floor .. end - 1], "/*") orelse return null;
    const opened: u32 = floor + @as(u32, @intCast(found));

    assert(opened >= floor);
    assert(opened + 2 < end);

    return opened;
}

fn is_space(byte: u8) bool {
    return byte == ' ';
}

fn javascript_vocabulary(tokens: []Token) void {
    var chained = false;

    for (tokens) |*token| {
        if (token.exact_kind(JavascriptKind) == .question_dot) {
            token.kind = .{ .punctuation = .dot };
            chained = true;

            continue;
        }

        if (!chained) continue;

        chained = false;

        if (std.meta.activeTag(token.kind) != .keyword) continue;
        if (token.kind.eql(.{ .keyword = .assert })) continue;

        token.kind = .identifier;
    }

    strings_opaque(JavascriptKind, tokens, .{ .end = .template_end, .start = .template_start });
}

fn line_comment_before(source: []const u8, end: u32) ?u32 {
    assert(end <= source.len);

    const floor = end -| comment_bytes_max;

    const line = if (std.mem.findScalarLast(u8, source[floor..end], '\n')) |newline|
        floor + newline + 1
    else
        floor;

    const marked = std.mem.findPos(u8, source[0..end], line, "//") orelse return null;

    assert(marked >= line);
    assert(marked + 2 <= end);

    return @intCast(marked);
}

fn odin_kind(options: struct { source: []const u8, text: []const u8 }, token: Token) Token.Kind {
    assert(token.end() <= options.source.len);

    const end = token.offset + token.length;

    assert(end <= options.source.len);
    assert(options.text.len == token.length);

    if (std.mem.eql(u8, options.text, "for")) return .{
        .keyword = odin_loop_keyword(options.source, end),
    };

    if (std.mem.eql(u8, options.text, "proc")) {
        return .{ .keyword = odin_procedure_keyword(options.source, token.offset) };
    }

    if (token.kind != .identifier) return token.kind;
    if (!scan.word_in(&odin_assert_names, options.text)) return token.kind;
    if (!calls_after_spaces(options.source, end)) return token.kind;
    return .{ .keyword = .assert };
}

fn odin_loop_keyword(source: []const u8, end: u32) Token.Keyword {
    assert(end <= source.len);

    const body = run_scan(source, end, scan.is_ascii_whitespace);

    assert(body >= end);

    if (scan.byte_at(source, body) == '{') return .loop_unbounded;
    return .loop;
}

fn odin_procedure_keyword(source: []const u8, start: u32) Token.Keyword {
    assert(start < source.len);
    assert(std.mem.startsWith(u8, source[start..], "proc"));

    var offset = start;
    var modifiers: u32 = 0;

    while (modifiers < support.modifier_count_max) : (modifiers += 1) {
        offset = trivia_skip_back(source, offset);

        const word = run_scan_back(source, .{ .end = offset, .floor = 0 }, scan.is_identifier_part);
        if (word == offset) break;
        if (word == 0) break;
        if (source[word - 1] != '#') break;

        offset = word - 1;
    }

    assert(offset <= start);

    if (offset < 2) return .lambda;
    if (source[offset - 2] != ':') return .lambda;

    return switch (source[offset - 1]) {
        ':', '=' => .function,
        else => .lambda,
    };
}

fn opens_a_line(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);

    var cursor = offset;

    while (cursor > 0) : (cursor -= 1) {
        const byte = source[cursor - 1];
        if (byte == '\n') return true;
        if (byte == '\r') return true;
        if (!scan.is_ascii_whitespace(byte)) return false;
    }

    assert(cursor == 0);

    return true;
}

fn opens_a_prong(source: []const u8, end: u32) bool {
    assert(end <= source.len);

    const arrow = run_scan(source, end, scan.is_ascii_whitespace);

    assert(arrow >= end);

    if (scan.byte_at(source, arrow) != '=') return false;
    return scan.byte_at(source, arrow + 1) == '>';
}

fn python_declares(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);

    const keyword_end = run_scan_back(source, .{ .end = offset, .floor = 0 }, is_space);

    const keyword = run_scan_back(
        source,
        .{ .end = keyword_end, .floor = 0 },
        scan.is_identifier_part,
    );

    assert(keyword <= keyword_end);
    assert(keyword_end <= offset);

    return scan.word_in(&python_declarers, source[keyword..keyword_end]);
}

fn python_is_assertion(
    source: []const u8,
    options: struct { end: u32, offset: u32 },
    fail_declared: bool,
) bool {
    assert(options.offset < options.end);
    assert(options.end <= source.len);

    const text = source[options.offset..options.end];

    if (!calls_after_spaces(source, options.end)) return false;
    if (python_declares(source, options.offset)) return false;
    if (std.mem.startsWith(u8, text, "assert_")) return true;
    if (!std.mem.endsWith(u8, source[0..options.offset], python_receiver)) return false;
    if (std.mem.eql(u8, text, python_fail_word)) return !fail_declared;
    return python_names_a_test_case_assertion(text);
}

fn opens_a_python_match(source: []const u8, options: struct { end: u32, offset: u32 }) bool {
    assert(options.offset < options.end);
    assert(options.end <= source.len);

    if (!opens_a_line(source, options.offset)) return false;

    const line_end = std.mem.findScalarPos(u8, source, options.end, '\n') orelse source.len;
    const rest = source[options.end..line_end];
    const code = if (std.mem.findScalar(u8, rest, '#')) |hash| rest[0..hash] else rest;
    const trimmed = std.mem.trimEnd(u8, code, " \t\r");

    assert(trimmed.len <= rest.len);

    return std.mem.endsWith(u8, trimmed, ":");
}

fn python_names_a_test_case_assertion(text: []const u8) bool {
    assert(text.len > 0);

    for (python_test_case_stems) |stem| {
        if (!std.mem.startsWith(u8, text, stem)) continue;
        if (text.len == stem.len) return false;
        return std.ascii.isUpper(text[stem.len]);
    }

    return false;
}

fn python_kind(
    options: struct { source: []const u8, text: []const u8 },
    token: Token,
    fail_declared: bool,
) Token.Kind {
    assert(token.end() <= options.source.len);

    const end = token.offset + token.length;

    assert(end <= options.source.len);
    assert(options.text.len == token.length);

    if (std.mem.eql(u8, options.text, python_soft_word)) {
        if (opens_a_python_match(options.source, .{
            .end = end,
            .offset = token.offset,
        })) return .{ .keyword = .match };

        return .identifier;
    }

    if (token.kind != .identifier) return token.kind;

    if (!python_is_assertion(
        options.source,
        .{ .end = end, .offset = token.offset },
        fail_declared,
    )) return token.kind;

    return .{ .keyword = .assert };
}

fn run_scan(source: []const u8, start: u32, comptime holds: fn (u8) bool) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        if (!holds(source[offset])) break;
    }

    assert(offset >= start);
    assert(offset <= source.len);

    return offset;
}

fn run_scan_back(
    source: []const u8,
    options: struct { end: u32, floor: u32 },
    comptime holds: fn (u8) bool,
) u32 {
    assert(options.floor <= options.end);
    assert(options.end <= source.len);

    var offset = options.end;

    while (offset > options.floor) : (offset -= 1) {
        if (!holds(source[offset - 1])) break;
    }

    assert(offset >= options.floor);
    assert(offset <= options.end);

    return offset;
}

fn strings_opaque(
    comptime Kind: type,
    tokens: []Token,
    options: struct { end: Kind, start: Kind },
) void {
    assert(options.start != options.end);
    assert(options.start.is_token());
    assert(options.end.is_token());

    var depth: u32 = 0;

    for (tokens) |*token| {
        const kind = token.exact_kind(Kind);

        if (kind == options.start) depth += 1;
        if (depth == 0) continue;

        assert(depth <= tokens.len);

        token.kind = .string;

        if (kind == options.end) depth -= 1;
    }
}

fn trivia_skip_back(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var offset = start;
    var trivia: u32 = 0;

    while (trivia < trivia_count_max) : (trivia += 1) {
        offset = run_scan_back(source, .{ .end = offset, .floor = 0 }, scan.is_ascii_whitespace);

        const opened = if (std.mem.endsWith(u8, source[0..offset], "*/"))
            comment_open_before(source, offset)
        else
            line_comment_before(source, offset);

        offset = opened orelse return offset;
    }

    assert(offset <= start);

    return offset;
}

fn zig_kind(options: struct { source: []const u8, text: []const u8 }, token: Token) Token.Kind {
    assert(token.end() <= options.source.len);

    const end = token.offset + token.length;

    assert(end <= options.source.len);
    assert(options.text.len == token.length);

    if (std.mem.eql(u8, options.text, "@import")) return .{ .keyword = .import };

    if (std.mem.eql(u8, options.text, "else")) {
        if (opens_a_prong(options.source, end)) return .{ .keyword = .other };
        return .{ .keyword = .branch_else };
    }

    if (token.kind != .identifier) return token.kind;
    if (std.mem.eql(u8, options.text, "assert")) return .{ .keyword = .assert };
    if (token.offset == 0) return token.kind;
    if (options.source[token.offset - 1] != '.') return token.kind;
    if (!scan.word_in(&zig_expectations, options.text)) return token.kind;
    return .{ .keyword = .assert };
}

pub const ExpectationAliases = struct {
    bindings: Bindings,
    declared: Declared,
    found: Found,
    language: Language,
    source: []const u8,
    state: State,

    const Declared = enum {
        absent,
        present,
        unknown,
    };

    const Found = std.bit_set.Integer(zig_expectations.len);

    const State = enum {
        collected,
        uncollected,
    };

    pub fn of(language: Language, source: []const u8, bindings: Bindings) ExpectationAliases {
        assert(source.len <= std.math.maxInt(u32));
        if (bindings != .empty) assert((language == .zig) == (bindings == .zig));

        return .{
            .bindings = bindings,
            .declared = .unknown,
            .found = .empty,
            .language = language,
            .source = source,
            .state = .uncollected,
        };
    }

    pub fn declares_a_name(held: *ExpectationAliases) bool {
        assert(held.source.len <= std.math.maxInt(u32));

        if (held.declared == .unknown) {
            held.declared = if (names_declared(held.bindings)) .present else .absent;
        }

        assert(held.declared != .unknown);

        return held.declared == .present;
    }

    pub fn calls(held: *ExpectationAliases, token: Token) bool {
        assert(token.end() <= held.source.len);

        const source = held.source;
        const end = token.offset + token.length;

        assert(end <= source.len);
        assert(source.len <= std.math.maxInt(u32));

        if (token.kind != .identifier) return false;
        if (token.offset == 0) return false;
        if (!held.declares_a_name()) return false;

        const text = source[token.offset..end];
        const position = expectation_position(text) orelse return false;

        if (source[token.offset - 1] == '.') return false;
        if (!calls_after_spaces(source, end)) return false;
        return held.aliases(position);
    }

    fn aliases(held: *ExpectationAliases, position: usize) bool {
        assert(position < zig_expectations.len);

        if (held.state == .uncollected) held.collect();

        assert(held.state == .collected);

        return held.found.isSet(position);
    }

    fn collect(held: *ExpectationAliases) void {
        var lines = std.mem.splitScalar(u8, held.source, '\n');

        assert(held.state == .uncollected);

        held.state = .collected;

        if (held.language != .zig) return;

        for (0..held.source.len + 1) |_| {
            const line = lines.next() orelse break;
            const trimmed = scan.trim_ascii(line);
            if (!std.mem.startsWith(u8, trimmed, alias_stem)) continue;

            inline for (zig_expectations, 0..) |name, position| {
                if (declares_the_alias(.{ .line = trimmed, .name = name })) {
                    if (std.mem.find(u8, line, testing_prefix ++ name ++ ";") != null) {
                        held.found.set(position);
                    }
                }
            }
        }

        assert(held.found.count() <= zig_expectations.len);
    }
};

pub fn opens_an_expectation(source: []const u8, token: Token) bool {
    assert(token.offset + token.length <= source.len);
    assert(expectation_lengths != 0);

    if (token.length >= 64) return false;
    if (expectation_lengths & (@as(u64, 1) << @intCast(token.length)) == 0) return false;
    return std.mem.startsWith(u8, source[token.offset..], expectation_stem);
}

fn names_declared(bindings: Bindings) bool {
    const semantic = switch (bindings) {
        .empty => return true,
        .zig => |held| held,
        .go, .javascript, .odin, .python, .rust => return false,
    };

    assert(semantic.binding_slice().len == semantic.count());

    for (semantic.binding_slice()) |binding| {
        const bit = @as(u64, 1) << @intCast(binding.name_hash >> 26);

        assert(binding.scope < semantic.scope_count());

        if (expectation_hash_bits & bit == 0) continue;

        for (expectation_hashes) |hash| {
            if (binding.name_hash == hash) return true;
        }
    }

    return false;
}

fn expectation_position(text: []const u8) ?usize {
    if (!std.mem.startsWith(u8, text, expectation_stem)) return null;

    assert(text.len >= expectation_stem.len);

    for (zig_expectations, 0..) |name, position| {
        if (std.mem.eql(u8, name, text)) return position;
    }

    return null;
}

fn declares_the_alias(options: struct { line: []const u8, name: []const u8 }) bool {
    assert(options.name.len > 0);
    assert(std.mem.findScalar(u8, options.line, '\n') == null);

    if (!std.mem.startsWith(u8, options.line, alias_opener)) return false;

    const rest = options.line[alias_opener.len..];
    if (!std.mem.startsWith(u8, rest, options.name)) return false;
    return std.mem.startsWith(u8, rest[options.name.len..], alias_binder);
}

pub fn vocabulary(language: Language, source: []const u8, tokens: []Token) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    switch (language) {
        .javascript, .typescript => return javascript_vocabulary(tokens),
        .odin, .python, .zig => {},
        else => return,
    }

    const fail_declared = language == .python and
        std.mem.find(u8, source, python_fail_declaration) != null;

    for (tokens) |*token| {
        assert(token.offset + token.length <= source.len);

        const text = source[token.offset..][0..token.length];

        token.kind = switch (language) {
            .odin => odin_kind(.{ .source = source, .text = text }, token.*),
            .python => python_kind(.{ .source = source, .text = text }, token.*, fail_declared),
            .zig => zig_kind(.{ .source = source, .text = text }, token.*),
            else => unreachable,
        };
    }

    if (language == .python) strings_opaque(PythonKind, tokens, .{
        .end = .f_string_end,
        .start = .f_string_start,
    });
}

const Classified = struct {
    count: u32,
    held: [token_count_test]Token,

    fn of(language: Language, source: []const u8) !Classified {
        var tokens: scylla.Tokens = try .init(std.testing.allocator, token_count_test);
        defer tokens.deinit(std.testing.allocator);

        try tokens.lex(.of(language), source);

        var classified: Classified = .{ .count = tokens.count(), .held = undefined };

        @memcpy(classified.held[0..classified.count], tokens.slice());
        vocabulary(language, source, classified.held[0..classified.count]);

        return classified;
    }

    fn slice(classified: *const Classified) []const Token {
        return classified.held[0..classified.count];
    }
};

const token_count_test: u32 = 256;

fn kinds_of(language: Language, source: []const u8, words: []const []const u8) ![8]Token.Kind {
    const classified = try Classified.of(language, source);
    var kinds: [8]Token.Kind = @splat(.newline);

    for (words, 0..) |word, index| {
        for (classified.slice()) |token| {
            if (!std.mem.eql(u8, source[token.offset..][0..token.length], word)) continue;

            kinds[index] = token.kind;

            break;
        }
    }

    return kinds;
}

test "a python assertion is named by its word or by its receiver" {
    const source = "assert_equal(a)\nself.assertTrue(b)\nself.failUnless(c)\nassertFalse(d)\n" ++
        "that.assertIn(e)\nmatch value:\n    case 1:\n        pass\nre.match(f)\n";

    const kinds = try kinds_of(.python, source, &.{
        "assert_equal",
        "assertTrue",
        "failUnless",
        "assertFalse",
        "assertIn",
        "match",
    });

    try std.testing.expect(kinds[0].eql(.{ .keyword = .assert }));
    try std.testing.expect(kinds[1].eql(.{ .keyword = .assert }));
    try std.testing.expect(kinds[2].eql(.{ .keyword = .assert }));
    try std.testing.expect(kinds[3].eql(.identifier));
    try std.testing.expect(kinds[4].eql(.identifier));
    try std.testing.expect(kinds[5].eql(.{ .keyword = .match }));
}

test "a python function or class declared with an assertion's name is no assertion" {
    const source = "def assert_equal(a, b):\n    pass\n\n\nclass assert_type(object):\n" ++
        "    pass\n\n\nassert_same(a)\n";

    const kinds = try kinds_of(.python, source, &.{ "assert_equal", "assert_type", "assert_same" });

    try std.testing.expect(kinds[0].eql(.identifier));
    try std.testing.expect(kinds[1].eql(.identifier));
    try std.testing.expect(kinds[2].eql(.{ .keyword = .assert }));
}

test "a python receiver call is an assertion only in unittest's spelling" {
    const source = "self.assertEqual(a)\nself.failUnless(b)\nself.fail(c)\n" ++
        "self.fail_login(d)\nself.failureException(e)\nself.asserted(f)\n";

    const kinds = try kinds_of(.python, source, &.{
        "assertEqual",
        "failUnless",
        "fail",
        "fail_login",
        "failureException",
        "asserted",
    });

    try std.testing.expect(kinds[0].eql(.{ .keyword = .assert }));
    try std.testing.expect(kinds[1].eql(.{ .keyword = .assert }));
    try std.testing.expect(kinds[2].eql(.{ .keyword = .assert }));
    try std.testing.expect(kinds[3].eql(.identifier));
    try std.testing.expect(kinds[4].eql(.identifier));
    try std.testing.expect(kinds[5].eql(.identifier));
}

test "a python match that opens a continuation line is a name" {
    const source = "check(\n    match=pattern,\n)\nmatch value:  # dispatch\n    case 1:\n" ++
        "        pass\n";

    const kinds = try kinds_of(.python, source, &.{"match"});
    const classified = try Classified.of(.python, source);
    var keywords: u32 = 0;

    for (classified.slice()) |token| {
        if (token.kind.eql(.{ .keyword = .match })) keywords += 1;
    }

    try std.testing.expect(kinds[0].eql(.identifier));
    try std.testing.expectEqual(@as(u32, 1), keywords);
}

test "a python fail the file declares is its own method rather than unittest's" {
    const source = "class Checker:\n    def fail(self, message, context):\n" ++
        "        self.errors.append(message)\n\n    def check(self, node):\n" ++
        "        self.fail(\"bad\", node)\n        self.assertValid(node)\n";

    const kinds = try kinds_of(.python, source, &.{"assertValid"});
    const classified = try Classified.of(.python, source);
    var asserted: u32 = 0;

    for (classified.slice()) |token| {
        if (token.kind.eql(.{ .keyword = .assert })) asserted += 1;
    }

    try std.testing.expect(kinds[0].eql(.{ .keyword = .assert }));
    try std.testing.expectEqual(@as(u32, 1), asserted);
}

test "a zig assertion, expectation, import and prong else keep their lint kinds" {
    const source = "const std = @import(\"std\");\nfn f(x: u8) void {\n    assert(x > 0);\n" ++
        "    try std.testing.expectEqual(1, x);\n    switch (x) {\n        else => {},\n    }\n}\n";

    const kinds = try kinds_of(.zig, source, &.{ "@import", "assert", "expectEqual", "else" });

    try std.testing.expect(kinds[0].eql(.{ .keyword = .import }));
    try std.testing.expect(kinds[1].eql(.{ .keyword = .assert }));
    try std.testing.expect(kinds[2].eql(.{ .keyword = .assert }));
    try std.testing.expect(kinds[3].eql(.{ .keyword = .other }));
}

test "a zig expectation called through a file alias is found by its call" {
    const source = "const expect = std.testing.expect;\nfn f(x: u8) !void {\n" ++
        "    try expect(x > 0);\n}\n";

    const classified = try Classified.of(.zig, source);
    var aliases: ExpectationAliases = .of(.zig, source, .empty);
    var aliased: u32 = 0;

    for (classified.slice()) |token| {
        if (aliases.calls(token)) aliased += 1;
    }

    try std.testing.expectEqual(@as(u32, 1), aliased);
}

test "an odin loop, procedure and assertion keep their lint kinds" {
    const source = "run :: proc(v: bool) {\n\tensure(v)\n\tfor {\n\t}\n" ++
        "\tcallback := call(proc() {})\n}\n";

    const kinds = try kinds_of(.odin, source, &.{ "proc", "ensure", "for" });

    try std.testing.expect(kinds[0].eql(.{ .keyword = .function }));
    try std.testing.expect(kinds[1].eql(.{ .keyword = .assert }));
    try std.testing.expect(kinds[2].eql(.{ .keyword = .loop_unbounded }));
}
