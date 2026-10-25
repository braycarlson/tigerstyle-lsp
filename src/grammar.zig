const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Language = scylla.Language;

annotation_prefix: []const u8 = "",
branch_body_word: []const u8 = "",
capital_marks_export: bool = false,
cast_words: []const []const u8 = &.{},
comment_block_close: []const u8 = "",
comment_block_open: []const u8 = "",
comment_prefix: []const u8 = "//",
decorator_prefix: []const u8 = "",
defer_word: []const u8 = "",
discard_names_each_value: bool = false,
discard_prefix: []const u8 = "",
primitive_types: []const []const u8 = &.{},
sized_type_names: []const []const u8 = &.{},
statements_end_with_semicolon: bool = false,
type_follows_colon: bool = true,

const Grammar = @This();

const css: Grammar = .{
    .comment_block_close = "*/",
    .comment_block_open = "/*",
    .comment_prefix = "",
};

const go: Grammar = .{
    .capital_marks_export = true,
    .comment_block_close = "*/",
    .comment_block_open = "/*",
    .defer_word = "defer",
    .discard_names_each_value = true,
    .discard_prefix = "_ = ",
    .sized_type_names = &.{ "int", "uint", "uintptr" },
    .type_follows_colon = false,
};

const javascript: Grammar = .{
    .annotation_prefix = "@",
    .comment_block_close = "*/",
    .comment_block_open = "/*",
    .decorator_prefix = "@",
};

const odin: Grammar = .{
    .annotation_prefix = "@",
    .branch_body_word = "do",
    .cast_words = &.{ "auto_cast", "cast", "transmute" },
    .comment_block_close = "*/",
    .comment_block_open = "/*",
    .decorator_prefix = "@",
    .defer_word = "defer",
    .discard_names_each_value = true,
    .discard_prefix = "_ = ",
    .primitive_types = &odin_primitive_types,
    .sized_type_names = &.{ "int", "uint", "uintptr" },
};

const python: Grammar = .{
    .annotation_prefix = "@",
    .comment_prefix = "#",
    .decorator_prefix = "@",
    .discard_prefix = "_ = ",
};

const rust: Grammar = .{
    .annotation_prefix = "#[",
    .cast_words = &.{"as"},
    .comment_block_close = "*/",
    .comment_block_open = "/*",
    .discard_prefix = "let _ = ",
    .primitive_types = &rust_primitive_types,
    .sized_type_names = &.{ "isize", "usize" },
    .statements_end_with_semicolon = true,
};

const typescript: Grammar = typed: {
    var typed = javascript;

    typed.cast_words = &typescript_cast_words;
    typed.primitive_types = &typescript_primitive_types;

    break :typed typed;
};

const zig: Grammar = .{
    .cast_words = &zig_cast_words,
    .defer_word = "defer",
    .discard_prefix = "_ = ",
    .primitive_types = &zig_primitive_types,
    .sized_type_names = &.{ "isize", "usize" },
    .statements_end_with_semicolon = true,
};

const odin_primitive_types = [_][]const u8{
    "any",
    "b16",
    "b32",
    "b64",
    "b8",
    "bool",
    "complex128",
    "complex32",
    "complex64",
    "cstring",
    "f16",
    "f16be",
    "f16le",
    "f32",
    "f32be",
    "f32le",
    "f64",
    "f64be",
    "f64le",
    "i128",
    "i128be",
    "i128le",
    "i16",
    "i16be",
    "i16le",
    "i32",
    "i32be",
    "i32le",
    "i64",
    "i64be",
    "i64le",
    "i8",
    "int",
    "quaternion128",
    "quaternion256",
    "quaternion64",
    "rawptr",
    "rune",
    "string",
    "typeid",
    "u128",
    "u128be",
    "u128le",
    "u16",
    "u16be",
    "u16le",
    "u32",
    "u32be",
    "u32le",
    "u64",
    "u64be",
    "u64le",
    "u8",
    "uint",
    "uintptr",
};

const rust_primitive_types = [_][]const u8{
    "bool",
    "char",
    "f32",
    "f64",
    "i128",
    "i16",
    "i32",
    "i64",
    "i8",
    "isize",
    "str",
    "u128",
    "u16",
    "u32",
    "u64",
    "u8",
    "usize",
};

const typescript_cast_words = [_][]const u8{ "as", "satisfies" };

const typescript_primitive_types = [_][]const u8{
    "any",
    "bigint",
    "boolean",
    "never",
    "null",
    "number",
    "object",
    "string",
    "symbol",
    "undefined",
    "unknown",
    "void",
};

const zig_cast_words = [_][]const u8{
    "@alignCast",
    "@as",
    "@bitCast",
    "@enumFromInt",
    "@floatFromInt",
    "@intCast",
    "@intFromEnum",
    "@intFromFloat",
    "@intFromPtr",
    "@ptrCast",
    "@ptrFromInt",
    "@truncate",
};

const zig_primitive_types = [_][]const u8{
    "anyerror",
    "anyframe",
    "anyopaque",
    "bool",
    "c_char",
    "c_int",
    "c_long",
    "c_longdouble",
    "c_longlong",
    "c_short",
    "c_uint",
    "c_ulong",
    "c_ulonglong",
    "c_ushort",
    "comptime_float",
    "comptime_int",
    "f128",
    "f16",
    "f32",
    "f64",
    "f80",
    "i1*",
    "i2*",
    "i3*",
    "i4*",
    "i5*",
    "i6*",
    "i7*",
    "i8*",
    "i9*",
    "isize",
    "noreturn",
    "type",
    "u1*",
    "u2*",
    "u3*",
    "u4*",
    "u5*",
    "u6*",
    "u7*",
    "u8*",
    "u9*",
    "usize",
    "void",
};

fn text_less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

pub fn of(language: Language) *const Grammar {
    assert(language != .markup);

    const held: *const Grammar = switch (language) {
        .css => &css,
        .go => &go,
        .javascript => &javascript,
        .odin => &odin,
        .python => &python,
        .rust => &rust,
        .typescript => &typescript,
        .zig => &zig,
        .markup => unreachable,
    };

    if (held.comment_prefix.len == 0) assert(held.comment_block_open.len > 0);
    if (held.comment_block_open.len > 0) assert(held.comment_block_close.len > 0);

    return held;
}

test "every grammar word list is sorted" {
    for (std.enums.values(Language)) |language| {
        if (language == .markup) continue;

        const grammar = of(language);

        const lists = [_][]const []const u8{
            grammar.cast_words,
            grammar.primitive_types,
            grammar.sized_type_names,
        };

        for (lists) |list| {
            try std.testing.expect(std.sort.isSorted([]const u8, list, {}, text_less));
        }
    }
}
