const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const conventions_module = @import("../conventions.zig");
const directives = @import("directives.zig");
const Context = @import("context.zig");
const Diagnostics = scylla.Diagnostics;
const Enclosures = @import("enclosures.zig");
const Grammar = @import("../grammar.zig");
const MacroOpeners = @import("macro_openers.zig");
const Fixes = scylla.Fixes;
const Fronts = scylla.Fronts;
const Index = scylla.LineIndex;
const Language = scylla.Language;
const Limits = @import("../limits.zig");
const Pairs = scylla.Brackets;
const Regions = scylla.suppress.Regions;
const Registry = scylla.rule.Registry;
const Settings = @import("../settings.zig");
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const StaticAllocator = scylla.StaticAllocator;
const Tables = scylla.Calls;
const Token = scylla.Token;
const TokenIndex = scylla.TokenIndex;
const classify = @import("../classify.zig");

pub const Findings = struct {
    diagnostics: Diagnostics,

    pub fn deinit(findings: *Findings) void {
        findings.diagnostics.deinit(std.testing.allocator);
        findings.* = undefined;
    }

    pub fn contains(findings: *const Findings, text: []const u8) bool {
        for (0..findings.count()) |index| {
            if (std.mem.eql(u8, findings.message(@intCast(index)), text)) return true;
        }

        return false;
    }

    pub fn count(findings: *const Findings) u32 {
        return findings.diagnostics.count();
    }

    pub fn empty(findings: *const Findings) bool {
        return findings.diagnostics.empty();
    }

    pub fn message(findings: *const Findings, index: u32) []const u8 {
        assert(index < findings.count());

        const row = &findings.diagnostics.slice()[index];
        return findings.diagnostics.message_of(row);
    }

    pub fn span(findings: *const Findings, index: u32) Span {
        assert(index < findings.count());

        return findings.diagnostics.slice()[index].span;
    }

    fn expect_messages(findings: *const Findings, expected: []const []const u8) !void {
        const equal = equal: {
            if (findings.count() != expected.len) break :equal false;

            for (expected, 0..) |text, index| {
                if (!std.mem.eql(u8, findings.message(@intCast(index)), text)) break :equal false;
            }

            break :equal true;
        };

        if (equal) return;

        findings.print();
        std.debug.print("expected {d} findings:\n", .{expected.len});

        for (expected) |text| std.debug.print("  {s}\n", .{text});

        return error.TestUnexpectedFindings;
    }

    pub fn print(findings: *const Findings) void {
        std.debug.print("found {d} findings:\n", .{findings.count()});

        for (0..findings.count()) |index| {
            const at = findings.span(@intCast(index));

            std.debug.print("  {d}..{d} {s}\n", .{
                at.offset,
                at.end(),
                findings.message(@intCast(index)),
            });
        }
    }
};

pub const limits: Limits = limits: {
    var held = Limits.default;

    held.diagnostic_count_max = 64;
    held.front.node_count_max = 1_024;
    held.front.token_count_max = 4_096;

    break :limits held;
};

const diagnostics_capacity: Diagnostics.Capacity = .{
    .related_count_max = limits.diagnostic_count_max,
    .row_count_max = limits.diagnostic_count_max,
    .text_bytes_max = limits.diagnostic_bytes_max,
};

pub const settings: Settings = settings: {
    var held = Settings.default;

    held.rules = .of_bits(std.math.maxInt(u128));

    break :settings held;
};

