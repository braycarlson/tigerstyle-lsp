const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const PRNG = scylla.testing.PRNG;
const Session = @import("testing/session.zig");

const Bodies = struct {
    texts: [body_variant_count][]u8,

    fn init(gpa: std.mem.Allocator) !Bodies {
        var bodies: Bodies = undefined;
        var built: u32 = 0;
        errdefer for (bodies.texts[0..built]) |text| gpa.free(text);

        for (&bodies.texts, 0..) |*text, variant| {
            text.* = try body(gpa, @intCast(variant));
            built += 1;
        }

        assert(built == body_variant_count);

        return bodies;
    }

    fn deinit(bodies: *Bodies, gpa: std.mem.Allocator) void {
        for (bodies.texts) |text| gpa.free(text);

        bodies.* = undefined;
    }

    fn at(bodies: *const Bodies, variant: u32) []const u8 {
        assert(variant < body_variant_count);

        return bodies.texts[variant];
    }
};

const body_variant_count: u32 = 6;
const cycle_count: u32 = 600;
const document_count: u32 = 70;
const resident_growth_max: u64 = 4 * 1024 * 1024;

const corrupt_bodies = [_][]const u8{
    "",
    "{",
    "}",
    "[]",
    "null",
    "{\"jsonrpc\":}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":}",
    "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{}}}",
    "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":[]}",
    "{\"jsonrpc\":\"2.0\",\"id\":\"\\ud800\",\"method\":\"shutdown\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":99999999999999999999,\"method\":\"textDocument/hover\"}",
};

fn below(random: *PRNG, bound: u32) u32 {
    assert(bound > 0);

    return random.int_inclusive(u32, bound - 1);
}

fn body(gpa: std.mem.Allocator, variant: u32) ![]u8 {
    assert(variant < body_variant_count);

    return switch (variant) {
        0 => gpa.dupe(u8, "fn main() {}\\n"),
        1 => gpa.dupe(u8, "fn main() {\\n   let maxValue = 1;\\n}\\n"),
        2 => repeated(gpa, "fn wide() {\\n", "   let value = 1;\\n", 90, "}\\n"),
        3 => repeated(gpa, "", "   ", 4_000, ""),
        4 => repeated(gpa, "", "x", 1_100_000, ""),
        else => gpa.dupe(u8, "fn main() {\\n    loop {\\n    }\\n}\\n"),
    };
}

fn repeated(
    gpa: std.mem.Allocator,
    head: []const u8,
    unit: []const u8,
    count: u32,
    tail: []const u8,
) ![]u8 {
    assert(unit.len > 0);
    assert(count > 0);

    const text = try gpa.alloc(u8, head.len + unit.len * count + tail.len);

    @memcpy(text[0..head.len], head);

    for (0..count) |index| @memcpy(text[head.len + index * unit.len ..][0..unit.len], unit);

    @memcpy(text[text.len - tail.len ..], tail);

    return text;
}

fn uri_of(buffer: []u8, index: u32) ![]const u8 {
    assert(index < document_count);

    return std.mem.print(buffer, "file:///soak/{d}.rs", .{index});
}

fn change(
    session: *Session,
    gpa: std.mem.Allocator,
    uri: []const u8,
    version: u32,
    text: []const u8,
) !void {
    const message = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":{d}}}," ++
            "\"contentChanges\":[{{\"text\":\"{s}\"}}]}}}}",
        .{ uri, version, text },
    );

    defer gpa.free(message);

    try session.send(message);
}

fn change_ranged(
    session: *Session,
    gpa: std.mem.Allocator,
    uri: []const u8,
    version: u32,
    random: *PRNG,
) !void {
    const line = below(random, 8);
    const start = below(random, 16);
    const end = start + below(random, 8);

    const text = switch (below(random, 4)) {
        0 => "",
        1 => "value",
        2 => "\n    let other = 2;\n",
        else => "maxValue",
    };

    const message = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":{d}}}," ++
            "\"contentChanges\":[{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}}," ++
            "\"end\":{{\"line\":{d},\"character\":{d}}}}},\"text\":\"{s}\"}}]}}}}",
        .{ uri, version, line, start, line, end, text },
    );

    defer gpa.free(message);

    try session.send(message);
}

fn close(session: *Session, gpa: std.mem.Allocator, uri: []const u8) !void {
    const message = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}}}}}}",
        .{uri},
    );

    defer gpa.free(message);

    try session.send(message);
}

fn save(session: *Session, gpa: std.mem.Allocator, uri: []const u8) !void {
    const message = try gpa.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\"," ++
            "\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}}}}}}",
        .{uri},
    );

    defer gpa.free(message);

    try session.send(message);
}

fn warm(session: *Session, gpa: std.mem.Allocator, random: *PRNG, bodies: *const Bodies) !void {
    var buffer: [64]u8 = undefined;

    for (0..body_variant_count) |variant_index| {
        const variant: u32 = @intCast(variant_index);
        const text = bodies.at(variant);

        for (0..document_count) |document_index| {
            const index: u32 = @intCast(document_index);
            const uri = try uri_of(&buffer, index);

            try Session.send_open(session, gpa, uri, text);
            try change(session, gpa, uri, variant + 2, text);
            try change_ranged(session, gpa, uri, variant + 2, random);
            try Session.barrier(session, gpa, 10_000 + (variant * document_count) + index);
        }
    }

    for (0..document_count) |document_index| {
        const uri = try uri_of(&buffer, @intCast(document_index));

        try save(session, gpa, uri);
        try close(session, gpa, uri);
    }

    try Session.barrier(session, gpa, 9_999);
}

