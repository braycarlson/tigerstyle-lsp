const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Applicability = scylla.Fixes.Applicability;
const CodeSet = scylla.rule.CodeSet;
const Severity = scylla.Diagnostics.Severity;
const rule_count_max = scylla.limits.rule_count_max;

fixable: CodeSet,
rules: CodeSet,
safe_fixes: CodeSet,
severity: [rule_count_max]?Severity,
thresholds: Thresholds,
unsafe_fixes: CodeSet,

const Settings = @This();

pub const Thresholds = struct {
    assertions_per_function_min: u32,
    declaration_distance_max: u32,
    else_if_chain_max: u32,
    function_lines_max: u32,
    line_length_max: u32,
    nesting_depth_max: u32,
    parameters_max: u32,

    pub const default: Thresholds = .{
        .assertions_per_function_min = assertions_per_function_min_default,
        .declaration_distance_max = declaration_distance_max_default,
        .else_if_chain_max = else_if_chain_max_default,
        .function_lines_max = function_lines_max_default,
        .line_length_max = line_length_max_default,
        .nesting_depth_max = nesting_depth_max_default,
        .parameters_max = parameters_max_default,
    };

    pub const unset: Thresholds = .{
        .assertions_per_function_min = 0,
        .declaration_distance_max = 0,
        .else_if_chain_max = 0,
        .function_lines_max = 0,
        .line_length_max = 0,
        .nesting_depth_max = 0,
        .parameters_max = 0,
    };

    pub fn merged(base: Thresholds, over: Thresholds) Thresholds {
        var result: Thresholds = undefined;

        inline for (@typeInfo(Thresholds).@"struct".field_names) |name| {
            const value_over = @field(over, name);

            @field(result, name) = if (value_over == 0) @field(base, name) else value_over;
        }

        if (base.validate()) assert(result.validate());

        return result;
    }

    pub fn validate(thresholds: Thresholds) bool {
        inline for (@typeInfo(Thresholds).@"struct".field_names) |name| {
            if (@field(thresholds, name) == 0) return false;
        }

        return true;
    }
};

pub const default: Settings = .{
    .fixable = .of_bits(std.math.maxInt(u128)),
    .rules = .empty,
    .safe_fixes = .empty,
    .severity = @splat(null),
    .thresholds = .default,
    .unsafe_fixes = .empty,
};

const assertions_per_function_min_default: u32 = 2;
const declaration_distance_max_default: u32 = 5;
const else_if_chain_max_default: u32 = 3;
const function_lines_max_default: u32 = 70;
const line_length_max_default: u32 = 100;
const nesting_depth_max_default: u32 = 4;
const parameters_max_default: u32 = 7;

comptime {
    assert(Thresholds.default.validate());
    assert(!Thresholds.unset.validate());
}

fn applicability_of(settings: *const Settings, rule_index: u32) ?Applicability {
    assert(rule_index < rule_count_max);

    if (settings.unsafe_fixes.contains(rule_index)) return .unsafe;
    if (settings.safe_fixes.contains(rule_index)) return .safe;
    return null;
}

pub fn enables(settings: *const Settings, rule_index: u32) bool {
    assert(rule_index < rule_count_max);

    return settings.rules.contains(rule_index);
}

fn fixes(settings: *const Settings, rule_index: u32) bool {
    assert(rule_index < rule_count_max);

    return settings.fixable.contains(rule_index);
}

pub fn ignore(settings: *Settings, codes: CodeSet) void {
    const before = settings.rules;

    settings.rules = before.difference_with(codes);

    assert(settings.rules.intersect_with(codes).is_empty());
    assert(settings.rules.union_with(before.intersect_with(codes)).bits == before.bits);
}

fn severity_of(settings: *const Settings, rule_index: u32, fallback: Severity) Severity {
    assert(rule_index < rule_count_max);

    return settings.severity[rule_index] orelse fallback;
}

test Settings {
    var settings = default;

    settings.rules = .with_all(4);

    settings.ignore(.of_bits(0b0010));

    try std.testing.expect(settings.enables(0));
    try std.testing.expect(!settings.enables(1));
    try std.testing.expect(settings.fixes(1));
    try std.testing.expectEqual(null, settings.applicability_of(2));
    try std.testing.expect(settings.thresholds.validate());
}

test Thresholds {
    var over = Thresholds.unset;

    over.parameters_max = 9;

    const merged = Thresholds.default.merged(over);

    try std.testing.expectEqual(@as(u32, 9), merged.parameters_max);
    try std.testing.expectEqual(Thresholds.default.line_length_max, merged.line_length_max);
    try std.testing.expect(!Thresholds.unset.validate());
}

test "the defaults validate" {
    try std.testing.expect(Thresholds.default.validate());
}

test "a zero threshold is rejected" {
    var thresholds = Thresholds.default;

    thresholds.parameters_max = 0;

    try std.testing.expect(!thresholds.validate());
}

test "a severity override wins" {
    var settings = default;

    settings.severity[2] = .@"error";

    try std.testing.expectEqual(Severity.@"error", settings.severity_of(2, .warning));
    try std.testing.expectEqual(Severity.warning, settings.severity_of(3, .warning));
}

test "a merge keeps the base where the override is unset" {
    var over = Thresholds.unset;

    over.line_length_max = 120;

    const merged = Thresholds.default.merged(over);

    try std.testing.expectEqual(@as(u32, 120), merged.line_length_max);
    try std.testing.expectEqual(parameters_max_default, merged.parameters_max);
}
