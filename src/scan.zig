const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Punctuation = scylla.Token.Punctuation;
const Span = scylla.Span;

pub const PunctuationScan = struct {
    punctuation: Punctuation,
    length: u32,
};

pub const Replacement = struct {
    from: u8,
    to: u8,
};

const ScalarRange = struct {
    first: u21,
    last: u21,
};

pub const ascii_whitespace = " \t\n\x0c\r";
pub const decimal_bytes_max: u32 = 20;
const byte_order_mark = "\xef\xbb\xbf";
const group_peel_max: u32 = 4;
const tab_columns: u32 = 4;

const unicode_spaces = [_]ScalarRange{
    .{ .first = 0x0085, .last = 0x0085 },
    .{ .first = 0x00a0, .last = 0x00a0 },
    .{ .first = 0x1680, .last = 0x1680 },
    .{ .first = 0x2000, .last = 0x200a },
    .{ .first = 0x2028, .last = 0x2029 },
    .{ .first = 0x202f, .last = 0x202f },
    .{ .first = 0x205f, .last = 0x205f },
    .{ .first = 0x3000, .last = 0x3000 },
    .{ .first = 0xfeff, .last = 0xfeff },
};

comptime {
    assert(decimal_width(std.math.maxInt(u64)) == decimal_bytes_max);

    for (unicode_spaces[0 .. unicode_spaces.len - 1], unicode_spaces[1..]) |range, next| {
        assert(range.first <= range.last);
        assert(range.last < next.first);
    }
}

pub fn balanced(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    var braces: u32 = 0;
    var brackets: u32 = 0;
    var parens: u32 = 0;

    for (text) |byte| {
        switch (byte) {
            '{' => braces += 1,
            '[' => brackets += 1,
            '(' => parens += 1,
            '}' => braces = std.math.sub(u32, braces, 1) catch return false,
            ']' => brackets = std.math.sub(u32, brackets, 1) catch return false,
            ')' => parens = std.math.sub(u32, parens, 1) catch return false,
            else => {},
        }
    }

    if (braces > 0) return false;
    if (brackets > 0) return false;
    return parens == 0;
}

pub fn byte_at(source: []const u8, offset: u32) ?u8 {
    if (offset < source.len) return source[offset];
    return null;
}

pub fn contains_folded(haystack: []const u8, needle: []const u8) bool {
    assert(haystack.len <= std.math.maxInt(u32));

    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;

    for (0..haystack.len - needle.len + 1) |start| {
        if (starts_with_folded(haystack[start..], needle)) return true;
    }

    return false;
}

pub fn decimal_read(text: []const u8) ?u64 {
    if (text.len == 0) return null;

    if (text.len > 1) {
        if (text[0] == '0') return null;
    }

    var value: u64 = 0;

    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;

        const shifted = std.math.mul(u64, value, 10) catch return null;

        value = std.math.add(u64, shifted, byte - '0') catch return null;
    }

    assert(decimal_width(value) == text.len);
    assert(text.len <= decimal_bytes_max);

    return value;
}

pub fn decimal_write(digits: []u8, value: u64) u32 {
    assert(digits.len >= decimal_bytes_max);

    var remaining = value;
    var length: u32 = 0;

    for (digits[0..decimal_bytes_max]) |*digit| {
        digit.* = '0' + @as(u8, @intCast(remaining % 10));
        remaining = @divFloor(remaining, 10);
        length += 1;

        if (remaining == 0) break;
    }

    assert(remaining == 0);
    assert(length == decimal_width(value));

    std.mem.reverse(u8, digits[0..length]);

    return length;
}

pub fn find(haystack: []const u8, needle: []const u8) ?u32 {
    assert(haystack.len <= std.math.maxInt(u32));

    if (needle.len == 0) return null;

    const found = std.mem.find(u8, haystack, needle) orelse return null;

    assert(found + needle.len <= haystack.len);

    return @intCast(found);
}