const Harness = struct {
    comments: scylla.ArrayType(Span),
    enclosures: Enclosures,
    expectation_aliases: classify.ExpectationAliases,
    fixes: Fixes,
    fronts: *Fronts,
    language: Language,
    lines: Index,
    macro_openers: MacroOpeners,
    flavor: scylla.SourceType.Flavor,
    pairs: Pairs,
    registry: Registry,
    suppressions: Regions,
    tables: Tables,
    token_index: TokenIndex,
    tokens: scylla.ArrayType(Token),

    fn init(
        harness: *Harness,
        gpa: std.mem.Allocator,
        language: Language,
        source_bytes_max: u32,
        rule: ?*const scylla.rule.Rule,
    ) !void {
        harness.language = language;
        harness.flavor = .plain;
        harness.comments = try .init(gpa, limits.front.token_count_max);
        harness.enclosures = try .init(gpa, limits.front.node_count_max);

        harness.fixes = try .init(gpa, .{
            .edit_count_max = limits.fix_edit_count_max,
            .fix_count_max = limits.diagnostic_count_max,
            .text_bytes_max = limits.diagnostic_bytes_max,
        });

        harness.fronts = try gpa.create(Fronts);

        try harness.fronts.init(gpa, &limits.front, .initOne(language), &.{});
        harness.lines = try .init(gpa, source_bytes_max + 1);
        harness.macro_openers = try .init(gpa);
        harness.pairs = try .init(gpa, limits.front.token_count_max);
        harness.registry = try .init(gpa, 1);

        if (rule) |held| harness.registry.register(held);

        harness.suppressions = try .init(gpa, limits.suppression_count_max);

        try harness.tables.init(gpa, .{
            .edge_count_max = limits.call_edge_count_max,
            .function_count_max = limits.function_count_max,
        });

        harness.token_index = try .init(gpa, limits.front.token_count_max);
        harness.tokens = try .init(gpa, limits.front.token_count_max);
    }

    fn deinit(harness: *Harness, gpa: std.mem.Allocator) void {
        harness.comments.deinit(gpa);
        harness.enclosures.deinit(gpa);
        harness.fixes.deinit(gpa);
        harness.fronts.deinit(gpa);
        gpa.destroy(harness.fronts);
        harness.lines.deinit(gpa);
        harness.macro_openers.deinit(gpa);
        harness.pairs.deinit(gpa);
        harness.registry.deinit(gpa);
        harness.suppressions.deinit(gpa);
        harness.tables.deinit(gpa);
        harness.token_index.deinit(gpa);
        harness.tokens.deinit(gpa);
        harness.* = undefined;
    }

    fn context_built(harness: *Harness, source: []const u8) !Context {
        try harness.lines.build(source);

        const source_type: scylla.SourceType = .{
            .flavor = harness.flavor,
            .language = harness.language,
        };

        const front = try harness.fronts.parse(source_type, source);
        const conventions = conventions_module.of_language(harness.language);

        harness.tokens.clear();
        harness.tokens.push_slice(front.tokens());
        classify.vocabulary(harness.language, source, harness.tokens.slice());

        const stream = harness.tokens.const_slice();

        assert(stream.len == front.tokens().len);

        try harness.pairs.build(source, stream);
        harness.tables.build(front, &conventions.returns());
        harness.enclosures.build(front, &harness.lines, source);
        harness.macro_openers.build(stream, conventions);
        harness.token_index.build(stream);
        harness.expectation_aliases = .of(harness.language, source, front.bindings());

        return .{
            .conventions = conventions,
            .enclosures = &harness.enclosures,
            .expectation_aliases = &harness.expectation_aliases,
            .front = front,
            .grammar = Grammar.of(harness.language),
            .lines = &harness.lines,
            .macro_openers = &harness.macro_openers,
            .pairs = &harness.pairs,
            .path = "",
            .registry = &harness.registry,
            .settings = &settings,
            .source = source,
            .tables = &harness.tables,
            .token_index = &harness.token_index,
            .tokens = stream,
        };
    }

    fn run(
        harness: *Harness,
        comptime module: type,
        source: []const u8,
        diagnostics: *Diagnostics,
    ) !void {
        const context = try harness.context_built(source);

        directives.scan(&harness.suppressions, &context, &harness.comments);
        harness.fixes.clear();

        var sink = Sink.init(&.{
            .applicability = null,
            .code = module.rule.code,
            .diagnostics = diagnostics,
            .file = scylla.FileID.of(0),
            .fixable = true,
            .fixes = &harness.fixes,
            .lines = &harness.lines,
            .rule_index = 0,
            .severity = module.rule.severity,
            .suppressions = &harness.suppressions,
        });

        module.run(&context, &sink);
    }
};

