const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const naming = @import("../naming.zig");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Declaration = Declarations.Declaration;
const Declarations = @import("../declarations.zig");
const Rendered = naming.Rendered;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const words_module = @import("../../words.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use proper capitalization for acronyms (`VSRState`, not `VsrState`).\"",
        },
    },
    .code = "TS042",
    .default_on = false,
    .description = "An acronym keeps one case throughout a name, so VSRState reads as one word " ++
        "rather than two.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "acronym-case",
    .severity = .information,
    .summary = "Capitalize an acronym as an acronym",
    .url = "",
};

const message = "the name spells an acronym in mixed case; write it as {s}";

pub fn run(context: *const Context, sink: *Sink) void {
    var names = naming.names_of(context);

    for (0..names.count_max()) |_| {
        const declaration = names.next() orelse break;

        assert(declaration.token < context.tokens.len);

        if (naming.stub_dictates(context, &declaration)) continue;

        name_check(context, sink, &declaration);
    }
}

fn name_check(context: *const Context, sink: *Sink, declaration: *const Declaration) void {
    assert(declaration.token < context.tokens.len);

    const token = context.tokens[declaration.token];
    const name = context.text(token);
    if (name.len == 0) return;
    if (naming.is_screaming(name)) return;

    var words = words_module.word_parts(name);

    for (0..name.len) |_| {
        const word = words.next() orelse return;
        const length = naming.acronym_length(word) orelse continue;

        assert(length <= word.len);

        if (!spells_both_cases(word[0..length])) continue;

        const rendered = upper_cased(name, word, length) orelse return;

        const fixed = naming.rename_fixed(
            context,
            sink,
            token,
            "Upper-case the acronym",
            rendered.slice(),
        );

        if (fixed) {
            sink.report_fixed_formatted(token.span(), message, .{
                scan.utf8_or(rendered.slice(), "the word"),
            });
        } else {
            sink.report_formatted(token.span(), message, .{
                scan.utf8_or(rendered.slice(), "the word"),
            });
        }

        return;
    }
}

fn spells_both_cases(acronym: []const u8) bool {
    assert(acronym.len > 0);

    var lower = false;
    var upper = false;

    for (acronym) |byte| {
        if (std.ascii.isLower(byte)) lower = true;
        if (std.ascii.isUpper(byte)) upper = true;
    }

    if (!lower) return false;
    return upper;
}

fn upper_cased(name: []const u8, word: []const u8, length: u32) ?Rendered {
    assert(length <= word.len);

    const start = scan.find(name, word) orelse return null;

    if (name.len > naming.rendered_bytes_max) return null;

    var rendered: Rendered = .empty;

    for (name, 0..) |byte, index| {
        const inside = index >= start and index < start + length;

        rendered.append(if (inside) std.ascii.toUpper(byte) else byte);
    }

    assert(rendered.length == name.len);

    return rendered;
}

fn expect_named(language: scylla.Language, source: []const u8, names: []const []const u8) !void {
    assert(source.len > 0);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != names.len) findings.print();

    try std.testing.expectEqual(names.len, findings.count());

    for (names, 0..) |name, index| {
        if (std.mem.find(u8, findings.message(@intCast(index)), name) != null) continue;

        findings.print();

        return error.TestUnexpectedMessage;
    }
}

test "a name a python stub declares is the runtime's spelling" {
    try testing.expect_stub_names(@This(), testing.stub_source, &.{ "tagOrId", "_AbiInfo" });

    var module = try testing.analyze(@This(), .python, testing.stub_source);
    defer module.deinit();

    if (module.count() != 3) module.print();

    try std.testing.expectEqual(@as(u32, 3), module.count());
}

test "a mixed case acronym renames in place" {
    try testing.expect_fixed(
        @This(),
        .rust,
        "struct HttpClient {\n}\n",
        .unsafe,
        "struct HTTPClient {\n}\n",
    );
}

test "a rename reaches every use in the file or is not offered" {
    const private = "const JsonValue = struct {};\n\nfn read() JsonValue {\n" ++
        "    return JsonValue{};\n}\n";

    const renamed = "const JSONValue = struct {};\n\nfn read() JSONValue {\n" ++
        "    return JSONValue{};\n}\n";

    const public = "pub const JsonValue = struct {};\n";

    try testing.expect_fixed(@This(), .zig, private, .unsafe, renamed);
    try testing.expect_fixed(@This(), .zig, public, .unsafe, public);
}

test "a rename reaches a use above the declaration" {
    const source = "pub fn read() JsonValue {\n    return JsonValue{};\n}\n\n" ++
        "const JsonValue = struct {};\n";

    const renamed = "pub fn read() JSONValue {\n    return JSONValue{};\n}\n\n" ++
        "const JSONValue = struct {};\n";

    try testing.expect_fixed(@This(), .zig, source, .unsafe, renamed);
}

test "a rename reaches the test that names the declaration" {
    const source = "const JsonValue = struct {};\n\ntest JsonValue {\n    _ = JsonValue{};\n}\n";
    const renamed = "const JSONValue = struct {};\n\ntest JSONValue {\n    _ = JSONValue{};\n}\n";

    try testing.expect_fixed(@This(), .zig, source, .unsafe, renamed);
}

test "a mixed case acronym is reported" {
    try expect_named(.rust, "struct HttpClient {\n}\n", &.{"HTTP"});
}

test "an upper case acronym is quiet" {
    try testing.expect_quiet(@This(), .rust, "struct HTTPClient {\n}\n");
}

test "a rust unit struct is named" {
    try expect_named(.rust, "struct HttpServer;\n", &.{"HTTPServer"});
}

test "a zig container binding is a type name" {
    const source = "const JsonValue = struct {\n    value: u32,\n};\n";

    try expect_named(.zig, source, &.{"JSONValue"});
}

test "a zig container binding in upper case is quiet" {
    try testing.expect_quiet(@This(), .zig, "const JSONValue = struct {\n    value: u32,\n};\n");
}

test "an acronym in a function name is checked" {
    const source = "package main\n\nfunc ParseJson() {}\n\nfunc parse_json() {}\n";

    try expect_named(.go, source, &.{"ParseJSON"});
}

test "a digit suffixed acronym is found" {
    const source = "struct Utf8Reader;\nstruct Ipv4Address;\nstruct Crc32;\n";

    try expect_named(.rust, source, &.{ "UTF8Reader", "IPv4Address", "CRC32" });
}

test "a lowercase acronym keeps one case" {
    try testing.expect_quiet(@This(), .go, "package main\n\ntype url struct{}\n");
}
