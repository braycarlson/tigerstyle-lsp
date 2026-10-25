const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const classify = @import("classify.zig");
const conventions_module = @import("conventions.zig");
const directives = @import("rules/directives.zig");
const languages = @import("languages.zig");
const scan = @import("scan.zig");
const timing = @import("timing.zig");
const Context = @import("rules/context.zig");
const Diagnostics = scylla.Diagnostics;
const Document = @import("document.zig");
const Enclosures = @import("rules/enclosures.zig");
const Fixes = scylla.Fixes;
const Front = scylla.Front;
const Fronts = scylla.Fronts;
const Grammar = @import("grammar.zig");
const Language = scylla.Language;
const MacroOpeners = @import("rules/macro_openers.zig");
const Pairs = scylla.Brackets;
const Regions = scylla.suppress.Regions;
const Rules = @import("rules.zig");
const Settings = @import("settings.zig");
const Span = scylla.Span;
const Limits = @import("limits.zig");
const Tables = scylla.Calls;
const Token = scylla.Token;
const TokenIndex = scylla.TokenIndex;
const log = scylla.log;

comments: scylla.ArrayType(Span),
enclosures: Enclosures,
expectation_aliases: classify.ExpectationAliases,
fixes: Fixes,
fronts: Fronts,
macro_openers: MacroOpeners,
io: std.Io,
pairs: Pairs,
path: scylla.Buffer,
suppressions: Regions,
tables: Tables,
timings: timing.Timings,
token_index: TokenIndex,
tokens: scylla.ArrayType(Token),

const Analysis = @This();

pub const Capacity = struct {
    calls: Tables.Capacity,
    fixes: Fixes.Capacity,
    front: Front.Capacity,
    suppression_count_max: u32,
    uri_bytes_max: u32,
};

pub const code_unnamed = "tigerstyle-lsp";
const reject_depth = "the file nests deeper than tigerstyle-lsp analyzes";
const reject_front = "the file holds text the language front end does not read";
const directive_bytes_max: u32 = 64;

pub fn init(
    analysis: *Analysis,
    gpa: std.mem.Allocator,
    io: std.Io,
    capacity: *const Capacity,
) std.mem.Allocator.Error!void {
    const token_count_max = capacity.front.token_count_max;

    assert(token_count_max > 0);
    assert(capacity.front.node_count_max <= token_count_max);

    analysis.io = io;
    analysis.timings = .zero;
    analysis.comments = try .init(gpa, token_count_max);
    errdefer analysis.comments.deinit(gpa);

    analysis.enclosures = try .init(gpa, capacity.front.node_count_max);
    errdefer analysis.enclosures.deinit(gpa);

    analysis.fixes = try .init(gpa, capacity.fixes);
    errdefer analysis.fixes.deinit(gpa);

    try analysis.fronts.init(gpa, &capacity.front, languages.linted_set, &.{});
    errdefer analysis.fronts.deinit(gpa);

    analysis.macro_openers = try .init(gpa);
    errdefer analysis.macro_openers.deinit(gpa);

    analysis.pairs = try .init(gpa, token_count_max);
    errdefer analysis.pairs.deinit(gpa);

    analysis.path = try .init(gpa, capacity.uri_bytes_max);
    errdefer analysis.path.deinit(gpa);

    analysis.suppressions = try .init(gpa, capacity.suppression_count_max);
    errdefer analysis.suppressions.deinit(gpa);

    try analysis.tables.init(gpa, capacity.calls);
    errdefer analysis.tables.deinit(gpa);

    analysis.token_index = try .init(gpa, token_count_max);
    errdefer analysis.token_index.deinit(gpa);

    analysis.tokens = try .init(gpa, token_count_max);

    assert(analysis.tokens.count() == 0);
}

pub fn deinit(analysis: *Analysis, gpa: std.mem.Allocator) void {
    assert(analysis.tokens.count() <= analysis.tokens.capacity());

    analysis.comments.deinit(gpa);
    analysis.enclosures.deinit(gpa);
    analysis.fixes.deinit(gpa);
    analysis.fronts.deinit(gpa);
    analysis.macro_openers.deinit(gpa);
    analysis.pairs.deinit(gpa);
    analysis.path.deinit(gpa);
    analysis.suppressions.deinit(gpa);
    analysis.tables.deinit(gpa);
    analysis.token_index.deinit(gpa);
    analysis.tokens.deinit(gpa);
    analysis.* = undefined;
}