pub fn find_word(haystack: []const u8, name: []const u8) bool {
    assert(haystack.len <= std.math.maxInt(u32));

    if (name.len == 0) return false;

    var offset: u32 = 0;

    while (offset + name.len <= haystack.len) {
        const at = offset + (find(haystack[offset..], name) orelse return false);

        assert(at >= offset);

        const end = at + name.len;
        const opened = at == 0 or !is_word_byte(haystack[at - 1]);
        const closed = end == haystack.len or !is_word_byte(haystack[end]);

        assert(end <= haystack.len);

        if (opened) {
            if (closed) return true;
        }

        offset = at + 1;
    }

    return false;
}

pub fn gap_is_blank(source: []const u8, gap: Span) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(gap.end() <= source.len);

    var offset = gap.offset;

    if (offset == 0) {
        if (std.mem.startsWith(u8, source, byte_order_mark)) {
            offset += @min(byte_order_mark.len, gap.length);
        }
    }

    while (offset < gap.end()) {
        if (std.ascii.isWhitespace(source[offset])) {
            offset += 1;

            continue;
        }

        const width = whitespace_width(source, offset);
        if (width == 0) return false;

        offset += width;
    }

    assert(offset >= gap.end());

    return true;
}

pub fn indent_width(line: []const u8) u32 {
    var width: u32 = 0;

    for (line) |byte| {
        if (byte == '\t') {
            width += tab_columns - width % tab_columns;
        } else {
            if (!is_ascii_whitespace(byte)) break;

            width += 1;
        }
    }

    assert(width <= line.len * tab_columns);

    return width;
}

pub fn is_ascii_whitespace(byte: u8) bool {
    const result: bool = switch (byte) {
        ' ', '\t', '\n', 0x0c, '\r' => true,
        else => false,
    };

    if (result) assert(std.ascii.isWhitespace(byte));

    return result;
}

pub fn is_identifier_part(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return byte == '_';
}

pub fn line_scan(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    const end: u32 = if (std.mem.findScalarPos(u8, source, start, '\n')) |found|
        @intCast(found)
    else
        @intCast(source.len);

    assert(end >= start);
    if (end < source.len) assert(source[end] == '\n');

    return end;
}

pub fn line_start_of(source: []const u8, offset: u32) u32 {
    const end: u32 = @intCast(@min(offset, source.len));

    const start: u32 = if (std.mem.findScalarLast(u8, source[0..end], '\n')) |found|
        @intCast(found + 1)
    else
        0;

    assert(start <= end);

    if (start > 0) assert(source[start - 1] == '\n');

    return start;
}

pub fn punctuation_of(source: []const u8, start: u32) PunctuationScan {
    assert(start < source.len);

    const byte = source[start];

    if (byte >= 0x80) {
        const width: u32 = if (scalar_width(source, start)) |held| held else 1;

        assert(start + width <= source.len);

        return .{ .punctuation = .other, .length = width };
    }

    const next = byte_at(source, start + 1) orelse 0;
    const third = byte_at(source, start +| 2) orelse 0;

    if (third == '=') {
        if (is_triple_assignment(byte, next)) return .{ .punctuation = .other, .length = 3 };
    }

    if (pair_of(byte, next)) |punctuation| return .{ .punctuation = punctuation, .length = 2 };

    const single: Punctuation = switch (byte) {
        '!' => .bang,
        '&' => .ampersand,
        '(' => .paren_open,
        ')' => .paren_close,
        '*' => .star,
        ',' => .comma,
        '.' => .dot,
        '/' => .slash,
        ':' => .colon,
        ';' => .semicolon,
        '<' => .less,
        '=' => .assign,
        '>' => .greater,
        '[' => .bracket_open,
        ']' => .bracket_close,
        else => .other,
    };

    return .{ .punctuation = single, .length = 1 };
}

