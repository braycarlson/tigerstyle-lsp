const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Conventions = @import("conventions.zig");
const Language = scylla.Language;
const SourceType = scylla.SourceType;

const Set = std.EnumSet(Language);

pub const linted = [_]Language{
    .go,
    .javascript,
    .odin,
    .python,
    .rust,
    .typescript,
    .zig,
};

pub const linted_set: Set = .initMany(&linted);

comptime {
    assert(linted_set.count() == linted.len);
    assert(!linted_set.contains(.css));
    assert(!linted_set.contains(.markup));

    for (linted[1..], 0..) |language, index| {
        assert(@backingInt(linted[index]) < @backingInt(language));
    }

    for (linted) |language| assert(language.lexes());
}

pub fn bit(language: Language) u6 {
    assert(linted_set.contains(language));

    const index = @backingInt(language);

    assert(index < @bitSizeOf(u64));

    return @intCast(index);
}

pub fn of_name(name: []const u8) ?Language {
    if (name.len == 0) return null;

    const language = Language.of_name(name) orelse return null;
    if (!linted_set.contains(language)) return null;

    assert(std.mem.eql(u8, language.name(), name));

    return language;
}

pub fn of_path(path: []const u8) ?Language {
    if (path.len == 0) return null;

    const language = Language.of_path(path) orelse return null;
    if (!linted_set.contains(language)) return null;

    assert(language.extensions().len > 0);

    return language;
}

pub fn source_type(language: Language, path: []const u8) SourceType {
    assert(linted_set.contains(language));

    if (path.len == 0) return .of(language);

    const found = SourceType.of_path(path) orelse return .of(language);
    if (found.language != language) return .of(language);

    assert(found.valid());

    return found;
}

test bit {
    var seen: u64 = 0;

    for (linted) |language| {
        const mask = @as(u64, 1) << bit(language);

        try std.testing.expectEqual(0, seen & mask);

        seen |= mask;
    }

    try std.testing.expectEqual(linted.len, @popCount(seen));
}

test of_name {
    try std.testing.expectEqual(Language.typescript, of_name("typescript").?);
    try std.testing.expectEqual(null, of_name("css"));
    try std.testing.expectEqual(null, of_name("markup"));
    try std.testing.expectEqual(null, of_name(""));
    try std.testing.expectEqual(null, of_name("cobol"));
}

test of_path {
    try std.testing.expectEqual(Language.rust, of_path("src/main.rs").?);
    try std.testing.expectEqual(Language.typescript, of_path("view.tsx").?);
    try std.testing.expectEqual(Language.rust, of_path("file:///tmp/main.rs").?);
    try std.testing.expectEqual(null, of_path("style.css"));
    try std.testing.expectEqual(null, of_path("notes.txt"));
    try std.testing.expectEqual(null, of_path(""));
}

test source_type {
    const stub = source_type(.python, "types.pyi");
    const tsx = source_type(.typescript, "view.tsx");

    try std.testing.expectEqual(SourceType.Flavor.stub, stub.flavor);
    try std.testing.expectEqual(SourceType.Flavor.tsx, tsx.flavor);
    try std.testing.expectEqual(SourceType.Flavor.plain, source_type(.python, "").flavor);
    try std.testing.expectEqual(SourceType.Flavor.plain, source_type(.rust, "view.tsx").flavor);
}

test "every linted language carries conventions of its own" {
    for (linted) |language| {
        const conventions = Conventions.of_language(language);
        var carried_count: u32 = 0;

        inline for (comptime std.enums.values(Conventions.Field)) |field| {
            if (conventions.carries(field)) carried_count += 1;
        }

        try std.testing.expect(carried_count > 0);
    }
}

test "every convention word list is sorted" {
    const fields = @typeInfo(Conventions).@"struct";

    for (linted) |language| {
        const conventions = Conventions.of_language(language);

        inline for (fields.field_names, fields.field_types) |name, Value| {
            const matched_in_order = comptime std.mem.eql(u8, name, "pointer_sigils");

            if (Value != []const []const u8) continue;
            if (matched_in_order) continue;

            const words: []const []const u8 = @field(conventions, name);

            for (words[0..words.len -| 1], 0..) |word, index| {
                try std.testing.expect(std.mem.lessThan(u8, word, words[index + 1]));
            }
        }
    }
}