pub fn run(
    analysis: *Analysis,
    entry: Document.Entry,
    rules: *const Rules,
    settings: *const Settings,
) void {
    const language = entry.state.language orelse return;
    const source_type = languages.source_type(language, entry.text.uri());

    analysis.path.clear();
    analysis.path.push(entry.text.uri()) catch unreachable;

    const source = entry.text.text_bytes();
    const diagnostics = &entry.state.diagnostics;

    assert(diagnostics.empty());

    if (is_generated(source)) return;
    if (is_markup(source)) return;

    analysis.fixes.clear();
    analysis.timings.document_record();

    if (!analysis.front_build_complete(source_type, source, diagnostics)) return;

    analysis.finish(.{
        .language = language,
        .lines = entry.text.lines_index(),
        .rules = rules,
        .settings = settings,
        .source = source,
    }, diagnostics);
}

const Prepared = struct {
    language: Language,
    lines: *const scylla.LineIndex,
    rules: *const Rules,
    settings: *const Settings,
    source: []const u8,
};

fn front_build_complete(
    analysis: *Analysis,
    source_type: scylla.SourceType,
    source: []const u8,
    diagnostics: *Diagnostics,
) bool {
    const clock = timing.Clock.init(analysis.io);
    const built = analysis.fronts.parse(source_type, source);

    analysis.timings.stage_add(.front, clock.nanoseconds());

    if (built) |_| return true else |err| switch (err) {
        error.DepthExceeded => rejection_report(diagnostics, reject_depth),
        error.BindingsExhausted,
        error.ChecksExhausted,
        error.DiagnosticsExhausted,
        error.EventsExhausted,
        error.FactsExhausted,
        error.IntermediatesExhausted,
        error.NodesExhausted,
        error.ReferencesExhausted,
        error.ScopesExhausted,
        error.TagsExhausted,
        error.TokensExhausted,
        => rejection_report(diagnostics, reject_front),
    }

    assert(!diagnostics.empty());

    return false;
}

fn finish(analysis: *Analysis, prepared: Prepared, diagnostics: *Diagnostics) void {
    const front = analysis.fronts.front(prepared.language);
    const conventions = conventions_module.of_language(prepared.language);

    analysis.tokens.clear();
    analysis.tokens.push_slice(front.tokens());
    classify.vocabulary(prepared.language, prepared.source, analysis.tokens.slice());

    const tokens = analysis.tokens.const_slice();

    assert(front.tokens().len == tokens.len);

    analysis.token_index.build(tokens);

    analysis.pairs.build(prepared.source, tokens) catch |err| switch (err) {
        error.DepthExceeded => log.line(
            "a file nests brackets deeper than {d}; the deeper ones stay unpaired",
            .{scylla.limits.bracket_depth_max},
        ),
    };

    const clock = timing.Clock.init(analysis.io);

    analysis.tables.build(front, &conventions.returns());
    analysis.enclosures.build(front, prepared.lines, prepared.source);
    analysis.macro_openers.build(tokens, conventions);
    analysis.expectation_aliases = .of(prepared.language, prepared.source, front.bindings());

    analysis.timings.stage_add(.tables, clock.nanoseconds());

    assert(analysis.tables.functions().len <= front.node_count());

    const context: Context = .{
        .conventions = conventions,
        .enclosures = &analysis.enclosures,
        .expectation_aliases = &analysis.expectation_aliases,
        .front = front,
        .grammar = Grammar.of(prepared.language),
        .lines = prepared.lines,
        .macro_openers = &analysis.macro_openers,
        .pairs = &analysis.pairs,
        .path = analysis.path.const_slice(),
        .registry = &prepared.rules.registry,
        .settings = prepared.settings,
        .source = prepared.source,
        .tables = &analysis.tables,
        .token_index = &analysis.token_index,
        .tokens = tokens,
    };

    analysis.stage_rules(prepared, &context, diagnostics);
}

fn stage_rules(
    analysis: *Analysis,
    prepared: Prepared,
    context: *const Context,
    diagnostics: *Diagnostics,
) void {
    const clock = timing.Clock.init(analysis.io);

    directives.scan(&analysis.suppressions, context, &analysis.comments);

    prepared.rules.run(analysis.io, prepared.language, context, .{
        .diagnostics = diagnostics,
        .fixes = &analysis.fixes,
        .suppressions = &analysis.suppressions,
    }, &analysis.timings);

    analysis.timings.stage_add(.rules, clock.nanoseconds());
    diagnostics.sort();

    assert(diagnostics.count() <= diagnostics.capacity());
}

pub fn fixes_swap(analysis: *Analysis, other: *Fixes) void {
    const held = analysis.fixes;

    analysis.fixes = other.*;
    other.* = held;

    assert(other.count() == held.count());
}

