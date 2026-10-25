const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");

const Texts = std.ArrayList([]const u8);

const Key = struct {
    path: []const u8,
    row: u32,
    rule: []const u8,

    fn order(left: Key, right: Key) std.math.Order {
        const path = std.mem.order(u8, left.path, right.path);
        if (path != .eq) return path;

        const row = std.math.order(left.row, right.row);
        if (row != .eq) return row;
        return std.mem.order(u8, left.rule, right.rule);
    }

    fn less(_: void, left: Key, right: Key) bool {
        return order(left, right) == .lt;
    }
};

const Label = struct {
    corpus: []const u8,
    path: []const u8,
    reproduces: bool,
    row: u32,
    rule: []const u8,
    verdict: []const u8,

    fn where_at(label: *const Label, gpa: std.mem.Allocator) ![]u8 {
        assert(label.rule.len > 0);

        return gpa.print("  {s} {s}/{s}:{d}", .{
            label.rule,
            label.corpus,
            label.path,
            label.row,
        });
    }

    fn key(label: *const Label) Key {
        return .{ .path = label.path, .row = label.row, .rule = label.rule };
    }
};

const Entry = struct {
    corpus: []const u8,
    path: []const u8,
    row: u32,
    rule: []const u8,
    text: []const u8,
    verdict: []const u8,

    fn key(entry: *const Entry) Key {
        return .{ .path = entry.path, .row = entry.row, .rule = entry.rule };
    }

    fn labelled(entry: *const Entry) bool {
        return std.mem.eql(u8, entry.verdict, "true") or std.mem.eql(u8, entry.verdict, "false");
    }
};

const Tally = struct {
    labelled: u32,
    truthful: u32,

    const empty: Tally = .{ .labelled = 0, .truthful = 0 };

    fn precision(tally: Tally) f64 {
        assert(tally.truthful <= tally.labelled);

        if (tally.labelled == 0) return 0.0;
        return @as(f64, @floatFromInt(tally.truthful)) / @as(f64, @floatFromInt(tally.labelled));
    }

    fn lower_bound(tally: Tally) f64 {
        assert(tally.truthful <= tally.labelled);

        if (tally.labelled == 0) return 0.0;

        const total: f64 = @floatFromInt(tally.labelled);
        const observed = tally.precision();
        const squared = confidence_z * confidence_z;
        const denominator = 1.0 + squared / total;
        const centre = observed + squared / (2.0 * total);

        const margin = confidence_z *
            @sqrt(observed * (1.0 - observed) / total + squared / (4.0 * total * total));

        return @max((centre - margin) / denominator, 0.0);
    }
};

const RuleTally = struct {
    rule: []const u8,
    tally: Tally,

    fn less(_: void, left: RuleTally, right: RuleTally) bool {
        return std.mem.order(u8, left.rule, right.rule) == .lt;
    }
};

const Found = struct {
    corpus: []const u8,
    keys: []const Key,

    fn contains(found: *const Found, key: Key) bool {
        const index = std.sort.binarySearch(Key, found.keys, key, Key.order);
        return index != null;
    }
};

const Floor = struct { []const u8, u32 };
const confidence_z: f64 = 1.959_964;
const coverage_min: usize = 10;
const evidence_min: u32 = 12;
const precision_lower_bound_min: f64 = 0.75;
const precision_target: f64 = 0.90;
const false_positives_still_standing: usize = 0;
const residue_still_standing: usize = 33;
const body_bytes_max = 1 << 24;
const below_floor = [_]Floor{};

const corpora = [_][]const u8{
    "alacritty",
    "axum",
    "bat",
    "bevy",
    "bootstrap",
    "bytes",
    "cargo",
    "clap",
    "cobra",
    "django",
    "express",
    "fastapi",
    "flask",
    "fzf",
    "ghostty",
    "httpx",
    "hyper",
    "libxev",
    "mach",
    "minio",
    "mypy",
    "numpy",
    "odin",
    "ols",
    "pandas",
    "pydantic",
    "regex",
    "requests",
    "rich",
    "ripgrep",
    "rust-analyzer",
    "serde",
    "sqlalchemy",
    "starship",
    "tigerbeetle",
    "tokio",
    "zig",
    "zig-clap",
    "zigimg",
    "zls",
    "zod",
};

