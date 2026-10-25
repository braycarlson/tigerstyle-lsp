const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const safety = @import("../safety.zig");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Token = scylla.Token;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Minimize the number of variables in scope, to reduce the probability " ++
                "that variables are misused.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 6: \"Data objects must be declared at the smallest possible " ++
                "level of scope.\"",
        },
    },
    .code = "TS011",
    .default_on = true,
    .description = "An import names what it brings in, so a reader can tell where a name came " ++
        "from.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-star-import",
    .severity = .warning,
    .summary = "An import must name what it brings in",
    .url = "",
};

const alias_word = "as";
const message = "the import brings in every name";
const type_word = "type";
const module_word = "mod";
const relative_words = [_][]const u8{ "self", "super" };
const test_module_attribute = "#[cfg(test)]";
const visibility_token_count_max: u32 = 6;
const visibility_words = [_][]const u8{ "crate", "in", "pub", "self", "super" };

pub fn run(context: *const Context, sink: *Sink) void {
    const tokens = context.tokens;

    assert(tokens.len <= std.math.maxInt(u32));

    for (tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (!token.is_keyword(.import)) continue;
        if (!opens_an_import(context, index)) continue;

        if (relative_path(context, index + 1)) {
            if (test_module_encloses(context, index)) continue;
        }

        const end = import_end(context, index + 1);

        assert(end > index);

        for (index + 1..end) |offset| {
            if (!wildcard(context, @intCast(offset))) continue;

            const anchor = wildcard_start(context, @intCast(offset));

            sink.report(tokens[anchor].span(), message);
        }
    }
}

fn wildcard(context: *const Context, offset: u32) bool {
    assert(offset < context.tokens.len);

    const tokens = context.tokens;
    const candidate = tokens[offset];
    const next: ?Token = if (offset + 1 < tokens.len) tokens[offset + 1] else null;

    if (!candidate.is_punctuation(.star)) {
        if (!candidate.is_punctuation(.dot)) return false;

        const following = next orelse return false;
        if (following.kind != .string) return false;
    }

    if (candidate.is_punctuation(.star)) {
        if (!opens_a_glob(context, offset)) return false;
    }

    const following = next orelse return true;

    assert(following.offset >= candidate.end());

    return !std.mem.eql(u8, context.text(following), alias_word);
}

fn opens_a_glob(context: *const Context, star: u32) bool {
    assert(star < context.tokens.len);

    const tokens = context.tokens;
    const previous = stream.significant_previous(tokens, star) orelse return false;
    const token = tokens[previous];
    if (context.is_path_separator(token)) return true;
    if (token.is_keyword(.import)) return true;
    if (context.front.language == .rust) return opens_a_use_tree_item(token);
    if (!std.mem.eql(u8, context.text(token), type_word)) return false;

    const before = stream.significant_previous(tokens, previous) orelse return false;

    assert(before < previous);

    return tokens[before].is_keyword(.import);
}

fn opens_a_use_tree_item(token: Token) bool {
    if (token.is_punctuation(.comma)) return true;
    return token.kind == .block_start;
}

fn wildcard_start(context: *const Context, star: u32) u32 {
    assert(star < context.tokens.len);

    const tokens = context.tokens;

    var cursor = star;

    for (0..star) |_| {
        if (cursor < 2) break;
        if (!context.is_path_separator(tokens[cursor - 1])) break;

        const segment = cursor - 2;

        switch (tokens[segment].kind) {
            .identifier, .keyword => cursor = segment,
            else => break,
        }
    }

    assert(cursor <= star);

    return cursor;
}

fn test_module_encloses(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    const cursor = block_start_before(context, index);
    if (tokens[cursor].kind != .block_start) return false;

    const header = stream.line_start_of_token(tokens, context.source, cursor);

    assert(header <= cursor);

    const names_a_module = for (tokens[header..cursor]) |token| {
        if (std.mem.eql(u8, context.text(token), module_word)) break true;
    } else false;

    if (!names_a_module) return false;

    const line = context.line_of(tokens[header].offset);
    if (line == 0) return false;

    const above = scan.trim_ascii(context.line_text(line - 1));
    return std.mem.eql(u8, above, test_module_attribute);
}

fn block_start_before(context: *const Context, index: u32) u32 {
    assert(index < context.tokens.len);

    var depth: u32 = 0;
    var cursor = index;

    for (0..index) |_| {
        cursor -= 1;

        const token = context.tokens[cursor];

        if (token.kind == .block_end) {
            depth += 1;

            continue;
        }

        if (token.kind != .block_start) continue;
        if (depth == 0) break;

        depth -= 1;
    }

    assert(cursor <= index);

    return cursor;
}

