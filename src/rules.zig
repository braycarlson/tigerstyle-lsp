const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const catalog = @import("rules/catalog.zig");
const coverage = @import("rules/coverage.zig");
const languages = @import("languages.zig");
const scan = @import("scan.zig");
const Analysis = @import("analysis.zig");
const CodeSet = scylla.rule.CodeSet;
const Context = @import("rules/context.zig");
const Diagnostic = scylla.Diagnostics.Diagnostic;
const Diagnostics = scylla.Diagnostics;
const Document = @import("document.zig");
const Fixes = scylla.Fixes;
const Language = scylla.Language;
const Limits = @import("limits.zig");
const Regions = scylla.suppress.Regions;
const Registry = scylla.rule.Registry;
const Rule = scylla.rule.Rule;
const Selection = scylla.rule.Selection;
const Settings = @import("settings.zig");
const Severity = scylla.Diagnostics.Severity;
const Sink = scylla.rule.Sink;
const StaticAllocator = scylla.StaticAllocator;
const Timings = @import("timing.zig").Timings;

registry: Registry,
runner: Runner,

const Rules = @This();

pub const Tables = struct {
    diagnostics: *Diagnostics,
    fixes: *Fixes,
    suppressions: *Regions,
};

const Runner = scylla.rule.RunnerType(Context, &runs);

const runs = runs: {
    var held: [catalog.rule_count]*const fn (*const Context, *Sink) void = undefined;

    for (catalog.modules, &held) |module, *run_function| {
        assert(@hasDecl(module, "run"));

        run_function.* = &module.run;
    }

    const result = held;

    break :runs result;
};

pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Rules {
    var registry = try catalog.registry_init(gpa);
    errdefer registry.deinit(gpa);

    var runner: Runner = try .init(gpa, catalog.rule_count);

    for (0..catalog.rule_count) |index| {
        const rule = registry.at(@intCast(index));

        runner.register(coverage.language_mask(rule.code), @intCast(index));
    }

    assert(runner.count() == catalog.rule_count);
    assert(registry.count() == catalog.rule_count);

    return .{ .registry = registry, .runner = runner };
}

pub fn deinit(rules: *Rules, gpa: std.mem.Allocator) void {
    assert(rules.registry.count() == catalog.rule_count);

    rules.runner.deinit(gpa);
    rules.registry.deinit(gpa);
    rules.* = undefined;
}

pub fn at(rules: *const Rules, index: u32) *const Rule {
    assert(index < rules.count());

    return rules.registry.at(index);
}

pub fn defaults(rules: *const Rules) CodeSet {
    var enabled: CodeSet = .empty;

    for (rules.registry.slice(), 0..) |*rule, index| {
        if (rule.group != .stable) continue;
        if (!rule.default_on) continue;

        enabled.insert(@intCast(index));
    }

    assert(enabled.count() > 0);
    assert(enabled.count() <= rules.count());

    return enabled;
}

pub fn count(rules: *const Rules) u32 {
    const held = rules.registry.count();

    assert(held == catalog.rule_count);

    return held;
}

pub fn find(rules: *const Rules, code: []const u8) ?*const Rule {
    const found = rules.registry.find(code) orelse return null;

    assert(std.mem.eql(u8, found.code, code));

    return found;
}

pub fn find_name(rules: *const Rules, name: []const u8) ?*const Rule {
    const found = rules.registry.find_name(name) orelse return null;

    assert(std.mem.eql(u8, found.name, name));

    return found;
}

pub fn of(rules: *const Rules, diagnostic: *const Diagnostic) ?*const Rule {
    const index = diagnostic.rule orelse return null;
    return rules.at(index);
}

pub fn run(
    rules: *const Rules,
    io: std.Io,
    language: Language,
    context: *const Context,
    tables: Tables,
    timings: *Timings,
) void {
    assert(languages.linted_set.contains(language));
    assert(rules.runner.count() == catalog.rule_count);

    const settings = context.settings;

    const policy: Runner.Policy = .{
        .enabled = settings.rules,
        .fixable = settings.fixable,
        .safe_fixes = settings.safe_fixes,
        .severity = settings.severity,
        .unsafe_fixes = settings.unsafe_fixes,
    };

    const bound: Runner.Tables = .{
        .diagnostics = tables.diagnostics,
        .file = scylla.FileID.of(0),
        .fixes = tables.fixes,
        .io = io,
        .language = languages.bit(language),
        .lines = context.lines,
        .registry = &rules.registry,
        .suppressions = tables.suppressions,
    };

    rules.runner.run(&bound, &policy, context, timings.rule_nanoseconds());
}

