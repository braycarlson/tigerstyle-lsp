const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const catalog = @import("catalog.zig");
const languages = @import("../languages.zig");
const Language = scylla.Language;
const Registry = scylla.rule.Registry;

const Gap = struct {
    code: []const u8,
    language: Language,
    reason: []const u8,
    support: Support,
};

const Problem = enum {
    language_unregistered,
    reason_empty,
    rule_unregistered,
};

const Support = enum {
    inapplicable,
    unimplemented,

    pub fn text(support: Support) []const u8 {
        const result: []const u8 = switch (support) {
            .inapplicable => "Inapplicable",
            .unimplemented => "Unimplemented",
        };

        assert(result.len > 0);
        assert(std.ascii.isUpper(result[0]));

        return result;
    }
};

const Violation = struct {
    gap_index: u32,
    problem: Problem,
};

pub const gaps = [_]Gap{
    .{
        .code = "TS007",
        .language = .go,
        .reason = "Go has no eval or exec; there is no runtime string-to-code path to report",
        .support = .inapplicable,
    },
    .{
        .code = "TS007",
        .language = .odin,
        .reason = "Odin has no eval or exec; there is no runtime string-to-code path to report",
        .support = .inapplicable,
    },
    .{
        .code = "TS007",
        .language = .rust,
        .reason = "Rust has no eval or exec; there is no runtime string-to-code path to report",
        .support = .inapplicable,
    },
    .{
        .code = "TS007",
        .language = .zig,
        .reason = "Zig has no eval or exec; there is no runtime string-to-code path to report",
        .support = .inapplicable,
    },
    .{
        .code = "TS009",
        .language = .go,
        .reason = "Go has no exception handler, so there is no bare one to catch",
        .support = .inapplicable,
    },
    .{
        .code = "TS009",
        .language = .javascript,
        .reason = "JavaScript has no typed catch; every catch clause catches everything, so " ++
            "none is barer than another",
        .support = .inapplicable,
    },
    .{
        .code = "TS009",
        .language = .odin,
        .reason = "Odin has no exception handler; a procedure returns an error value beside its " ++
            "result",
        .support = .inapplicable,
    },
    .{
        .code = "TS009",
        .language = .rust,
        .reason = "Rust has no exception handler, so there is no bare one to catch",
        .support = .inapplicable,
    },
    .{
        .code = "TS009",
        .language = .typescript,
        .reason = "TypeScript has no typed catch; every catch clause catches everything, so " ++
            "none is barer than another",
        .support = .inapplicable,
    },
    .{
        .code = "TS009",
        .language = .zig,
        .reason = "Zig has no exception handler; an error union is returned, not caught",
        .support = .inapplicable,
    },
    .{
        .code = "TS010",
        .language = .go,
        .reason = "Go has no exception handler, so there is no empty one to catch",
        .support = .inapplicable,
    },
    .{
        .code = "TS010",
        .language = .javascript,
        .reason = "JavaScript has no pass statement; an empty catch is reported by TS028",
        .support = .inapplicable,
    },
    .{
        .code = "TS010",
        .language = .odin,
        .reason = "Odin has no exception handler, so there is no empty one to catch",
        .support = .inapplicable,
    },
    .{
        .code = "TS010",
        .language = .rust,
        .reason = "Rust has no exception handler, so there is no empty one to catch",
        .support = .inapplicable,
    },
    .{
        .code = "TS010",
        .language = .typescript,
        .reason = "TypeScript has no pass statement; an empty catch is reported by TS028",
        .support = .inapplicable,
    },
    .{
        .code = "TS010",
        .language = .zig,
        .reason = "Zig has no exception handler, so there is no empty one to catch",
        .support = .inapplicable,
    },
    .{
        .code = "TS011",
        .language = .odin,
        .reason = "Odin has no wildcard import; an import binds one package name",
        .support = .inapplicable,
    },
    .{
        .code = "TS011",
        .language = .zig,
        .reason = "Zig has no wildcard import; @import binds one name",
        .support = .inapplicable,
    },
    .{
        .code = "TS013",
        .language = .go,
        .reason = "Go has no global statement; a binding never reaches out of its scope by keyword",
        .support = .inapplicable,
    },
    .{
        .code = "TS013",
        .language = .odin,
        .reason = "Odin has no global statement; a binding never reaches out of its scope by " ++
            "keyword",
        .support = .inapplicable,
    },
    .{
        .code = "TS013",
        .language = .rust,
        .reason = "Rust has no global statement; a binding never reaches out of its scope by " ++
            "keyword",
        .support = .inapplicable,
    },
    .{
        .code = "TS013",
        .language = .zig,
        .reason = "Zig has no global statement; a binding never reaches out of its scope by " ++
            "keyword",
        .support = .inapplicable,
    },
    .{
        .code = "TS014",
        .language = .go,
        .reason = "Go has no nested named function; a func literal is a lambda, which TS015 " ++
            "reports",
        .support = .inapplicable,
    },
    .{
        .code = "TS014",
        .language = .zig,
        .reason = "Zig has no nested function; a fn is legal only at container scope, so every " ++
            "inner function is a struct member",
        .support = .inapplicable,
    },
    .{
        .code = "TS015",
        .language = .zig,
        .reason = "Zig's anonymous function is a named fn on an anonymous struct, " ++
            "`struct { fn lessThan(...) ... }.lessThan`, which TigerBeetle itself writes 145 " ++
            "times as the comparator idiom; the naming sentence the rule cites is met by the fn " ++
            "name, so the shape is not reported",
        .support = .inapplicable,
    },
    .{
        .code = "TS018",
        .language = .go,
        .reason = "Go has no macro system; go:generate runs a program rather than expanding text",
        .support = .inapplicable,
    },
    .{
        .code = "TS018",
        .language = .javascript,
        .reason = "JavaScript has no macro system; there is no expansion to weigh",
        .support = .inapplicable,
    },
    .{
        .code = "TS018",
        .language = .odin,
        .reason = "Odin has no macro system; a #directive instructs the compiler rather than " ++
            "expanding text",
        .support = .inapplicable,
    },
    .{
        .code = "TS018",
        .language = .python,
        .reason = "Python has no macro system; a decorator is an ordinary call, not an expansion",
        .support = .inapplicable,
    },
    .{
        .code = "TS018",
        .language = .typescript,
        .reason = "TypeScript has no macro system; there is no expansion to weigh",
        .support = .inapplicable,
    },
    .{
        .code = "TS018",
        .language = .zig,
        .reason = "Zig has comptime rather than a textual macro expander",
        .support = .inapplicable,
    },
    .{
        .code = "TS019",
        .language = .javascript,
        .reason = "JavaScript has no pointer type; every name binds a reference the runtime owns",
        .support = .inapplicable,
    },
    .{
        .code = "TS019",
        .language = .typescript,
        .reason = "TypeScript has no pointer type; every name binds a reference the runtime owns",
        .support = .inapplicable,
    },
    .{
        .code = "TS021",
        .language = .javascript,
        .reason = "JavaScript has no goto; break and continue with a label are the only " ++
            "non-local jumps",
        .support = .inapplicable,
    },
    .{
        .code = "TS021",
        .language = .odin,
        .reason = "Odin has no goto; break and continue with a label are the only non-local jumps",
        .support = .inapplicable,
    },
    .{
        .code = "TS021",
        .language = .python,
        .reason = "Python has no goto; break, continue, and return are the only non-local jumps",
        .support = .inapplicable,
    },
    .{
        .code = "TS021",
        .language = .rust,
        .reason = "Rust has no goto; its loop labels break and continue to an enclosing loop only",
        .support = .inapplicable,
    },
    .{
        .code = "TS021",
        .language = .typescript,
        .reason = "TypeScript has no goto; break and continue with a label are the only " ++
            "non-local jumps",
        .support = .inapplicable,
    },
    .{
        .code = "TS021",
        .language = .zig,
        .reason = "Zig has no goto; its loop labels break and continue to an enclosing loop only",
        .support = .inapplicable,
    },
    .{
        .code = "TS027",
        .language = .javascript,
        .reason = "JavaScript numbers are IEEE doubles and bigint is arbitrary precision, so " ++
            "there is no sized type to require",
        .support = .inapplicable,
    },
    .{
        .code = "TS027",
        .language = .python,
        .reason = "Python integers are arbitrary precision, so there is no sized type to require",
        .support = .inapplicable,
    },
    .{
        .code = "TS027",
        .language = .typescript,
        .reason = "TypeScript numbers are IEEE doubles and bigint is arbitrary precision, so " ++
            "there is no sized type to require",
        .support = .inapplicable,
    },
    .{
        .code = "TS028",
        .language = .python,
        .reason = "Python signals failure by raising, which TS009 and TS010 already cover",
        .support = .inapplicable,
    },
    .{
        .code = "TS030",
        .language = .go,
        .reason = "Go requires braces on every if, so an unbraced one does not parse",
        .support = .inapplicable,
    },
    .{
        .code = "TS030",
        .language = .python,
        .reason = "Python blocks are indentation, not braces",
        .support = .inapplicable,
    },
    .{
        .code = "TS030",
        .language = .rust,
        .reason = "Rust requires braces on every if, so an unbraced one does not parse",
        .support = .inapplicable,
    },
    .{
        .code = "TS033",
        .language = .javascript,
        .reason = "a JavaScript parameter carries no type, so two adjacent parameters cannot be " ++
            "compared",
        .support = .inapplicable,
    },
    .{
        .code = "TS035",
        .language = .javascript,
        .reason = "JavaScript has no build step; a check of the platform or the environment is " ++
            "a runtime branch",
        .support = .inapplicable,
    },
    .{
        .code = "TS035",
        .language = .python,
        .reason = "Python has no build step; a check of the platform or the interpreter version " ++
            "is a runtime branch",
        .support = .inapplicable,
    },
    .{
        .code = "TS035",
        .language = .typescript,
        .reason = "TypeScript has no build step of its own; a check of the platform or the " ++
            "environment is a runtime branch",
        .support = .inapplicable,
    },
    .{
        .code = "TS040",
        .language = .go,
        .reason = "integer division is spelled with the same operator as float division; " ++
            "telling them apart needs type inference this linter does not do",
        .support = .inapplicable,
    },
    .{
        .code = "TS040",
        .language = .javascript,
        .reason = "integer division is spelled with the same operator as float division; " ++
            "telling them apart needs type inference this linter does not do",
        .support = .inapplicable,
    },
    .{
        .code = "TS040",
        .language = .odin,
        .reason = "integer division is spelled with the same operator as float division; " ++
            "telling them apart needs type inference this linter does not do",
        .support = .inapplicable,
    },
    .{
        .code = "TS040",
        .language = .python,
        .reason = "the // operator already names the rounding, and telling / apart needs type " ++
            "inference this linter does not do",
        .support = .inapplicable,
    },
    .{
        .code = "TS040",
        .language = .typescript,
        .reason = "integer division is spelled with the same operator as float division; " ++
            "telling them apart needs type inference this linter does not do",
        .support = .inapplicable,
    },
    .{
        .code = "TS041",
        .language = .javascript,
        .reason = "JavaScript has no Option or Result to stack; a value is returned or an error " ++
            "is thrown",
        .support = .inapplicable,
    },
    .{
        .code = "TS044",
        .language = .go,
        .reason = "a Go struct holds only fields; its methods are declared outside it, so the " ++
            "order is not the author's to choose",
        .support = .inapplicable,
    },
    .{
        .code = "TS044",
        .language = .odin,
        .reason = "an Odin struct holds only fields; its procedures are declared beside it, so " ++
            "the order is not the author's to choose",
        .support = .inapplicable,
    },
    .{
        .code = "TS046",
        .language = .javascript,
        .reason = "JavaScript frees by garbage collection rather than at a defer, so the " ++
            "paired-allocation shape has no syntax to anchor on",
        .support = .inapplicable,
    },
    .{
        .code = "TS046",
        .language = .python,
        .reason = "Python frees by refcount rather than at a defer, so the paired-allocation " ++
            "shape has no syntax to anchor on",
        .support = .inapplicable,
    },
    .{
        .code = "TS046",
        .language = .rust,
        .reason = "Rust frees on drop rather than at a defer, so the paired-allocation shape " ++
            "this rule looks for has no syntax to anchor on",
        .support = .inapplicable,
    },
    .{
        .code = "TS046",
        .language = .typescript,
        .reason = "TypeScript frees by garbage collection rather than at a defer, so the " ++
            "paired-allocation shape has no syntax to anchor on",
        .support = .inapplicable,
    },
    .{
        .code = "TS051",
        .language = .javascript,
        .reason = "JavaScript has no pointer type; every name binds a reference the runtime owns",
        .support = .inapplicable,
    },
    .{
        .code = "TS051",
        .language = .python,
        .reason = "Python has no pointer type; every name binds a reference the runtime owns",
        .support = .inapplicable,
    },
    .{
        .code = "TS051",
        .language = .typescript,
        .reason = "TypeScript has no pointer type; every name binds a reference the runtime owns",
        .support = .inapplicable,
    },
    .{
        .code = "TS052",
        .language = .odin,
        .reason = "Odin has no way to recover from a panic; an assertion failure ends the process",
        .support = .inapplicable,
    },
    .{
        .code = "TS052",
        .language = .zig,
        .reason = "Zig has no way to recover from a panic; the panic handler does not return",
        .support = .inapplicable,
    },
    .{
        .code = "TS054",
        .language = .go,
        .reason = "Go has no suspension point inside a function; a goroutine blocks on a " ++
            "channel, but the function's own control flow never yields to its caller",
        .support = .inapplicable,
    },
    .{
        .code = "TS054",
        .language = .odin,
        .reason = "Odin has no async, await, or coroutine; a procedure runs to completion",
        .support = .inapplicable,
    },
    .{
        .code = "TS055",
        .language = .go,
        .reason = "the Go grammar requires the trailing comma when the closing delimiter starts " ++
            "a new line, so a wrapped list without one does not compile",
        .support = .inapplicable,
    },
    .{
        .code = "TS056",
        .language = .go,
        .reason = "a Go channel is bounded by construction: make(chan T, n) names the bound " ++
            "and an unbuffered channel holds nothing",
        .support = .inapplicable,
    },
    .{
        .code = "TS056",
        .language = .javascript,
        .reason = "JavaScript has no queue type; an array used as a queue grows on push, which " ++
            "TS016 reports",
        .support = .inapplicable,
    },
    .{
        .code = "TS056",
        .language = .typescript,
        .reason = "TypeScript has no queue type; an array used as a queue grows on push, which " ++
            "TS016 reports",
        .support = .inapplicable,
    },
};