fn binary(gpa: std.mem.Allocator, io: std.Io) !cli.Command {
    var command: cli.Command = try .init(gpa, io);
    errdefer command.deinit(gpa);

    try command.environment_set("TIGERSTYLE_NO_CACHE", "1");

    return command;
}

fn corpus_path(gpa: std.mem.Allocator, io: std.Io, parts: []const []const u8) ![]u8 {
    assert(parts.len > 0);

    const corpus_root = try cli.rooted(gpa, io, "corpus");
    defer gpa.free(corpus_root);

    var joined: Texts = .empty;
    defer joined.deinit(gpa);

    try joined.append(gpa, corpus_root);
    try joined.appendSlice(gpa, parts);

    return std.Io.Dir.path.join(gpa, joined.items);
}

fn fetched(gpa: std.mem.Allocator, io: std.Io) !bool {
    for (corpora) |name| {
        const checkout = try corpus_path(gpa, io, &.{name});
        defer gpa.free(checkout);

        if (!cli.is_directory(io, checkout)) return false;
    }

    return true;
}

fn read(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    const relative = try gpa.print("tests/fixtures/precision/{s}", .{name});
    defer gpa.free(relative);

    const path = try cli.rooted(gpa, io, relative);
    defer gpa.free(path);

    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(body_bytes_max)) catch |err| {
        std.debug.print("cannot read {s}: {t}\n", .{ path, err });

        return err;
    };
}

fn objects(gpa: std.mem.Allocator, body: []const u8) !Texts {
    var found: Texts = .empty;
    errdefer found.deinit(gpa);

    var depth: i32 = 0;
    var quoted = false;
    var escaped = false;
    var start: usize = 0;

    for (body, 0..) |byte, offset| {
        if (escaped) {
            escaped = false;

            continue;
        }

        if (quoted) {
            if (byte == '\\') escaped = true;
            if (byte == '"') quoted = false;

            continue;
        }

        switch (byte) {
            '"' => quoted = true,
            '{' => {
                depth += 1;

                if (depth == 2) start = offset;
            },
            '}' => {
                if (depth == 2) try found.append(gpa, body[start .. offset + 1]);

                depth -= 1;
            },
            else => {},
        }
    }

    return found;
}

fn field(object: []const u8, comptime key: []const u8) []const u8 {
    const marker = "\"" ++ key ++ "\":";

    const found = std.mem.find(u8, object, marker) orelse {
        std.debug.panic("{s} carries no {s}", .{ object, key });
    };

    const rest = std.mem.trimStart(u8, object[found + marker.len ..], &std.ascii.whitespace);

    if (std.mem.startsWith(u8, rest, "\"")) {
        const text = rest[1..];
        var escaped = false;

        for (text, 0..) |byte, offset| {
            if (escaped) {
                escaped = false;

                continue;
            }

            if (byte == '\\') escaped = true;
            if (byte == '"') return text[0..offset];
        }

        return text;
    }

    const end = std.mem.findAny(u8, rest, ",}\n") orelse rest.len;
    return std.mem.trim(u8, rest[0..end], &std.ascii.whitespace);
}

fn unescaped(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var rendered: std.ArrayList(u8) = try .initCapacity(gpa, text.len);
    errdefer rendered.deinit(gpa);

    var index: usize = 0;

    for (0..text.len + 1) |_| {
        if (index >= text.len) break;

        const byte = text[index];

        index += 1;

        if (byte != '\\') {
            rendered.appendAssumeCapacity(byte);

            continue;
        }

        if (index >= text.len) break;

        const escape = text[index];

        index += 1;

        rendered.appendAssumeCapacity(switch (escape) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => escape,
        });
    }

    assert(rendered.items.len <= text.len);

    return rendered.toOwnedSlice(gpa);
}

