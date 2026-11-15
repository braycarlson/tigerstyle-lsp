const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");
const Workspace = @import("workspace.zig");

const Edit = struct {
    body: []const u8,
    name: []const u8,
};

const camel_body = "fn helper() {\n    let maxValue = 1;\n}\n";
const edit_delay_milliseconds = 50;
const oversized_bytes = 2 << 20;
const settle_milliseconds = 600;

fn watched(
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace: *Workspace,
    edit: Edit,
) !cli.Output {
    assert(edit.name.len > 0);

    return watched_as(gpa, io, workspace, "concise", edit);
}

fn watched_as(
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace: *Workspace,
    format: []const u8,
    edit: Edit,
) !cli.Output {
    assert(format.len > 0);
    assert(edit.name.len > 0);

    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "lint", "--watch", "--format", format, workspace.root });
    command.environment_remove("FORCE_COLOR");
    command.environment_remove("NO_COLOR");

    var running = try command.spawn(io);
    errdefer running.kill(io);

    try io.sleep(.fromMilliseconds(settle_milliseconds), .awake);
    try io.sleep(.fromMilliseconds(edit_delay_milliseconds), .awake);
    _ = try workspace.write(.{ .body = edit.body, .name = edit.name });

    try io.sleep(.fromMilliseconds(settle_milliseconds), .awake);

    return running.stop(gpa, io);
}

fn contains(options: struct { part: []const u8, text: []const u8 }) bool {
    assert(options.part.len > 0);

    return std.mem.find(u8, options.text, options.part) != null;
}

fn expect_guarded(output: *const cli.Output) !void {
    const tripped = contains(.{ .part = "allocation guard tripped", .text = output.stderr });

    if (tripped) std.debug.print("{s}\n", .{output.stderr});

    try std.testing.expect(!tripped);
}

fn expect_found(output: *const cli.Output, part: []const u8) !void {
    assert(part.len > 0);

    const found = contains(.{ .part = part, .text = output.stdout });

    if (!found) std.debug.print("{s}\n", .{output.stdout});

    try std.testing.expect(found);
}

test "a file the sweep cannot read is counted in the tally" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "failed", .suite = "watch" });
    defer workspace.deinit();

    const oversized = try gpa.alloc(u8, oversized_bytes);
    defer gpa.free(oversized);

    const head = "fn a() {}\n";

    @memcpy(oversized[0..head.len], head);
    @memset(oversized[head.len..], 'x');

    _ = try workspace.write(.{ .body = camel_body, .name = "a.rs" });
    _ = try workspace.write(.{ .body = oversized, .name = "big.rs" });

    var output = try watched_as(gpa, io, &workspace, "json", .{
        .body = camel_body,
        .name = "a.rs",
    });

    defer output.deinit(gpa);

    const named = contains(.{ .part = "error: cannot read ", .text = output.stderr });

    if (!named) std.debug.print("{s}\n", .{output.stderr});

    try expect_guarded(&output);
    try std.testing.expect(named);
    try expect_found(&output, "[]");
}

test "an edited configuration reaches the next sweep" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "reconfigure", .suite = "watch" });
    defer workspace.deinit();

    _ = try workspace.write(.{ .body = camel_body, .name = "a.rs" });
    _ = try workspace.write(.{ .body = "ignore = [\"TS032\"]\n", .name = "tigerstyle.toml" });

    var output = try watched(gpa, io, &workspace, .{
        .body = "extend_select = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    defer output.deinit(gpa);

    try expect_guarded(&output);
    try expect_found(&output, "TS032");
}

test "an edited configuration that stops reading is reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "unreadable", .suite = "watch" });
    defer workspace.deinit();

    _ = try workspace.write(.{ .body = camel_body, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    var output = try watched(gpa, io, &workspace, .{
        .body = "nonsense = 1\n",
        .name = "tigerstyle.toml",
    });

    defer output.deinit(gpa);

    const complaint = "tigerstyle.toml:1: the key is not a tigerstyle-lsp option";
    const reported = contains(.{ .part = complaint, .text = output.stderr });

    if (!reported) std.debug.print("{s}\n", .{output.stderr});

    try expect_guarded(&output);
    try std.testing.expect(reported);
}

test "an edited source file reaches the next sweep" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "resweep", .suite = "watch" });
    defer workspace.deinit();

    _ = try workspace.write(.{ .body = "fn helper() {\n    let value = 1;\n}\n", .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    var output = try watched(gpa, io, &workspace, .{ .body = camel_body, .name = "a.rs" });
    defer output.deinit(gpa);

    try expect_guarded(&output);
    try expect_found(&output, "TS032");
}

test "an extended configuration is watched too" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "extended", .suite = "watch" });
    defer workspace.deinit();

    _ = try workspace.write(.{ .body = camel_body, .name = "a.rs" });
    _ = try workspace.write(.{ .body = "ignore = [\"TS032\"]\n", .name = "base.toml" });

    _ = try workspace.write(.{
        .body = "extend = \"base.toml\"\nextend_select = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    var output = try watched(gpa, io, &workspace, .{
        .body = "line_length_max = 100\n",
        .name = "base.toml",
    });

    defer output.deinit(gpa);

    try expect_guarded(&output);
    try expect_found(&output, "TS032");
}