pub fn gap_of(code: []const u8, language: Language) ?*const Gap {
    assert(code.len > 0);

    for (&gaps) |*gap| {
        if (gap.language != language) continue;
        if (!std.mem.eql(u8, gap.code, code)) continue;

        assert(gap.reason.len > 0);

        return gap;
    }

    return null;
}

pub fn language_mask(code: []const u8) u64 {
    assert(code.len > 0);

    var mask: u64 = 0;

    for (languages.linted) |language| {
        if (gap_of(code, language) == null) mask |= @as(u64, 1) << languages.bit(language);
    }

    assert(@popCount(mask) <= languages.linted.len);

    return mask;
}

fn validate(registry: *const Registry) u32 {
    assert(registry.count() > 0);

    const checked = validated(&gaps, registry);

    assert(checked == gaps.len);

    return checked;
}

fn validated(table: []const Gap, registry: *const Registry) u32 {
    assert(table.len > 0);
    assert(violation_of(table, registry) == null);

    return @intCast(table.len);
}

fn violation_of(table: []const Gap, registry: *const Registry) ?Violation {
    assert(table.len > 0);
    assert(registry.count() > 0);

    for (table, 0..) |*gap, gap_index| {
        const problem = problem_of(gap, registry) orelse continue;
        return .{ .gap_index = @intCast(gap_index), .problem = problem };
    }

    return null;
}