fn labels(gpa: std.mem.Allocator, io: std.Io) ![]Label {
    const body = try read(gpa, io, "labels.json");
    var found = try objects(gpa, body);
    var result = try gpa.alloc(Label, found.items.len);

    for (found.items, 0..) |object, index| {
        result[index] = .{
            .corpus = field(object, "corpus"),
            .path = try unescaped(gpa, field(object, "path")),
            .reproduces = std.mem.eql(u8, field(object, "reproduces"), "true"),
            .row = try std.fmt.parseUnsigned(u32, field(object, "row"), 10),
            .rule = field(object, "rule"),
            .verdict = field(object, "verdict"),
        };
    }

    assert(result.len == found.items.len);

    found.deinit(gpa);

    return result;
}

fn sample(gpa: std.mem.Allocator, io: std.Io) ![]Entry {
    const body = try read(gpa, io, "sample.json");
    var found = try objects(gpa, body);
    var result = try gpa.alloc(Entry, found.items.len);

    for (found.items, 0..) |object, index| {
        result[index] = .{
            .corpus = field(object, "corpus"),
            .path = try unescaped(gpa, field(object, "path")),
            .row = try std.fmt.parseUnsigned(u32, field(object, "row"), 10),
            .rule = field(object, "rule"),
            .text = try unescaped(gpa, field(object, "text")),
            .verdict = field(object, "verdict"),
        };
    }

    found.deinit(gpa);

    return result;
}

fn selection(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var rules: Texts = .empty;

    for (try labels(gpa, io)) |label| try rules.append(gpa, label.rule);
    for (try sample(gpa, io)) |entry| try rules.append(gpa, entry.rule);

    std.mem.sort([]const u8, rules.items, {}, cli.text_less);

    var unique: Texts = .empty;

    for (rules.items) |rule| {
        const last = if (unique.items.len == 0) "" else unique.items[unique.items.len - 1];

        if (!std.mem.eql(u8, last, rule)) try unique.append(gpa, rule);
    }

    assert(unique.items.len <= rules.items.len);

    return std.mem.join(gpa, ",", unique.items);
}

fn reported(gpa: std.mem.Allocator, io: std.Io) ![]Found {
    const chosen = try selection(gpa, io);
    var result = try gpa.alloc(Found, corpora.len);

    for (corpora, 0..) |name, index| {
        const checkout = try corpus_path(gpa, io, &.{name});

        var command = try binary(gpa, io);
        defer command.deinit(gpa);

        try command.arguments_add(gpa, &.{
            "check",
            "--isolated",
            "--preview",
            "--exit-zero",
            "--format",
            "concise",
            "--select",
            chosen,
            checkout,
        });

        const output = try command.output(gpa, io);
        const prefix = try gpa.print("{s}/", .{checkout});

        result[index] = .{ .corpus = name, .keys = try keys_parsed(gpa, output.stdout, prefix) };
    }

    return result;
}

fn keys_parsed(gpa: std.mem.Allocator, stdout: []const u8, prefix: []const u8) ![]Key {
    assert(prefix.len > 0);

    var keys: std.ArrayList(Key) = .empty;
    var lines: cli.Lines = .init(stdout);

    for (0..stdout.len + 1) |_| {
        var line = lines.next() orelse break;

        for (0..line.len + 1) |_| {
            if (!std.mem.startsWith(u8, line, prefix)) break;

            line = line[prefix.len..];
        }

        try keys.append(gpa, parsed(line) orelse continue);
    }

    std.mem.sort(Key, keys.items, {}, Key.less);

    var unique: std.ArrayList(Key) = .empty;

    for (keys.items, 0..) |key, index| {
        if (index > 0) {
            if (Key.order(keys.items[index - 1], key) == .eq) continue;
        }

        try unique.append(gpa, key);
    }

    return unique.items;
}

