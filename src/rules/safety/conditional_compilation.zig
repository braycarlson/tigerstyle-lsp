const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 8: \"The use of conditional compilation directives is often " ++
                "also dubious, but cannot always be avoided. This means that there should " ++
                "rarely be justification for more than one or two conditional compilation " ++
                "directives even in large software development efforts, beyond the standard " ++
                "boilerplate that avoids multiple inclusion of the same header file. Each such " ++
                "use should be flagged by a tool-based checker and justified in the code.\"",
        },
    },
    .code = "TS035",
    .default_on = false,
    .description = "One program is built for every target, because a branch taken at build time " ++
        "is a branch no test covers.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "conditional-compilation",
    .severity = .warning,
    .summary = "Limit conditional compilation",
    .url = "",
};

const branch_words = [_][]const u8{
    "case ",
    "if ",
    "if(",
    "switch ",
    "switch(",
    "when ",
    "while ",
};

const build_marker = "//go:build";
const configuration_word = "cfg";
const legacy_build_marker = "// +build";
const marker_count_max: u32 = 16;
const predicate_scan_max: u32 = 256;
const test_suffix = "_test";
const test_word = "test";

pub fn run(context: *const Context, sink: *Sink) void {
    path_report(context, sink);

    const markers = context.conventions.conditional_markers;
    if (markers.len == 0) return;

    assert(markers.len <= marker_count_max);

    var occurrences: [marker_count_max]?u32 = undefined;

    for (markers, 0..) |marker, slot| occurrences[slot] = scan.find(context.source, marker);

    for (0..context.line_count()) |line_index| {
        const line: u32 = @intCast(line_index);
        const span = context.line_span(line);
        const text = context.line_text(line);

        for (markers, 0..) |marker, slot| {
            assert(marker.len > 0);

            const found = occurrence_from(context.source, marker, occurrences[slot], span.offset);

            occurrences[slot] = found;

            const at = found orelse continue;
            if (at + marker.len > span.end()) continue;

            const start = at - span.offset;
            const before = text[0..start];

            assert(start + marker.len <= text.len);

            if (needs_a_branch(context, marker)) {
                if (!branches_or_binds(before)) continue;
            }

            const offset = context.line_span(line).offset + start;

            if (!is_a_directive(marker)) {
                if (quoted(context, offset)) continue;
            }

            if (names_a_test(context, marker, offset)) continue;
            if (twins_a_constraint(context, marker, line)) continue;

            assert(offset + marker.len <= context.source.len);

            sink.report(
                .{ .offset = offset, .length = @intCast(marker.len) },
                "the branch builds a different program per target",
            );

            break;
        }
    }
}

fn occurrence_from(source: []const u8, marker: []const u8, held: ?u32, floor: u32) ?u32 {
    assert(marker.len > 0);
    assert(floor <= source.len);

    const occurrence = held orelse return null;
    if (occurrence >= floor) return occurrence;

    const found = std.mem.findPos(u8, source, floor, marker) orelse return null;

    assert(found >= floor);

    return @intCast(found);
}

fn path_report(context: *const Context, sink: *Sink) void {
    const suffixes = context.conventions.conditional_path_suffixes;
    if (suffixes.len == 0) return;

    const name = scylla.path.file_name(context.path);
    const dot = std.mem.findScalarLast(u8, name, '.') orelse name.len;
    const stem = name[0..dot];

    assert(dot <= name.len);
    assert(stem.len <= name.len);

    if (std.mem.endsWith(u8, stem, test_suffix)) return;

    for (suffixes) |suffix| {
        if (!std.mem.endsWith(u8, stem, suffix)) continue;

        assert(suffix.len <= stem.len);

        sink.report(
            context.line_span(0),
            "the file name selects a target; the file builds for one platform",
        );

        return;
    }
}

fn is_a_directive(marker: []const u8) bool {
    assert(marker.len > 0);

    if (std.mem.startsWith(u8, marker, "//")) return true;

    const directive = std.mem.startsWith(u8, marker, "#+");

    if (directive) assert(marker.len >= 2);

    return directive;
}

fn needs_a_branch(context: *const Context, marker: []const u8) bool {
    assert(marker.len > 0);

    if (!context.conventions.conditional_markers_need_a_branch) return false;
    if (std.mem.startsWith(u8, marker, "#")) return false;

    const needs = !std.mem.startsWith(u8, marker, "//");

    if (needs) assert(marker[0] != '#');

    return needs;
}

fn branches_or_binds(text: []const u8) bool {
    if (branches(text)) return true;
    if (scan.find(text, "::") != null) return true;
    if (!scan.find_word(text, "const")) return false;

    const binds = scan.find(text, "=") != null;

    if (binds) assert(text.len > "const".len);

    return binds;
}