test Rules {
    const gpa = std.testing.allocator;

    var rules: Rules = try .init(gpa);
    defer rules.deinit(gpa);

    const bounded = rules.find("TS006") orelse return error.TestUnexpectedResult;
    const named = rules.find_name(bounded.name) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u32, 57), rules.count());
    try std.testing.expectEqual(bounded, named);
    try std.testing.expectEqualStrings("TS001", rules.at(0).code);
    try std.testing.expectEqual(null, rules.find("TS999"));
}

test defaults {
    const gpa = std.testing.allocator;

    var rules: Rules = try .init(gpa);
    defer rules.deinit(gpa);

    var selection: Selection = try .init(gpa, Limits.selector_count_max);
    defer selection.deinit(gpa);

    const enabled = rules.defaults();

    try std.testing.expectEqual(selection.resolve(&rules.registry).bits, enabled.bits);
    try std.testing.expect(enabled.contains(rules.registry.index_of("TS001").?));
    try std.testing.expect(!enabled.contains(rules.registry.index_of("TS050").?));
}

test "a registered language runs the rules unmodified" {
    const gpa = std.testing.allocator;
    const source = "fn read_sector() {\n    loop {\n        let max_count = 1;\n    }\n}\n";

    var rules: Rules = try .init(gpa);
    defer rules.deinit(gpa);

    var analysis: Analysis = undefined;

    try analysis.init(gpa, std.testing.io, &Limits.default.analysis());
    defer analysis.deinit(gpa);

    var document: Document = try .init(gpa, &Limits.default.document());
    defer document.deinit(gpa);

    var selection: Selection = try .init(gpa, Limits.selector_count_max);
    defer selection.deinit(gpa);

    var settings = Settings.default;

    settings.rules = selection.resolve(&rules.registry);
    document.state.language = .rust;

    try document.text.text_replace(source);
    analysis.run(document.entry(), &rules, &settings);

    const found = found: {
        for (document.state.diagnostics.slice()) |diagnostic| {
            if (std.mem.eql(u8, diagnostic.code, "TS006")) break :found true;
        }

        break :found false;
    };

    try std.testing.expect(found);
}

test "a code parses to its index" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();

    var rules: Rules = try .init(gpa);
    defer rules.deinit(gpa);

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try std.testing.expectEqual(@as(?u32, 0), rules.registry.index_of("TS001"));
    try std.testing.expectEqual(@as(?u32, null), rules.registry.index_of("XX001"));
    try std.testing.expectEqual(@as(?u32, null), rules.registry.index_of("TS"));
    try std.testing.expectEqual(@as(?u32, null), rules.registry.index_of("TSxyz"));
    try std.testing.expectEqualStrings("TS001", rules.at(0).code);
}

const predecessor_error_codes: []const []const u8 = &.{
    "TS001",
    "TS005",
    "TS007",
    "TS010",
    "TS019",
    "TS021",
    "TS028",
    "TS036",
    "TS052",
};

const predecessor_information_codes: []const []const u8 = &.{
    "TS004",
    "TS025",
    "TS026",
    "TS029",
    "TS031",
    "TS037",
    "TS038",
    "TS040",
    "TS042",
    "TS043",
    "TS044",
    "TS045",
    "TS046",
    "TS047",
    "TS048",
    "TS053",
    "TS054",
    "TS055",
    "TS057",
};

test "the default severities match the predecessor" {
    const gpa = std.testing.allocator;

    var rules: Rules = try .init(gpa);
    defer rules.deinit(gpa);

    var error_count: u32 = 0;
    var information_count: u32 = 0;

    for (0..rules.count()) |index| {
        const rule = rules.at(@intCast(index));

        const expected: Severity = expected: {
            if (scan.word_in(predecessor_error_codes, rule.code)) {
                error_count += 1;

                break :expected .@"error";
            }

            if (scan.word_in(predecessor_information_codes, rule.code)) {
                information_count += 1;

                break :expected .information;
            }

            break :expected .warning;
        };

        try std.testing.expectEqual(expected, rule.severity);
    }

    try std.testing.expectEqual(predecessor_error_codes.len, error_count);
    try std.testing.expectEqual(predecessor_information_codes.len, information_count);
}

test "every registered rule has a distinct code" {
    const gpa = std.testing.allocator;

    var rules: Rules = try .init(gpa);
    defer rules.deinit(gpa);

    try std.testing.expect(rules.count() > 20);
    try std.testing.expect(rules.find("TS002") != null);
    try std.testing.expect(rules.find("TS999") == null);
}