pub fn suppressions_plan(analysis: *Analysis, entry: Document.Entry, prefix: []const u8) void {
    const source = entry.text.text_bytes();
    const lines = entry.text.lines_index();
    const diagnostics = &entry.state.diagnostics;
    var edited: u32 = 0;

    assert(prefix.len > 0);

    analysis.fixes.clear();

    for (diagnostics.slice(), 0..) |diagnostic, index| {
        if (std.mem.eql(u8, diagnostic.code, code_unnamed)) continue;

        const line = lines.line_of(diagnostic.span.offset);
        const end = scan.line_scan(source, lines.line_start(line));

        analysis.fixes.open("Suppress the finding", .safe, line);

        var text: [directive_bytes_max]u8 = undefined;

        const directive = std.mem.print(&text, "  {s} tigerstyle-ignore: {s}", .{
            prefix,
            diagnostic.code,
        }) catch "";

        if (directive.len > 0) {
            if (analysis.fixes.edit(.{ .offset = end, .length = 0 }, directive)) {
                edited += 1;
            } else |err| switch (err) {
                error.EditsExhausted, error.TargetExhausted, error.TextExhausted => {},
            }
        }

        diagnostics.attach(@intCast(index), analysis.fixes.close());
    }

    assert(edited <= diagnostics.count());
}

fn rejection_report(diagnostics: *Diagnostics, message: []const u8) void {
    assert(message.len > 0);

    diagnostics.push(.{
        .code = code_unnamed,
        .fix = null,
        .message = .{ .static = message },
        .related_count = 0,
        .related_start = 0,
        .rule = null,
        .severity = .warning,
        .span = .{ .offset = 0, .length = 0 },
    }) catch |err| switch (err) {
        error.RelatedExhausted, error.RowsExhausted => {},
    };

    assert(!diagnostics.empty());
}

fn is_generated(source: []const u8) bool {
    assert(source.len <= std.math.maxInt(u32));

    var start: u32 = 0;

    for (0..generated_line_count) |_| {
        if (start >= source.len) break;

        const end = scan.line_scan(source, start);

        assert(end <= source.len);

        for (generated_markers) |marker| {
            if (scan.contains_folded(source[start..end], marker)) return true;
        }

        if (end == source.len) break;

        start = end + 1;
    }

    return false;
}

fn is_markup(source: []const u8) bool {
    const unmarked = if (std.mem.startsWith(u8, source, byte_order_mark))
        source[byte_order_mark.len..]
    else
        source;

    const text = std.mem.trimStart(u8, unmarked, scan.ascii_whitespace);

    assert(text.len <= source.len);

    return std.mem.startsWith(u8, text, markup_declaration);
}

const byte_order_mark = "\xef\xbb\xbf";
const generated_line_count: u32 = 8;

const generated_markers = [_][]const u8{
    "@generated",
    "auto-generated",
    "autogenerated",
    "automatically generated",
    "code generated",
    "do not edit",
    "do not manually modify",
};

const markup_declaration = "<?xml";

test Analysis {
    const gpa = std.testing.allocator;
    const source = "fn read_sector() {\n    loop {\n        let value = 1;\n    }\n}\n";

    var rules: Rules = try .init(gpa);
    defer rules.deinit(gpa);

    var analysis: Analysis = undefined;

    try analysis.init(gpa, std.testing.io, &Limits.default.analysis());
    defer analysis.deinit(gpa);

    var document: Document = try .init(gpa, &Limits.default.document());
    defer document.deinit(gpa);

    var settings: Settings = .default;

    settings.rules = rules.defaults();

    try document.text.uri_set("src/sector.rs");
    try document.text.text_replace(source);
    document.state.language = .rust;

    analysis.run(document.entry(), &rules, &settings);

    const diagnostics = &document.state.diagnostics;
    var bounded_loop = false;

    for (diagnostics.slice()) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "TS006")) bounded_loop = true;
    }

    try std.testing.expect(bounded_loop);
    try std.testing.expectEqual(@as(u32, 1), analysis.timings.document_count());

    document.state.language = null;

    diagnostics.clear();
    analysis.run(document.entry(), &rules, &settings);

    try std.testing.expect(diagnostics.empty());
}

test "a file that opens with an xml declaration is markup, not code" {
    try std.testing.expect(is_markup("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<TS/>\n"));
    try std.testing.expect(is_markup("\xef\xbb\xbf<?xml version=\"1.0\"?>\n"));
    try std.testing.expect(is_markup("\n  <?xml version=\"1.0\"?>\n"));
    try std.testing.expect(!is_markup("const declaration = \"<?xml\";\n"));
    try std.testing.expect(!is_markup("const x = 1;\n"));
    try std.testing.expect(!is_markup(""));
}

test "a generated marker in the head marks the file" {
    try std.testing.expect(is_generated("// Code generated by tool. DO NOT EDIT.\npackage main\n"));
    try std.testing.expect(is_generated("\n\n\n# @generated\n"));
    try std.testing.expect(!is_generated("fn main() {}\n"));
    try std.testing.expect(!is_generated("1\n2\n3\n4\n5\n6\n7\n8\n// do not edit\n"));
}
