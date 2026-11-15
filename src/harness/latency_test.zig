const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Clock = scylla.timing.Clock;
const Session = @import("session.zig");
const Line = std.ArrayList(u8);

const Replay = struct {
    lines: std.ArrayList(Line),

    fn init(gpa: std.mem.Allocator) !Replay {
        var replay: Replay = .{ .lines = .empty };
        errdefer replay.deinit(gpa);

        for (0..function_count) |index| {
            var number: [16]u8 = undefined;
            const digits = try std.mem.print(&number, "{d}", .{index});
            const function = try std.mem.replaceOwned(u8, gpa, template, "%d", digits);
            defer gpa.free(function);

            var lines = std.mem.splitScalar(u8, function[0 .. function.len - 1], '\n');

            for (0..function.len) |_| {
                const held = lines.next() orelse break;
                var line: Line = .empty;
                errdefer line.deinit(gpa);

                try line.appendSlice(gpa, held);
                try replay.lines.append(gpa, line);
            }
        }

        assert(replay.lines.items.len == function_count * 7);

        return replay;
    }

    fn deinit(replay: *Replay, gpa: std.mem.Allocator) void {
        for (replay.lines.items) |*line| line.deinit(gpa);

        replay.lines.deinit(gpa);
        replay.* = undefined;
    }

    fn byte_count(replay: *const Replay) usize {
        var count: usize = 0;

        for (replay.lines.items) |line| count += line.items.len + 1;

        assert(count >= replay.lines.items.len);

        return count;
    }

    fn edit(replay: *Replay, gpa: std.mem.Allocator, index: u32) ![]u8 {
        assert(index < edit_count);

        const line = line_of(.{ .count = @intCast(replay.lines.items.len), .index = index });

        return switch (index % 3) {
            0 => replay.insert(gpa, line, insertion),
            1 => replay.replace(gpa, .{ .line = line, .width = insertion.len }, replacement),
            else => replay.replace(gpa, .{ .line = line, .width = replacement.len }, ""),
        };
    }

    fn insert(replay: *Replay, gpa: std.mem.Allocator, line: u32, inserted: []const u8) ![]u8 {
        assert(line < replay.lines.items.len);
        assert(inserted.len > 0);

        try replay.lines.items[line].insertSlice(gpa, 0, inserted);

        return change_of(gpa, .{ .end = 0, .line = line, .start = 0 }, inserted);
    }

    fn replace(
        replay: *Replay,
        gpa: std.mem.Allocator,
        options: struct { line: u32, width: u32 },
        inserted: []const u8,
    ) ![]u8 {
        assert(options.line < replay.lines.items.len);
        assert(replay.lines.items[options.line].items.len >= options.width);

        try replay.lines.items[options.line].replaceRange(gpa, 0, options.width, inserted);

        return change_of(
            gpa,
            .{ .end = options.width, .line = options.line, .start = 0 },
            inserted,
        );
    }

    fn text(replay: *const Replay, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();

        for (replay.lines.items) |line| {
            try out.writer.writeAll(line.items);
            try out.writer.writeByte('\n');
        }

        return out.toOwnedSlice();
    }
};

const ceiling_microseconds: u64 = 250_000;
const edit_count = 500;
const function_count = 4_000;
const insertion = "    ";
const replacement = "\t";
const stride = 97;

const template = "fn helper_%d(value: u32) -> u32 {\n    if value > 0 {\n        return value;\n" ++
    "    }\n\n    0\n}\n";

const uri = "file:///replay.rs";

fn line_of(options: struct { count: u32, index: u32 }) u32 {
    assert(options.count > 0);

    const cycle = @divFloor(options.index, 3);
    const line = (cycle * stride) % options.count;

    assert(line < options.count);

    return line;
}

fn change_of(
    gpa: std.mem.Allocator,
    options: struct { end: u32, line: u32, start: u32 },
    text: []const u8,
) ![]u8 {
    assert(options.start <= options.end);

    const written = try escaped(gpa, text);
    defer gpa.free(written);

    return gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"" ++ uri ++ "\",\"version\":2}}," ++
            "\"contentChanges\":[{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}}," ++
            "\"end\":{{\"line\":{d},\"character\":{d}}}}},\"text\":\"{s}\"}}]}}}}",
        .{ options.line, options.start, options.line, options.end, written },
    );
}