fn resident_of(session: *const Session, gpa: std.mem.Allocator, io: std.Io) !u64 {
    if (!Session.resident_measured) return 0;

    const resident = try Session.resident_bytes(gpa, io, session.identifier());

    assert(resident > 0);

    return resident;
}

fn cycle_run(
    session: *Session,
    gpa: std.mem.Allocator,
    random: *PRNG,
    bodies: *const Bodies,
    cycle: u32,
) !void {
    var buffer: [64]u8 = undefined;
    const uri = try uri_of(&buffer, below(random, document_count));

    switch (below(random, 5)) {
        0 => try Session.send_open(session, gpa, uri, bodies.at(below(random, body_variant_count))),
        1 => try change(session, gpa, uri, cycle + 2, bodies.at(below(random, body_variant_count))),
        2 => try change_ranged(session, gpa, uri, cycle + 2, random),
        3 => try save(session, gpa, uri),
        else => try close(session, gpa, uri),
    }

    try Session.barrier(session, gpa, 1_000 + cycle);
}

test "a long session holds its memory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var bodies: Bodies = try .init(gpa);
    defer bodies.deinit(gpa);

    var random: PRNG = .init(0x5EED_1234_ABCD_9876);
    var session: Session = undefined;

    try session.start(gpa, io);
    defer session.deinit();

    const response = try Session.initialize(&session, gpa);

    gpa.free(response);

    try warm(&session, gpa, &random, &bodies);

    var buffer: [64]u8 = undefined;

    for (0..document_count) |document_index| {
        const uri = try uri_of(&buffer, @intCast(document_index));

        try Session.send_open(&session, gpa, uri, "fn main() {\\n    let value = 1;\\n}\\n");
    }

    try Session.barrier(&session, gpa, 2);

    const resident_before = try resident_of(&session, gpa, io);

    for (0..cycle_count) |cycle| try cycle_run(&session, gpa, &random, &bodies, @intCast(cycle));

    const resident_after = try resident_of(&session, gpa, io);

    try session.send("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"shutdown\"}");

    const shutdown = try session.receive(gpa);

    gpa.free(shutdown);

    try session.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var finished = try session.finish(gpa);
    defer finished.deinit(gpa);

    try std.testing.expectEqual(@as(i32, 0), finished.code);

    if (!Session.resident_measured) return;

    if (resident_after > resident_before + resident_growth_max) {
        std.debug.print("resident bytes grew from {d} to {d}\n", .{
            resident_before,
            resident_after,
        });

        return error.TestUnexpectedResult;
    }
}

test "a document past the finding limit reports truncation" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    const response = try Session.initialize(&session, gpa);

    gpa.free(response);

    const text = try repeated(gpa, "fn main() {\\n", "   let value = 1;\\n", 2_000, "}\\n");
    defer gpa.free(text);

    try Session.send_open(&session, gpa, "file:///many.rs", text);

    const notification = try session.receive(gpa);
    defer gpa.free(notification);

    try std.testing.expect(Session.contains(notification, "were truncated"));

    var finished = try session.finish(gpa);

    finished.deinit(gpa);
}

test "corrupt bodies keep the session alive" {
    const gpa = std.testing.allocator;
    var random: PRNG = .init(0x0FF1_CE00_1234_5678);
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    const response = try Session.initialize(&session, gpa);

    gpa.free(response);

    for (corrupt_bodies, 0..) |corrupt, cycle| {
        try session.send(corrupt);
        try Session.barrier(&session, gpa, 2_000 + @as(u32, @intCast(cycle)));
    }

    for (0..200) |cycle| {
        var hover = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/hover\",".* ++
            "\"params\":{\"textDocument\":{\"uri\":\"file:///a.rs\"}}}".*;

        const offset = below(&random, hover.len);

        hover[offset] = @intCast(32 + below(&random, 90));

        try session.send(&hover);
        try Session.barrier(&session, gpa, 3_000 + @as(u32, @intCast(cycle)));
    }

    try session.send("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"shutdown\"}");

    const shutdown = try session.receive(gpa);

    gpa.free(shutdown);

    try session.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var finished = try session.finish(gpa);
    defer finished.deinit(gpa);

    try std.testing.expectEqual(@as(i32, 0), finished.code);
}

test "a corrupt frame ends the session without tripping the guard" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;

    try session.start(gpa, std.testing.io);
    defer session.deinit();

    const response = try Session.initialize(&session, gpa);

    gpa.free(response);

    try session.send_raw("Content-Length: not-a-number\r\n\r\n", "{}");

    var finished = try session.finish(gpa);
    defer finished.deinit(gpa);

    try std.testing.expect(Session.contains(finished.stderr, "the transport failed"));
}