pub fn stripped_group(text: []const u8) []const u8 {
    var stripped = trim_ascii(text);

    for (0..group_peel_max) |_| {
        if (stripped.len < 2) break;
        if (stripped[0] != '(') break;
        if (stripped[stripped.len - 1] != ')') break;

        const inner = stripped[1 .. stripped.len - 1];
        if (!balanced(inner)) break;

        stripped = trim_ascii(inner);
    }

    assert(stripped.len <= text.len);

    if (stripped.len > 0) assert(!is_ascii_whitespace(stripped[0]));

    return stripped;
}

pub fn translated(target: []u8, source: []const u8, replacement: Replacement) ?u32 {
    assert(source.len <= std.math.maxInt(u32));

    if (target.len < source.len) return null;

    for (source, target[0..source.len]) |byte, *slot| {
        slot.* = if (byte == replacement.from) replacement.to else byte;
    }

    if (replacement.from != replacement.to) {
        assert(std.mem.findScalar(u8, target[0..source.len], replacement.from) == null);
    }

    return @intCast(source.len);
}

pub fn trim_ascii(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, ascii_whitespace);

    assert(trimmed.len <= text.len);
    if (trimmed.len > 0) assert(!is_ascii_whitespace(trimmed[0]));
    if (trimmed.len > 0) assert(!is_ascii_whitespace(trimmed[trimmed.len - 1]));

    return trimmed;
}

pub fn utf8_or(bytes: []const u8, fallback: []const u8) []const u8 {
    assert(std.unicode.utf8ValidateSlice(fallback));

    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    return fallback;
}

pub fn whitespace_scan(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        if (!is_blank(source[offset])) break;
    }

    if (offset == start) {
        if (start < source.len) return start + whitespace_width(source, start);
    }

    assert(offset <= source.len);
    if (offset > start) assert(is_blank(source[start]));

    return offset;
}

pub fn word_listed(words: []const []const u8, word: []const u8) bool {
    for (words, 0..) |listed, index| {
        if (index > 0) assert(std.mem.order(u8, words[index - 1], listed) != .gt);

        if (std.mem.eql(u8, listed, word)) return true;
    }

    return false;
}

pub fn word_in(comptime words: []const []const u8, word: []const u8) bool {
    comptime assert(words.len > 0);

    const map = comptime std.StaticStringMap(void).initComptime(pairs_of(words));
    return map.has(word);
}

fn decimal_width(value: u64) u32 {
    var digits: u32 = 1;
    var remaining = @divFloor(value, 10);

    while (remaining > 0) : (digits += 1) {
        remaining = @divFloor(remaining, 10);
    }

    assert(digits <= decimal_bytes_max);

    if (digits > 1) assert(value >= std.math.pow(u64, 10, digits - 1));
    if (digits < decimal_bytes_max) assert(value < std.math.pow(u64, 10, digits));

    return digits;
}

fn is_blank(byte: u8) bool {
    if (byte == '\n') return false;
    if (byte == '\r') return false;
    return std.ascii.isWhitespace(byte);
}

fn is_triple_assignment(byte: u8, next: u8) bool {
    if (byte == next) {
        return switch (byte) {
            '<', '>', '*', '/' => true,
            else => false,
        };
    }

    return switch (byte) {
        '+', '-', '*' => next == '%' or next == '|',
        else => false,
    };
}

fn is_unicode_space(scalar: u21) bool {
    assert(scalar >= 0x80);

    for (unicode_spaces) |range| {
        if (scalar < range.first) return false;
        if (scalar <= range.last) return true;
    }

    return false;
}

fn is_word_byte(byte: u8) bool {
    if (byte >= 0x80) return true;
    return is_identifier_part(byte);
}

fn pair_of(byte: u8, next: u8) ?Punctuation {
    if (next == '=') {
        return switch (byte) {
            '=' => .equal,
            '>' => .greater_equal,
            '<' => .less_equal,
            '!' => .not_equal,
            '+', '-', '*', '/', '%', '&', '|', '^' => .other,
            else => null,
        };
    }

    return switch (byte) {
        '&' => if (next == '&') .ampersand_double else null,
        '-' => if (next == '>') .arrow else null,
        '=' => if (next == '>') .other else null,
        '|' => if (next == '|') .bar_double else null,
        else => null,
    };
}