pub fn analyze(comptime module: type, language: Language, source: []const u8) !Findings {
    return analyze_of(module, .of(language), source);
}

pub fn analyze_stub(comptime module: type, source: []const u8) !Findings {
    const source_type: scylla.SourceType = .{ .flavor = .stub, .language = .python };
    return analyze_of(module, source_type, source);
}

fn analyze_of(comptime module: type, source_type: scylla.SourceType, source: []const u8) !Findings {
    comptime assert(@hasDecl(module, "rule"));
    comptime assert(@hasDecl(module, "run"));

    assert(source_type.valid());

    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();

    var harness: Harness = undefined;

    try harness.init(gpa, source_type.language, @intCast(source.len), &module.rule);
    defer harness.deinit(gpa);

    harness.flavor = source_type.flavor;

    var findings: Findings = .{
        .diagnostics = try .init(std.testing.allocator, diagnostics_capacity),
    };

    errdefer findings.deinit();

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try harness.run(module, source, &findings.diagnostics);

    return findings;
}

pub fn expect_stub_names(
    comptime module: type,
    source: []const u8,
    names: []const []const u8,
) !void {
    var findings = try analyze_stub(module, source);
    defer findings.deinit();

    if (findings.count() != names.len) findings.print();

    try std.testing.expectEqual(names.len, findings.count());

    for (names, 0..) |name, index| {
        const span = findings.span(@intCast(index));

        try std.testing.expectEqualStrings(name, source[span.offset..span.end()]);
    }
}

pub const stub_source = "from typing import Final, type_check_only\n\nSP: Final = 0x20\n\n\n" ++
    "class Element:\n    previousSibling: Element | None\n" ++
    "    def setIdAttributeNS(self, namespaceURI: str, localName: str) -> None: ...\n" ++
    "    def coords(self, tagOrId: str, /) -> list[float]: ...\n" ++
    "    def shorten(self, opt_str: str, max_lines: int) -> str: ...\n" ++
    "    def wrap(self, obj: object, max_width: int, /) -> str: ...\n\n\n" ++
    "@type_check_only\nclass _AbiInfo:\n    debug: bool\n";

pub fn expect_findings(
    comptime module: type,
    language: Language,
    source: []const u8,
    expected: []const []const u8,
) !void {
    var findings = try analyze(module, language, source);
    defer findings.deinit();

    try findings.expect_messages(expected);
}

pub fn expect_quiet(comptime module: type, language: Language, source: []const u8) !void {
    try expect_findings(module, language, source, &.{});
}

pub fn expect_spans(
    comptime module: type,
    language: Language,
    source: []const u8,
    expected: []const [2]u32,
) !void {
    var findings = try analyze(module, language, source);
    defer findings.deinit();

    const equal = equal: {
        if (findings.count() != expected.len) break :equal false;

        for (expected, 0..) |pair, index| {
            const at = findings.span(@intCast(index));
            if (at.offset != pair[0]) break :equal false;
            if (at.end() != pair[1]) break :equal false;
        }

        break :equal true;
    };

    if (equal) return;

    findings.print();

    return error.TestUnexpectedSpans;
}

pub fn expect_anchors(
    comptime module: type,
    language: Language,
    source: []const u8,
    expected: []const [2]u32,
) !void {
    var findings = try analyze(module, language, source);
    defer findings.deinit();

    if (findings.count() != expected.len) {
        findings.print();

        return error.TestUnexpectedAnchors;
    }

    for (expected, 0..) |pair, index| {
        const anchor = anchor_of(source, findings.span(@intCast(index)).offset);

        try std.testing.expectEqual(pair[0], anchor[0]);
        try std.testing.expectEqual(pair[1], anchor[1]);
    }
}