fn parsed(line: []const u8) ?Key {
    const head, const rest = std.mem.cut(u8, line, ": ") orelse return null;
    const count = std.mem.countScalar(u8, head, ':') + 1;
    if (count < 3) return null;

    const column_split = std.mem.findScalarLast(u8, head, ':').?;
    const row_split = std.mem.findScalarLast(u8, head[0..column_split], ':').?;

    const row = std.fmt.parseUnsigned(u32, head[row_split + 1 .. column_split], 10) catch {
        return null;
    };

    var words = std.mem.splitScalar(u8, rest, ' ');

    for (0..rest.len + 1) |_| {
        const word = words.next() orelse break;

        if (std.mem.startsWith(u8, word, "TS")) {
            return .{ .path = head[0..row_split], .row = row, .rule = word };
        }
    }

    return null;
}

fn found_of(found: []const Found, corpus: []const u8) *const Found {
    for (found) |*held| {
        if (std.mem.eql(u8, held.corpus, corpus)) return held;
    }

    std.debug.panic("{s} is not a reported corpus", .{corpus});
}

fn tallies(gpa: std.mem.Allocator, entries: []const Entry) ![]RuleTally {
    var result: std.ArrayList(RuleTally) = .empty;

    for (entries) |*entry| {
        const tally = try tally_of(gpa, &result, entry.rule);

        if (!entry.labelled()) continue;

        tally.labelled += 1;

        if (std.mem.eql(u8, entry.verdict, "true")) tally.truthful += 1;
    }

    std.mem.sort(RuleTally, result.items, {}, RuleTally.less);

    return result.items;
}

fn tally_of(gpa: std.mem.Allocator, list: *std.ArrayList(RuleTally), rule: []const u8) !*Tally {
    assert(rule.len > 0);

    for (list.items) |*held| {
        if (std.mem.eql(u8, held.rule, rule)) return &held.tally;
    }

    try list.append(gpa, .{ .rule = rule, .tally = .empty });

    return &list.items[list.items.len - 1].tally;
}

fn drawn(entries: []const Entry, rule: []const u8) usize {
    var count: usize = 0;

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.rule, rule)) count += 1;
    }

    assert(count <= entries.len);

    return count;
}

fn expect_none(message: []const u8, lines: []const []const u8) !void {
    assert(message.len > 0);

    if (lines.len > 0) std.debug.print("{s}:\n", .{message});

    for (lines) |line| std.debug.print("{s}\n", .{line});

    try std.testing.expectEqual(0, lines.len);
}

test "the labelled sample is reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const entries = try sample(gpa, std.testing.io);
    const tallied = try tallies(gpa, entries);

    std.log.info("per-rule precision over the ported sample:", .{});

    for (tallied) |held| {
        std.log.info("  {s}: {d:.0}% ({d}/{d} labelled, {d} drawn), 95% lower bound {d:.0}%", .{
            held.rule,
            100.0 * held.tally.precision(),
            held.tally.truthful,
            held.tally.labelled,
            drawn(entries, held.rule),
            100.0 * held.tally.lower_bound(),
        });
    }

    try std.testing.expect(tallied.len > 0);
}

test "every sampled finding carries a verdict" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();

    var waiting: Texts = .empty;

    for (try sample(gpa, std.testing.io)) |*entry| {
        if (entry.labelled()) continue;

        try waiting.append(gpa, try gpa.print("  {s} {s}/{s}:{d} {s}", .{
            entry.rule,
            entry.corpus,
            entry.path,
            entry.row,
            entry.text,
        }));
    }

    try expect_none(
        "an unlabelled sample entry counts as neither truth nor noise, so it silently lifts " ++
            "every rule it belongs to",
        waiting.items,
    );
}

test "every sampled rule carries enough labels to judge it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const entries = try sample(gpa, std.testing.io);

    var thin: Texts = .empty;

    for (try tallies(gpa, entries)) |held| {
        const count = drawn(entries, held.rule);
        const floor = @min(coverage_min, count);
        if (held.tally.labelled >= floor) continue;

        try thin.append(gpa, try gpa.print("  {s}: {d} labelled of {d} drawn, " ++
            "{d} needed", .{ held.rule, held.tally.labelled, count, floor }));
    }

    try expect_none("a rule judged on a handful of findings is not judged at all", thin.items);
}