fn names_a_test(context: *const Context, marker: []const u8, offset: u32) bool {
    if (scan.find(marker, configuration_word) == null) return false;

    assert(offset + marker.len <= context.source.len);

    const start = offset + marker.len;
    const end = @min(start + predicate_scan_max, context.source.len);

    assert(start <= end);

    return holds_the_test_word(configuration_predicate(context.source[start..end]));
}

fn holds_the_test_word(predicate: []const u8) bool {
    assert(predicate.len <= predicate_scan_max);

    var start: usize = 0;

    for (predicate, 0..) |byte, index| {
        if (scan.is_identifier_part(byte)) continue;
        if (std.mem.eql(u8, predicate[start..index], test_word)) return true;

        start = index + 1;
    }

    assert(start <= predicate.len);

    return std.mem.eql(u8, predicate[start..], test_word);
}

fn configuration_predicate(after: []const u8) []const u8 {
    assert(after.len <= predicate_scan_max);

    var depth: u32 = 0;

    for (after, 0..) |byte, index| {
        switch (byte) {
            '(', '[' => depth += 1,
            ')', ']' => {
                if (depth == 0) return after[0..index];

                depth -= 1;
            },
            ',' => if (depth == 0) return after[0..index],
            else => {},
        }
    }

    assert(depth <= after.len);

    return after;
}

fn twins_a_constraint(context: *const Context, marker: []const u8, line: u32) bool {
    if (!std.mem.eql(u8, marker, legacy_build_marker)) return false;
    if (line == 0) return false;

    assert(marker.len == legacy_build_marker.len);
    assert(line < context.line_count());

    return scan.find(context.line_text(line - 1), build_marker) != null;
}

fn quoted(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    for (context.tokens) |token| {
        switch (token.kind) {
            .comment, .string => {},
            else => continue,
        }

        if (!token.span().contains(offset)) continue;

        assert(token.length > 0);

        return true;
    }

    return false;
}

fn branches(text: []const u8) bool {
    for (branch_words) |word| {
        const found = scan.find(text, word) orelse continue;

        assert(found + word.len <= text.len);

        return true;
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

test "a feature predicate is reported" {
    try expect_count(.rust, "#[cfg(feature = \"latest\")]\nfn run() {}\n", 1);
}

test "a test predicate is quiet" {
    const source = "#[cfg(test)]\nmod tests {}\n\n#[cfg(any(test, feature = \"x\"))]\nfn " ++
        "a() {}\n\n#[cfg(not(test))]\nfn b() {}\n\n#[cfg_attr(test, " ++
        "derive(Debug))]\nstruct S;\n\nfn c() {\n    if cfg!(test) {}\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a test word outside the predicate skips nothing" {
    const source = "#[cfg(target_os = \"windows\")] // fastest\nfn a() {}\n\n#[cfg(unix)]\n" ++
        "fn b() {}\n\nfn contest() {}\n";

    try expect_count(.rust, source, 2);
}

test "a debug assertions predicate is reported" {
    try expect_count(.rust, "#[cfg(debug_assertions)]\nfn run() {}\n", 1);
}

test "a conditional derive is reported" {
    const source = "#[cfg_attr(feature = \"serde\", derive(Serialize))]\nstruct S;\n";

    try expect_count(.rust, source, 1);
}

test "an odin build directive is reported" {
    try expect_count(.odin, "#+build linux\npackage p\n", 1);
}

test "an odin constant bound to a marker is reported" {
    try expect_count(.odin, "package p\n\nis_windows :: ODIN_OS == .Windows\n", 1);
}

test "a zig constant bound to a marker is reported" {
    const source = "const builtin = @import(\"builtin\");\nconst native_os = " ++
        "builtin.os.tag;\n\nfn run() void {\n    if (builtin.mode == .Debug) " ++
        "{}\n}\n";

    try expect_count(.zig, source, 2);
}

test "a javascript marker outside a branch is quiet" {
    const source = "function run() {\n    process.env.NODE_ENV = \"development\";\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "an odin marker outside a branch is quiet" {
    try testing.expect_quiet(@This(), .odin, "ODIN_DEBUG: bool\n");
}

test "an odin marker inside a branch is reported" {
    const source = "run :: proc() {\n\twhen ODIN_OS == .Windows {\n\t\tship()\n\t}\n}\n";

    try expect_count(.odin, source, 1);
}

test "a marker inside a doc comment is quiet" {
    const source = "/// let held = cfg!(target_endian = \"big\");\nfn run() {}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a marker inside a string is quiet" {
    const source = "def run():\n    print(f\"on {sys.platform}\")\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a go build comment is still reported" {
    try expect_count(.go, "//go:build windows\n\npackage main\n", 1);
}

test "a rust marker needs no branch" {
    try expect_count(.rust, "#[cfg(feature = \"paging\")]\nfn run() {}\n", 1);
}