fn escaped(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    for (text) |byte| {
        switch (byte) {
            '"' => try out.writer.writeAll("\\\""),
            '\\' => try out.writer.writeAll("\\\\"),
            '\n' => try out.writer.writeAll("\\n"),
            '\r' => try out.writer.writeAll("\\r"),
            '\t' => try out.writer.writeAll("\\t"),
            else => try out.writer.writeByte(byte),
        }
    }

    return out.toOwnedSlice();
}

fn percentile(sorted: []const u64, options: struct { denominator: u32, numerator: u32 }) u64 {
    assert(sorted.len > 0);
    assert(options.numerator <= options.denominator);

    const position = @divFloor(sorted.len * options.numerator, options.denominator);
    const clamped = @min(position, sorted.len - 1);

    assert(clamped < sorted.len);

    return sorted[clamped];
}

fn turnaround(session: *Session, gpa: std.mem.Allocator, io: std.Io, change: []const u8) !u64 {
    assert(change.len > 0);

    const clock: Clock = .init(io);

    try session.send(change);

    const published = try session.receive(gpa);
    defer gpa.free(published);

    const microseconds = @divFloor(clock.nanoseconds(), std.time.ns_per_us);

    try std.testing.expect(Session.contains(.{ .part = "publishDiagnostics", .text = published }));

    return microseconds;
}

test "five hundred edits hold their turnaround" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var replay: Replay = try .init(gpa);
    defer replay.deinit(gpa);

    try std.testing.expect(replay.byte_count() < (1 << 20));

    var session: Session = undefined;

    try session.start(gpa, io);
    defer session.deinit();

    var turnarounds: [edit_count]u64 = undefined;

    try replayed(&session, gpa, io, &replay, &turnarounds);
    try shutdown(&session, gpa);

    std.mem.sort(u64, &turnarounds, {}, std.sort.asc(u64));

    const p99 = percentile(&turnarounds, .{ .denominator = 100, .numerator = 99 });

    if (std.testing.environ.containsConstant("TIGERSTYLE_BENCH")) {
        const p50 = percentile(&turnarounds, .{ .denominator = 2, .numerator = 1 });

        std.debug.print(
            "{{\n  \"bytes\": {d},\n  \"edits\": {d},\n  \"p50_microseconds\": {d},\n" ++
                "  \"p99_microseconds\": {d}\n}}\n",
            .{ replay.byte_count(), edit_count, p50, p99 },
        );
    }

    if (p99 > ceiling_microseconds) {
        std.debug.print("the p99 turnaround is {d}us, over the {d}us ceiling\n", .{
            p99,
            ceiling_microseconds,
        });

        return error.TestUnexpectedResult;
    }
}

fn replayed(
    session: *Session,
    gpa: std.mem.Allocator,
    io: std.Io,
    replay: *Replay,
    turnarounds: *[edit_count]u64,
) !void {
    const response = try Session.initialize(session, gpa);

    gpa.free(response);

    const text = try replay.text(gpa);
    defer gpa.free(text);

    const opened_text = try escaped(gpa, text);
    defer gpa.free(opened_text);

    try Session.send_open(session, gpa, .{ .text = opened_text, .uri = uri });

    const opened = try session.receive(gpa);
    defer gpa.free(opened);

    try std.testing.expect(Session.contains(.{ .part = "publishDiagnostics", .text = opened }));

    for (turnarounds, 0..) |*elapsed, index| {
        const change = try replay.edit(gpa, @intCast(index));
        defer gpa.free(change);

        elapsed.* = try turnaround(session, gpa, io, change);
    }
}

fn shutdown(session: *Session, gpa: std.mem.Allocator) !void {
    try session.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}");

    const response = try session.receive(gpa);
    defer gpa.free(response);

    try std.testing.expect(Session.contains(.{ .part = "\"result\":null", .text = response }));
    try session.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var finished = try session.finish(gpa);
    defer finished.deinit(gpa);

    if (finished.code != 0) std.debug.print("{s}\n", .{finished.stderr});

    try std.testing.expectEqual(@as(i32, 0), finished.code);
}