fn pairs_of(comptime words: []const []const u8) [words.len]struct { []const u8 } {
    var pairs: [words.len]struct { []const u8 } = undefined;

    for (words, &pairs) |word, *pair| {
        pair.* = .{word};
    }

    return pairs;
}

fn scalar_decoded(source: []const u8, offset: u32) ?u21 {
    const width = scalar_width(source, offset) orelse return null;
    const bytes = source[offset..][0..width];

    const value = switch (width) {
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => unreachable,
    } catch return null;

    assert(value >= 0x80);

    return value;
}

fn scalar_width(source: []const u8, offset: u32) ?u3 {
    assert(offset < source.len);
    assert(source[offset] >= 0x80);

    const width = std.unicode.utf8ByteSequenceLength(source[offset]) catch return null;
    if (width > source.len - offset) return null;
    if (width < 2) return null;

    const bytes = source[offset..][0..width];

    const valid = switch (width) {
        2 => if (std.unicode.utf8Decode2(bytes[0..2].*)) |_| true else |_| false,
        3 => if (std.unicode.utf8Decode3(bytes[0..3].*)) |_| true else |_| false,
        4 => if (std.unicode.utf8Decode4(bytes[0..4].*)) |_| true else |_| false,
        else => unreachable,
    };

    if (!valid) return null;

    assert(width <= 4);

    return width;
}

fn starts_with_folded(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;

    for (text[0..prefix.len], prefix) |byte, expected| {
        if (std.ascii.toLower(byte) != expected) return false;
    }

    return true;
}

fn whitespace_width(source: []const u8, offset: u32) u32 {
    assert(offset < source.len);

    const byte = source[offset];
    if (byte < 0x80) return @intFromBool(std.ascii.isWhitespace(byte));

    const value = scalar_decoded(source, offset) orelse return 0;
    const width: u32 = if (is_unicode_space(value)) scalar_width(source, offset).? else 0;

    assert(width <= 3);
    assert(offset + width <= source.len);

    return width;
}

test balanced {
    try std.testing.expect(balanced("f(a[0]) { }"));
    try std.testing.expect(balanced(""));
    try std.testing.expect(!balanced("f(a"));
    try std.testing.expect(!balanced("a)"));
    try std.testing.expect(!balanced("(]"));
}

test byte_at {
    try std.testing.expectEqual(@as(?u8, 'b'), byte_at("ab", 1));
    try std.testing.expectEqual(@as(?u8, null), byte_at("ab", 2));
}

test contains_folded {
    try std.testing.expect(contains_folded("// Code generated. DO NOT EDIT.", "do not edit"));
    try std.testing.expect(!contains_folded("do not", "do not edit"));
    try std.testing.expect(!contains_folded("anything", ""));
    try std.testing.expect(starts_with_folded("Content-Length: 7", "content-length:"));
    try std.testing.expect(!starts_with_folded("abc", "ABC"));
}

test decimal_read {
    try std.testing.expectEqual(0, decimal_read("0"));
    try std.testing.expectEqual(1_024, decimal_read("1024"));
    try std.testing.expectEqual(std.math.maxInt(u64), decimal_read("18446744073709551615"));
    try std.testing.expectEqual(null, decimal_read(""));
    try std.testing.expectEqual(null, decimal_read("01"));
    try std.testing.expectEqual(null, decimal_read("1_0"));
    try std.testing.expectEqual(null, decimal_read("-1"));
    try std.testing.expectEqual(null, decimal_read("18446744073709551616"));
}

test decimal_write {
    const values = [_]u64{ 0, 9, 10, 99, 100, 1_000_000, std.math.maxInt(u64) };
    var digits: [decimal_bytes_max]u8 = undefined;

    for (values) |value| {
        const length = decimal_write(&digits, value);

        try std.testing.expectEqual(decimal_width(value), length);
        try std.testing.expectEqual(value, decimal_read(digits[0..length]));
    }
}