fn import_end(context: *const Context, start: u32) u32 {
    assert(start <= context.tokens.len);

    var depth: u32 = 0;

    const end: u32 = end: for (context.tokens[start..], start..) |token, position| {
        const offset: u32 = @intCast(position);

        if (token.kind == .block_start) {
            if (depth == 0) {
                if (!groups_a_path(context, offset)) break :end offset;
            }
        }

        if (token.is_punctuation(.paren_open)) depth += 1;
        if (token.kind == .block_start) depth += 1;

        if (closes_an_import_group(token)) {
            if (depth == 0) break :end offset;

            depth -= 1;
        }

        if (depth == 0) {
            if (terminates_an_import(token)) break :end offset;
        }
    } else @intCast(context.tokens.len);

    assert(end >= start);
    assert(end <= context.tokens.len);

    return end;
}

fn closes_an_import_group(token: Token) bool {
    const closes = switch (token.kind) {
        .block_end => true,
        .punctuation => |punctuation| punctuation == .paren_close,
        else => false,
    };

    if (closes) assert(token.closes_a_group_or_block());
    if (closes) assert(!token.opens_a_group_or_block());

    return closes;
}

fn terminates_an_import(token: Token) bool {
    const terminal = switch (token.kind) {
        .comment, .newline => true,
        .punctuation => |punctuation| punctuation == .semicolon,
        else => false,
    };

    if (terminal) assert(token.kind != .identifier);
    if (terminal) assert(!token.opens_a_group_or_block());

    return terminal;
}

fn groups_a_path(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index == 0) return false;

    const before = context.tokens[index - 1];

    assert(before.offset <= context.tokens[index].offset);

    return before.is_punctuation(.colon);
}

fn opens_an_import(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    var cursor = index;

    for (0..visibility_token_count_max) |_| {
        if (cursor == 0) return true;

        const previous = cursor - 1;
        const token = context.tokens[previous];
        if (token.is_punctuation(.bracket_close)) return true;
        if (safety.follows_a_statement_break(context, cursor)) return true;
        if (!names_a_visibility(context, token)) return false;

        cursor = previous;
    }

    assert(cursor < index);

    return false;
}

fn names_a_visibility(context: *const Context, token: Token) bool {
    assert(token.end() <= context.source.len);

    if (token.is_punctuation(.paren_open)) return true;
    if (token.is_punctuation(.paren_close)) return true;

    const named = scan.word_in(&visibility_words, context.text(token));

    if (named) assert(token.length >= 2);

    return named;
}

fn relative_path(context: *const Context, start: u32) bool {
    assert(start <= context.tokens.len);

    if (start == context.tokens.len) return false;

    const token = context.tokens[start];
    const relative = scan.word_in(&relative_words, context.text(token));

    if (relative) assert(token.length >= 4);

    return relative;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a star import under an attribute is reported" {
    try expect_count(.rust, "#[cfg(unix)]\nuse unix::*;\n", 1);
}

test "a public re export is reported" {
    try expect_count(.rust, "pub use unix::*;\n", 1);
}

test "a crate visible re export is reported" {
    try expect_count(.rust, "pub(crate) use std::fmt::*;\n", 1);
}

test "a super glob inside a test module is quiet" {
    try testing.expect_quiet(@This(), .rust, "#[cfg(test)]\nmod tests {\n    use super::*;\n}\n");
}

test "a super glob outside a test module is reported" {
    try expect_count(.rust, "use super::*;\n\nmod inner {\n    use super::*;\n}\n", 2);
}

test "a star import inside a function is reported" {
    try expect_count(.python, "def run():\n    from os import *\n", 1);
}

test "a star import is reported" {
    try expect_count(.python, "from module import *\n", 1);
}

test "a wildcard is reported once per wildcard" {
    const source = "use std::io::*;\nuse foo::{bar::*, baz::*};\nfn f() {}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{ .{ 1, 5 }, .{ 2, 11 }, .{ 2, 19 } });
}

test "a wildcard anchors past a path keyword" {
    try testing.expect_anchors(@This(), .rust, "use crate::error::*;\nfn f() {}\n", &.{.{ 1, 5 }});
}

test "a python wildcard anchors at the star" {
    try testing.expect_anchors(@This(), .python, "from os.path import *\n", &.{.{ 1, 21 }});
}

test "a product or a power in an export is not a wildcard" {
    const source = "export const area = width * height;\nexport const limit = 2 ** 31;\n";

    try testing.expect_quiet(@This(), .typescript, source);
}

test "a glob inside a use group is a wildcard" {
    try expect_count(.rust, "use std::cmp::Ordering::{self, *};\nuse crate::{*};\nfn f() {}\n", 2);
}

test "a type only export of every name is a wildcard" {
    try expect_count(.typescript, "export type * from \"./kinds\";\n", 1);
    try expect_count(.javascript, "export * from \"./kinds\";\n", 1);
}