fn problem_of(gap: *const Gap, registry: *const Registry) ?Problem {
    const rule = registry.find(gap.code) orelse return .rule_unregistered;

    assert(std.mem.eql(u8, rule.code, gap.code));

    if (!languages.linted_set.contains(gap.language)) return .language_unregistered;
    if (gap.reason.len == 0) return .reason_empty;
    return null;
}

test "every gap names a registered rule and language" {
    var registry = try catalog.registry_init(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, gaps.len), validate(&registry));
    try std.testing.expect(gaps.len > 0);
}

test "every gap is named once" {
    for (gaps, 0..) |gap, index| {
        for (gaps[0..index]) |earlier| {
            if (earlier.language != gap.language) continue;

            try std.testing.expect(!std.mem.eql(u8, earlier.code, gap.code));
        }
    }
}

test language_mask {
    const mask = language_mask("TS007");
    var every_language: u64 = 0;

    for (languages.linted) |language| every_language |= @as(u64, 1) << languages.bit(language);

    try std.testing.expectEqual(@as(u64, 0), mask & (@as(u64, 1) << languages.bit(.go)));
    try std.testing.expect(mask & (@as(u64, 1) << languages.bit(.python)) != 0);
    try std.testing.expectEqual(every_language, language_mask("TS002"));
    try std.testing.expectEqual(languages.linted.len, @popCount(every_language));
}

test "a gap naming an unregistered rule is refused" {
    var registry = try catalog.registry_init(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);

    const refused = [_]Gap{.{
        .code = "TS999",
        .language = .rust,
        .reason = "there is no such rule",
        .support = gaps[0].support,
    }};

    const expected: Violation = .{ .gap_index = 0, .problem = .rule_unregistered };

    try std.testing.expectEqual(expected, violation_of(&refused, &registry));
}

test "a gap naming an unregistered language is refused" {
    var registry = try catalog.registry_init(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);

    const refused = [_]Gap{.{
        .code = gaps[0].code,
        .language = .css,
        .reason = "css is not a registered language",
        .support = gaps[0].support,
    }};

    const expected: Violation = .{ .gap_index = 0, .problem = .language_unregistered };

    try std.testing.expectEqual(expected, violation_of(&refused, &registry));
}

test "a gap with no reason is refused" {
    var registry = try catalog.registry_init(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);

    const refused = [_]Gap{.{
        .code = gaps[0].code,
        .language = gaps[0].language,
        .reason = "",
        .support = gaps[0].support,
    }};

    const expected: Violation = .{ .gap_index = 0, .problem = .reason_empty };

    try std.testing.expectEqual(expected, violation_of(&refused, &registry));
}