test find {
    try std.testing.expectEqual(@as(?u32, 2), find("a.len()", "len"));
    try std.testing.expectEqual(@as(?u32, null), find("abc", ""));
    try std.testing.expectEqual(@as(?u32, null), find("abc", "d"));
}

test find_word {
    try std.testing.expect(find_word("let len = 0;", "len"));
    try std.testing.expect(find_word("len", "len"));
    try std.testing.expect(find_word("a.len()", "len"));
    try std.testing.expect(!find_word("let length = 0;", "len"));
    try std.testing.expect(!find_word("olen", "len"));
    try std.testing.expect(!find_word("", "len"));
    try std.testing.expect(!find_word("len", ""));
    try std.testing.expect(find_word("held(value)", "value"));
    try std.testing.expect(!find_word("held(values)", "value"));
    try std.testing.expect(!find_word("held(revalue)", "value"));
}

test gap_is_blank {
    const source = "\xef\xbb\xbf  \u{00a0}\n x";

    try std.testing.expect(gap_is_blank(source, .{ .offset = 0, .length = 5 }));
    try std.testing.expect(gap_is_blank(source, .{ .offset = 0, .length = 8 }));
    try std.testing.expect(!gap_is_blank(source, .{ .offset = 0, .length = 10 }));
    try std.testing.expect(gap_is_blank(source, .{ .offset = 3, .length = 0 }));
    try std.testing.expect(!gap_is_blank("\u{00e4}", .{ .offset = 0, .length = 2 }));
}

test indent_width {
    try std.testing.expectEqual(4, indent_width("    let x = 1;"));
    try std.testing.expectEqual(4, indent_width("\tlet x = 1;"));
    try std.testing.expectEqual(4, indent_width("  \tlet x = 1;"));
    try std.testing.expectEqual(8, indent_width("\t\tlet x = 1;"));
    try std.testing.expectEqual(0, indent_width("let x = 1;"));
    try std.testing.expectEqual(4, indent_width("    "));
    try std.testing.expectEqual(0, indent_width(""));
}

test is_ascii_whitespace {
    try std.testing.expect(is_ascii_whitespace('\r'));
    try std.testing.expect(!is_ascii_whitespace(0x0b));
    try std.testing.expect(!is_ascii_whitespace('x'));
}

test is_identifier_part {
    try std.testing.expect(is_identifier_part('_'));
    try std.testing.expect(is_identifier_part('5'));
    try std.testing.expect(!is_identifier_part('$'));
    try std.testing.expect(!is_identifier_part(0xc3));
}

test line_scan {
    try std.testing.expectEqual(3, line_scan("one\ntwo", 0));
    try std.testing.expectEqual(7, line_scan("one\ntwo", 4));
    try std.testing.expectEqual(0, line_scan("", 0));
}

test line_start_of {
    try std.testing.expectEqual(0, line_start_of("one\ntwo", 2));
    try std.testing.expectEqual(0, line_start_of("one\ntwo", 3));
    try std.testing.expectEqual(4, line_start_of("one\ntwo", 4));
    try std.testing.expectEqual(4, line_start_of("one\ntwo", 6));
    try std.testing.expectEqual(4, line_start_of("one\ntwo", 99));
    try std.testing.expectEqual(0, line_start_of("", 0));
}

