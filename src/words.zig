const std = @import("std");
const assert = std.debug.assert;
const scan = @import("scan.zig");

const Words = struct {
    name: []const u8,
    offset: u32,

    pub fn next(words: *Words) ?[]const u8 {
        const name = words.name;

        assert(words.offset <= name.len);

        while (words.offset < name.len) : (words.offset += 1) {
            if (name[words.offset] != '_') break;
        }

        if (words.offset == name.len) return null;

        const start = words.offset;
        var cut = start + 1;

        assert(name[start] != '_');

        while (cut < name.len) : (cut += 1) {
            if (name[cut] == '_') break;
            if (is_word_break(name, cut)) break;
        }

        assert(cut > start);
        assert(cut <= name.len);

        words.offset = cut;

        return name[start..cut];
    }
};

pub fn word_parts(name: []const u8) Words {
    assert(name.len <= std.math.maxInt(u32));

    return .{ .name = name, .offset = 0 };
}

fn is_word_break(name: []const u8, cut: u32) bool {
    assert(cut > 0);
    assert(cut < name.len);

    const current = name[cut];
    const before = name[cut - 1];

    if (!std.ascii.isUpper(current)) return false;
    if (std.ascii.isLower(before)) return true;

    const follows = scan.byte_at(name, cut + 1) orelse return false;
    if (!std.ascii.isLower(follows)) return false;
    if (std.ascii.isDigit(before)) return true;
    if (!std.ascii.isUpper(before)) return false;
    if (follows != 'v') return true;

    const version = scan.byte_at(name, cut + 2) orelse return true;
    return !std.ascii.isDigit(version);
}

fn parts_expect(name: []const u8, expected: []const []const u8) !void {
    var words = word_parts(name);

    for (expected) |part| {
        const word = words.next() orelse return error.TestUnexpectedResult;

        try std.testing.expectEqualStrings(part, word);
    }

    const rest = words.next();

    try std.testing.expectEqual(null, rest);
}

test "a name splits on underscores and camel boundaries" {
    try parts_expect("heap_bytes_live", &.{ "heap", "bytes", "live" });
    try parts_expect("HTTPServerName", &.{ "HTTP", "Server", "Name" });
    try parts_expect("__leading", &.{"leading"});
    try parts_expect("heldValueMax", &.{ "held", "Value", "Max" });
    try parts_expect("___", &.{});
    try parts_expect("", &.{});
    try parts_expect("POWER_SIGN", &.{ "POWER", "SIGN" });
    try parts_expect("HTTPS_KEY", &.{ "HTTPS", "KEY" });
    try parts_expect("CONTEXT_TYPE", &.{ "CONTEXT", "TYPE" });
}

test "a version suffix stays with its acronym" {
    try parts_expect("IPv4Address", &.{ "IPv4", "Address" });
    try parts_expect("parseIPv4Address", &.{ "parse", "IPv4", "Address" });
    try parts_expect("myAPIv2Client", &.{ "my", "APIv2", "Client" });
    try parts_expect("IOEvent", &.{ "IO", "Event" });
}

test "a digit run ends its word before a capitalized word" {
    try parts_expect("Base64Encode", &.{ "Base64", "Encode" });
    try parts_expect("HTTP2Server", &.{ "HTTP2", "Server" });
    try parts_expect("Point2D", &.{"Point2D"});
    try parts_expect("Vec3DArray", &.{ "Vec3D", "Array" });
}
