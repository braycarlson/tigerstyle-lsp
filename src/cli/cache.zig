const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const cli = @import("../config/options.zig");
const languages = @import("../linter/languages.zig");
const Cache = scylla.Cache;
const Draft = @import("../config/draft.zig");
const Limits = @import("../limits.zig");
const Registry = scylla.rule.Registry;
const Rules = @import("../rules.zig");
const Settings = @import("../linter/settings.zig");
const Stat = scylla.path.Stat;
pub const directory_default = ".tigerstyle_cache";
pub const magic = "TIGERSC";

comptime {
    assert(magic.len < Cache.magic_bytes);
}

pub fn build_stamp(io: std.Io) ?Stat {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = std.process.executablePath(io, &buffer) catch return null;

    assert(length > 0);
    assert(length <= buffer.len);

    return scylla.path.stat_of(io, buffer[0..length]);
}

pub fn key_of(draft: *const Draft, registry: *const Registry, build: ?Stat) u64 {
    assert(registry.count() > 0);

    if (build) |held| assert(held.nanoseconds < std.time.ns_per_s);

    var hasher = std.hash.Fnv1a_64.init();

    hashed_settings(&hasher, &draft.settings(null, registry));

    for (languages.linted) |language| {
        hashed_settings(&hasher, &draft.settings(language, registry));
    }

    var ignores = draft.file_ignore_patterns();

    for (0..ignores.remaining) |_| {
        const ignore = ignores.next() orelse break;

        hashed_u128(&hasher, ignore.codes.bits);
        hasher.update(ignore.pattern);
    }

    assert(ignores.remaining == 0);

    hashed_u64(&hasher, @intFromBool(draft.selection.preview.enabled));
    hasher.update(cli.version);

    if (build) |held| hashed_stat(&hasher, held);

    return hasher.final();
}

pub fn directory_named(named: ?[]const u8) ?[]const u8 {
    const held = named orelse return null;
    if (held.len == 0) return null;

    assert(held.len > 0);

    return held;
}

fn hashed_settings(hasher: *std.hash.Fnv1a_64, settings: *const Settings) void {
    const thresholds = settings.thresholds;

    const values = [_]u32{
        thresholds.assertions_per_function_min,
        thresholds.declaration_distance_max,
        thresholds.else_if_chain_max,
        thresholds.function_lines_max,
        thresholds.line_length_max,
        thresholds.nesting_depth_max,
        thresholds.parameters_max,
    };

    const sets = [_]scylla.rule.CodeSet{
        settings.fixable,
        settings.rules,
        settings.safe_fixes,
        settings.unsafe_fixes,
    };

    for (values) |value| hashed_u64(hasher, value);
    for (sets) |set| hashed_u128(hasher, set.bits);

    for (settings.severity) |severity| {
        const level: u64 = if (severity) |held| @bitCast(held.lsp_code()) else 0;

        hashed_u64(hasher, level);
    }

    const names = &settings.parameter_exempt_types;

    hashed_u64(hasher, names.count());

    for (0..names.count()) |index| {
        const name = names.at(@intCast(index));

        hashed_u64(hasher, name.len);
        hasher.update(name);
    }

    assert(settings.severity.len == scylla.limits.rule_count_max);
}

fn hashed_stat(hasher: *std.hash.Fnv1a_64, stat: Stat) void {
    assert(stat.nanoseconds >= 0);
    assert(stat.nanoseconds < std.time.ns_per_s);

    hashed_u64(hasher, stat.mode);
    hashed_u64(hasher, @bitCast(stat.nanoseconds));
    hashed_u64(hasher, @bitCast(stat.seconds));
    hashed_u64(hasher, stat.size);
}

fn hashed_u64(hasher: *std.hash.Fnv1a_64, value: u64) void {
    var bytes: [@sizeOf(u64)]u8 = undefined;

    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn hashed_u128(hasher: *std.hash.Fnv1a_64, value: u128) void {
    var bytes: [@sizeOf(u128)]u8 = undefined;

    std.mem.writeInt(u128, &bytes, value, .little);
    hasher.update(&bytes);
}

test "the magic fits the cache header" {
    try std.testing.expect(magic.len < Cache.magic_bytes);
}

test key_of {
    const gpa = std.testing.allocator;
    var rules: Rules = try .init(gpa);
    defer rules.deinit(gpa);

    var draft: Draft = try .init(gpa, Limits.default.draft());
    defer draft.deinit(gpa);

    const first = key_of(&draft, &rules.registry, null);

    try std.testing.expectEqual(first, key_of(&draft, &rules.registry, null));

    const built: Stat = .{ .mode = 0o755, .nanoseconds = 5, .seconds = 1, .size = 30 };
    const rebuilt: Stat = .{ .mode = 0o755, .nanoseconds = 6, .seconds = 1, .size = 30 };
    const built_key = key_of(&draft, &rules.registry, built);

    try std.testing.expectEqual(built_key, key_of(&draft, &rules.registry, built));
    try std.testing.expect(built_key != first);
    try std.testing.expect(built_key != key_of(&draft, &rules.registry, rebuilt));

    draft.selection.preview.enabled = !draft.selection.preview.enabled;

    try std.testing.expect(first != key_of(&draft, &rules.registry, null));
}

test directory_named {
    try std.testing.expectEqual(null, directory_named(null));
    try std.testing.expectEqual(null, directory_named(""));
    try std.testing.expectEqualStrings("cache", directory_named("cache").?);
}