test punctuation_of {
    const expect = std.testing.expectEqual;
    const other: PunctuationScan = .{ .punctuation = .other, .length = 1 };
    const wide: PunctuationScan = .{ .punctuation = .other, .length = 3 };
    const widest: PunctuationScan = .{ .punctuation = .other, .length = 4 };
    const compound = [_][]const u8{ "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=" };
    const triple = [_][]const u8{ "<<=", ">>=", "**=", "//=", "+%=", "-%=", "*%=", "+|=" };
    const double: PunctuationScan = .{ .punctuation = .other, .length = 2 };

    for (compound) |operator| try expect(double, punctuation_of(operator, 0));
    for (triple) |operator| try expect(wide, punctuation_of(operator, 0));

    try expect(PunctuationScan{ .punctuation = .less, .length = 1 }, punctuation_of("<<", 0));
    try expect(PunctuationScan{ .punctuation = .star, .length = 1 }, punctuation_of("**", 0));
    try expect(PunctuationScan{ .punctuation = .equal, .length = 2 }, punctuation_of("==", 0));
    try expect(other, punctuation_of("+%", 0));
    try expect(other, punctuation_of("~=", 0));
    try expect(wide, punctuation_of("\u{2192}", 0));
    try expect(widest, punctuation_of("\u{1f600}", 0));
    try expect(other, punctuation_of("\xff=", 0));
    try expect(other, punctuation_of("\xe2\x80", 0));
}

test stripped_group {
    try std.testing.expectEqualStrings("a", stripped_group("((a))"));
    try std.testing.expectEqualStrings("a", stripped_group("  ( a ) "));
    try std.testing.expectEqualStrings("(a) + (b)", stripped_group("(a) + (b)"));
    try std.testing.expectEqualStrings("a", stripped_group("a"));
}

test translated {
    var target: [8]u8 = @splat(0);
    var empty: [0]u8 = .{};

    try std.testing.expectEqual(5, translated(&target, "a_b_c", .{ .from = '_', .to = '-' }));
    try std.testing.expectEqualStrings("a-b-c", target[0..5]);
    try std.testing.expectEqual(0, translated(&target, "", .{ .from = '_', .to = '-' }));
    const digits: Replacement = .{ .from = '1', .to = '2' };

    try std.testing.expectEqual(null, translated(&target, "123456789", digits));
    try std.testing.expectEqual(null, translated(&empty, "a", .{ .from = 'a', .to = 'b' }));
}

test trim_ascii {
    try std.testing.expectEqualStrings("a b", trim_ascii(" \ta b\r\n"));
    try std.testing.expectEqualStrings("\x0ba", trim_ascii("\x0ba "));
    try std.testing.expectEqualStrings("", trim_ascii("  "));
}

test utf8_or {
    try std.testing.expectEqualStrings("path", utf8_or("path", "<path>"));
    try std.testing.expectEqualStrings("<path>", utf8_or(&.{ 0xff, 0xfe }, "<path>"));
}

test whitespace_scan {
    try std.testing.expectEqual(4, whitespace_scan("    x", 0));
    try std.testing.expectEqual(3, whitespace_scan("\t\t x", 0));
    try std.testing.expectEqual(0, whitespace_scan("x", 0));
    try std.testing.expectEqual(4, whitespace_scan("    ", 0));
    try std.testing.expectEqual(2, whitespace_scan("  \n  ", 0));
    try std.testing.expectEqual(0, whitespace_scan("", 0));
    try std.testing.expectEqual(2, whitespace_scan("  x", 2));
    try std.testing.expectEqual(1, whitespace_scan("\n", 0));
    try std.testing.expectEqual(2, whitespace_scan("\u{00a0}x", 0));
    try std.testing.expectEqual(3, whitespace_scan("\u{2028}x", 0));
    try std.testing.expectEqual(3, whitespace_scan("\u{feff}x", 0));
    try std.testing.expectEqual(0, whitespace_scan("\u{00e4}x", 0));
    try std.testing.expectEqual(0, whitespace_scan("\u{2013}x", 0));
}

test word_in {
    try std.testing.expect(word_in(&.{ "as", "satisfies" }, "satisfies"));
    try std.testing.expect(!word_in(&.{ "as", "satisfies" }, "a"));
}

test word_listed {
    const words = [_][]const u8{ "alpha", "beta", "gamma" };

    try std.testing.expect(word_listed(&words, "beta"));
    try std.testing.expect(!word_listed(&words, "delta"));
    try std.testing.expect(!word_listed(&.{}, "alpha"));
}