test "no sampled rule reports more noise than truth" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();

    var failures: Texts = .empty;

    for (try tallies(gpa, try sample(gpa, std.testing.io))) |held| {
        const tally = held.tally;
        if (tally.labelled == 0) continue;

        if (tally.labelled >= evidence_min) {
            if (tally.lower_bound() >= precision_lower_bound_min) continue;

            const line = try gpa.print("  {s}: {d:.0}% over {d} labels, " ++
                "95% lower bound {d:.0}% (floor {d:.0}%)", .{
                held.rule,
                100.0 * tally.precision(),
                tally.labelled,
                100.0 * tally.lower_bound(),
                100.0 * precision_lower_bound_min,
            });

            try failures.append(gpa, line);

            continue;
        }

        if (tally.precision() >= precision_target) continue;

        try failures.append(gpa, try gpa.print("  {s}: {d:.0}% over {d} labels, " ++
            "too few to bound (target {d:.0}%)", .{
            held.rule,
            100.0 * tally.precision(),
            tally.labelled,
            100.0 * precision_target,
        }));
    }

    try expect_none(
        "a rule this noisy is one a user turns off, and a rule a user turns off protects nobody",
        failures.items,
    );
}

test "every sampled rule meets the precision target" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();

    var short: Texts = .empty;

    for (try tallies(gpa, try sample(gpa, std.testing.io))) |held| {
        const tally = held.tally;
        if (tally.labelled == 0) continue;
        if (tally.precision() >= precision_target) continue;

        try short.append(gpa, try gpa.print("  {s}: {d:.0}% over {d} labels, " ++
            "{d} false positive(s) (target {d:.0}%)", .{
            held.rule,
            100.0 * tally.precision(),
            tally.labelled,
            tally.labelled - tally.truthful,
            100.0 * precision_target,
        }));
    }

    try expect_none(
        "these rules are honest enough to ship but not yet at the target",
        short.items,
    );
}

test "the rules under the evidence floor are named exactly" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();

    var under: std.ArrayList(Floor) = .empty;

    for (try tallies(gpa, try sample(gpa, std.testing.io))) |held| {
        const tally = held.tally;
        if (tally.labelled == 0) continue;
        if (tally.labelled >= evidence_min) continue;

        try under.append(gpa, .{ held.rule, tally.labelled });
    }

    try std.testing.expectEqual(below_floor.len, under.items.len);

    for (below_floor, under.items) |named, found| {
        try std.testing.expectEqualStrings(named[0], found[0]);
        try std.testing.expectEqual(named[1], found[1]);
    }
}

test "a rule under the floor has drawn its whole population" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const io = std.testing.io;
    if (!try fetched(gpa, io)) return error.SkipZigTest;

    const found = try reported(gpa, io);
    const entries = try sample(gpa, io);

    var short: Texts = .empty;

    for (below_floor) |floor| {
        var population: usize = 0;

        for (corpora) |name| {
            for (found_of(found, name).keys) |key| {
                if (std.mem.eql(u8, key.rule, floor[0])) population += 1;
            }
        }

        if (population <= drawn(entries, floor[0])) continue;

        const line = try gpa.print("  {s}: {d} drawn of {d} reported; " ++
            "draw the rest before excusing it", .{
            floor[0],
            drawn(entries, floor[0]),
            population,
        });

        try short.append(gpa, line);
    }

    try expect_none(
        "a rule under the floor with findings left undrawn is not short of evidence, it is " ++
            "short of work",
        short.items,
    );
}

test "every label names a declared corpus" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();

    var orphans: Texts = .empty;

    for (try labels(gpa, std.testing.io)) |label| {
        const known = for (corpora) |name| {
            if (std.mem.eql(u8, name, label.corpus)) break true;
        } else false;

        if (known) continue;

        try orphans.append(gpa, try gpa.print("  {s} names {s}", .{
            label.rule,
            label.corpus,
        }));
    }

    try expect_none(
        "a label against a corpus nothing clones can never reproduce",
        try sorted_unique(gpa, orphans.items),
    );
}