fn anchor_of(source: []const u8, offset: u32) [2]u32 {
    assert(offset <= source.len);

    var line: u32 = 1;
    var column: u32 = 1;

    for (source[0..offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;

            continue;
        }

        if (byte & 0xc0 != 0x80) column += 1;
    }

    return .{ line, column };
}

pub fn expect_fixed(
    comptime module: type,
    language: Language,
    source: []const u8,
    minimum: scylla.Fixes.Applicability,
    expected: []const u8,
) !void {
    const gpa = std.testing.allocator;
    const fixed = try fixed_of(module, language, source, minimum);
    defer gpa.free(fixed);

    try std.testing.expectEqualStrings(expected, fixed);
}

fn fixed_of(
    comptime module: type,
    language: Language,
    source: []const u8,
    minimum: scylla.Fixes.Applicability,
) ![]u8 {
    const gpa = std.testing.allocator;

    var current = try gpa.dupe(u8, source);
    errdefer gpa.free(current);

    for (0..limits.fix_pass_count_max) |_| {
        const next = switch (try fixed_pass(module, language, current, minimum)) {
            .converged => break,
            .fixed => |fixed| fixed,
        };

        gpa.free(current);
        current = next;
    }

    return current;
}

pub fn fixed_once(
    comptime module: type,
    language: Language,
    source: []const u8,
    minimum: scylla.Fixes.Applicability,
) ![]u8 {
    const gpa = std.testing.allocator;

    return switch (try fixed_pass(module, language, source, minimum)) {
        .converged => try gpa.dupe(u8, source),
        .fixed => |fixed| fixed,
    };
}

const Pass = union(enum) {
    converged,
    fixed: []u8,
};

fn fixed_pass(
    comptime module: type,
    language: Language,
    source: []const u8,
    minimum: scylla.Fixes.Applicability,
) !Pass {
    const gpa = std.testing.allocator;
    const target_bytes_max: u32 = @intCast(source.len * 2 + 4_096);

    var harness: Harness = undefined;

    try harness.init(gpa, language, target_bytes_max, &module.rule);
    defer harness.deinit(gpa);

    var diagnostics: Diagnostics = try .init(gpa, diagnostics_capacity);
    defer diagnostics.deinit(gpa);

    var target: scylla.Buffer = try .init(gpa, target_bytes_max);
    defer target.deinit(gpa);

    try harness.run(module, source, &diagnostics);

    const applied = harness.fixes.apply(&target, source, minimum) catch |err| switch (err) {
        error.EditsExhausted, error.TargetExhausted, error.TextExhausted => return .converged,
    };

    if (applied == 0) return .converged;
    return .{ .fixed = try gpa.dupe(u8, target.const_slice()) };
}

pub const Fixture = struct {
    context: Context,
    harness: Harness,
    scope: StaticAllocator.FreezeScope,
    static_allocator: StaticAllocator,

    pub fn init(fixture: *Fixture, language: Language, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        fixture.static_allocator = .init(std.testing.allocator);
        errdefer fixture.static_allocator.deinit();

        const gpa = fixture.static_allocator.allocator();

        try fixture.harness.init(gpa, language, @intCast(source.len), null);
        errdefer fixture.harness.deinit(gpa);

        fixture.scope = fixture.static_allocator.freeze_scope();
        errdefer fixture.scope.leave();

        fixture.context = try fixture.harness.context_built(source);

        assert(fixture.context.source.len == source.len);
    }

    pub fn deinit(fixture: *Fixture) void {
        const gpa = fixture.static_allocator.allocator();

        assert(fixture.context.source.len <= std.math.maxInt(u32));

        fixture.scope.leave();
        fixture.harness.deinit(gpa);
        fixture.static_allocator.deinit();
        fixture.* = undefined;
    }
};

fn lines_of(gpa: std.mem.Allocator, source: []const u8) !Index {
    var lines: Index = try .init(gpa, @as(u32, @intCast(source.len)) + 1);
    errdefer lines.deinit(gpa);

    try lines.build(source);

    assert(lines.count() > 0);

    return lines;
}
