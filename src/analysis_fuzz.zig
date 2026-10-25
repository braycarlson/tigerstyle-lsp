const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const fuzz = @import("testing/fuzz.zig");
const languages = @import("languages.zig");
const Analysis = @import("analysis.zig");
const Document = @import("document.zig");
const Language = scylla.Language;
const Limits = @import("limits.zig");
const PRNG = scylla.testing.PRNG;
const Rules = @import("rules.zig");
const Settings = @import("settings.zig");
const StaticAllocator = scylla.StaticAllocator;

const Slot = enum {
    full,
    subject,
    twin,
};

const Harness = struct {
    analysis: Analysis,
    documents: std.EnumArray(Slot, Document),
    rules: Rules,

    fn init(harness: *Harness, gpa: std.mem.Allocator, io: std.Io) !void {
        harness.rules = try .init(gpa);

        try harness.analysis.init(gpa, io, &limits.analysis());

        for (std.enums.values(Slot)) |slot| {
            harness.documents.set(slot, try .init(gpa, &limits.document()));
        }

        assert(harness.rules.count() > 0);
    }

    fn deinit(harness: *Harness, gpa: std.mem.Allocator) void {
        assert(harness.rules.count() > 0);

        for (std.enums.values(Slot)) |slot| harness.documents.getPtr(slot).deinit(gpa);

        harness.analysis.deinit(gpa);
        harness.rules.deinit(gpa);
        harness.* = undefined;
    }

    fn analyzed(
        harness: *Harness,
        slot: Slot,
        language: Language,
        enabled: u128,
        source: []const u8,
    ) bool {
        assert(languages.linted_set.contains(language));

        const document = harness.documents.getPtr(slot);

        document.state.diagnostics.clear();
        document.state.language = language;

        document.text.text_replace(source) catch return false;

        var settings = Settings.default;

        settings.rules = .of_bits(enabled);

        harness.analysis.run(document.entry(), &harness.rules, &settings);

        return true;
    }

    fn check(harness: *Harness, language: Language, selection: u128, source: []const u8) void {
        const registered = registered_mask(&harness.rules);
        const chosen = selection & registered;
        if (!harness.analyzed(.subject, language, chosen, source)) return;

        assert(harness.analyzed(.twin, language, chosen, source));

        const subject = harness.documents.getPtr(.subject);

        spans_check(subject, source);
        answers_check(subject, harness.documents.getPtr(.twin));
        assert(harness.analyzed(.full, language, registered, source));
        subset_check(harness.documents.getPtr(.full), subject);
    }
};

const limits: Limits = limits: {
    var held = Limits.default;

    held.call_edge_count_max = 1_024;
    held.depth_max = 32;
    held.diagnostic_count_max = 256;
    held.document_count_max = 4;
    held.file_bytes_max = 4_096;
    held.file_line_count_max = 512;
    held.fix_edit_count_max = 256;
    held.front.node_count_max = 1_024;
    held.front.token_count_max = 4_096;
    held.function_count_max = 256;
    held.suppression_count_max = 256;

    break :limits held;
};

const fragments = [_][]const u8{
    "fn",
    "def",
    "func",
    "proc",
    "const",
    "let",
    "var",
    "if",
    "else",
    "for",
    "while",
    "loop",
    "return",
    "assert",
    "try",
    "catch",
    "except",
    "class",
    "struct",
    "import",
    "(",
    ")",
    "{",
    "}",
    "[",
    "]",
    ";",
    ",",
    ".",
    ":",
    "=",
    "==",
    "!=",
    "&&",
    "||",
    "and",
    "or",
    "not",
    "+",
    "-",
    "*",
    "/",
    "\"",
    "'",
    "`",
    "//",
    "#",
    "/*",
    "*/",
    "\n",
    " ",
    "    ",
    "\t",
    "\r\n",
    "0",
    "1.5",
    "value",
    "x",
    "maxVal",
    "\u{e9}",
};

comptime {
    assert(limits.file_bytes_max >= 1_024);
    assert(fragments.len > 32);
}

pub fn main(gpa: std.mem.Allocator, io: std.Io, args: fuzz.FuzzArgs) !void {
    var prng = PRNG.init(args.seed);
    const events_max = args.events_max orelse 1_024;

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    const static = static_allocator.allocator();
    const harness = try gpa.create(Harness);
    defer gpa.destroy(harness);

    try harness.init(static, io);
    defer harness.deinit(static);

    var source_buffer: [limits.file_bytes_max]u8 = undefined;

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (0..events_max) |_| {
        const source = fuzz.source_generate(&prng, &fragments, &source_buffer);
        const language = languages.linted[prng.index(languages.linted.len)];
        const selection = @as(u128, prng.int(u64)) << 64 | prng.int(u64);

        harness.check(language, selection, source);
    }
}

fn registered_mask(rules: *const Rules) u128 {
    const count = rules.count();

    assert(count > 0);
    assert(count < 128);

    return (@as(u128, 1) << @intCast(count)) - 1;
}

fn spans_check(document: *const Document, source: []const u8) void {
    const diagnostics = document.state.diagnostics.slice();

    assert(document.text.text_count() == source.len);

    for (diagnostics) |diagnostic| {
        const start = diagnostic.span.offset;
        const end = diagnostic.span.end();

        assert(end <= source.len);
        assert(boundary_is(source, start));
        assert(boundary_is(source, end));

        round_trip_check(document, start);
        round_trip_check(document, end);
    }
}

fn boundary_is(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);

    if (offset == source.len) return true;
    return source[offset] & 0xc0 != 0x80;
}

fn round_trip_check(document: *const Document, offset: u32) void {
    assert(offset <= document.text.text_count());

    const position = document.text.point_of(offset);

    assert(document.text.offset_of(position).? == offset);
}

fn answers_check(left: *const Document, right: *const Document) void {
    const first = left.state.diagnostics.slice();
    const second = right.state.diagnostics.slice();

    assert(first.len == second.len);

    for (first, second) |one, other| {
        assert(std.mem.eql(u8, one.code, other.code));
        assert(one.span.offset == other.span.offset);
        assert(one.span.length == other.span.length);
    }
}

fn subset_check(full: *const Document, subject: *const Document) void {
    const everything = full.state.diagnostics.slice();
    const chosen = subject.state.diagnostics.slice();

    if (full.state.diagnostics.is_overflowed()) return;

    for (chosen) |diagnostic| {
        var found = false;

        for (everything) |other| {
            if (!std.mem.eql(u8, other.code, diagnostic.code)) continue;
            if (other.span.offset != diagnostic.span.offset) continue;

            found = true;

            break;
        }

        assert(found);
    }
}

test "analysis fuzz smoke" {
    try main(std.testing.allocator, std.testing.io, .{ .events_max = 64, .seed = 123 });
}