test "every label points at a file that exists" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const io = std.testing.io;
    if (!try fetched(gpa, io)) return error.SkipZigTest;

    var missing: Texts = .empty;

    for (try labels(gpa, io)) |*label| {
        const path = try corpus_path(gpa, io, &.{ label.corpus, label.path });

        if (!cli.is_file(io, path)) try missing.append(gpa, try label.where_at(gpa));
    }

    try expect_none(
        "a label against a file the pinned commit does not hold can never reproduce",
        try sorted_unique(gpa, missing.items),
    );
}

test "every sampled finding is still reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const io = std.testing.io;
    if (!try fetched(gpa, io)) return error.SkipZigTest;

    const found = try reported(gpa, io);

    var lost: Texts = .empty;

    for (try sample(gpa, io)) |*entry| {
        if (found_of(found, entry.corpus).contains(entry.key())) continue;

        try lost.append(gpa, try gpa.print("  {s} {s}/{s}:{d}", .{
            entry.rule,
            entry.corpus,
            entry.path,
            entry.row,
        }));
    }

    try expect_none(
        "the sample holds only findings tigerstyle-lsp reported when it was drawn, so a lost " ++
            "one is a rule that narrowed without the sample being redrawn",
        lost.items,
    );
}

test "every violation the port kept is still reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const io = std.testing.io;
    if (!try fetched(gpa, io)) return error.SkipZigTest;

    const found = try reported(gpa, io);

    var lost: Texts = .empty;

    for (try labels(gpa, io)) |*label| {
        if (!label.reproduces) continue;
        if (!std.mem.eql(u8, label.verdict, "true")) continue;
        if (found_of(found, label.corpus).contains(label.key())) continue;

        try lost.append(gpa, try label.where_at(gpa));
    }

    try expect_none(
        "each line below is a real defect this linter used to catch and no longer does. " ++
            "narrowing a rule to quiet a false positive is only worth it if these stay empty",
        lost.items,
    );
}

test "the known false positives only ever get fewer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const io = std.testing.io;
    if (!try fetched(gpa, io)) return error.SkipZigTest;

    const found = try reported(gpa, io);

    var standing: Texts = .empty;

    for (try labels(gpa, io)) |*label| {
        if (!std.mem.eql(u8, label.verdict, "false")) continue;
        if (!found_of(found, label.corpus).contains(label.key())) continue;

        try standing.append(gpa, try label.where_at(gpa));
    }

    std.log.info("{d} findings the regression set judged wrong are still reported:", .{
        standing.items.len,
    });

    for (standing.items) |line| std.log.info("{s}", .{line});

    try std.testing.expect(standing.items.len <= false_positives_still_standing);
    try std.testing.expect(standing.items.len >= false_positives_still_standing);
}

test "the residue the port left only ever gets smaller" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const io = std.testing.io;
    if (!try fetched(gpa, io)) return error.SkipZigTest;

    const found = try reported(gpa, io);

    var residue: Texts = .empty;

    for (try labels(gpa, io)) |*label| {
        if (found_of(found, label.corpus).contains(label.key())) continue;

        try residue.append(gpa, try label.where_at(gpa));
    }

    std.log.info("{d} labels the predecessor recorded do not reproduce here:", .{
        residue.items.len,
    });

    for (residue.items) |line| std.log.info("{s}", .{line});

    try std.testing.expect(residue.items.len <= residue_still_standing);
    try std.testing.expect(residue.items.len >= residue_still_standing);
}

fn sorted_unique(gpa: std.mem.Allocator, lines: [][]const u8) ![]const []const u8 {
    std.mem.sort([]const u8, lines, {}, cli.text_less);

    var unique: Texts = .empty;

    for (lines, 0..) |line, index| {
        if (index > 0) {
            if (std.mem.eql(u8, lines[index - 1], line)) continue;
        }

        try unique.append(gpa, line);
    }

    assert(unique.items.len <= lines.len);

    return unique.items;
}
