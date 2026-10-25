const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Diagnostic = scylla.Diagnostics.Diagnostic;
const Document = @import("document.zig");
const FileID = scylla.FileID;
const Fixes = scylla.Fixes;
const Format = scylla.report.Format;
const Report = scylla.report.Report;
const Rules = @import("rules.zig");
const Terminal = scylla.Terminal;
const log = scylla.log;

diff: scylla.Diff,
format: Format,
quiet: bool,
report: Report,
terminal: Terminal,

const Reporter = @This();

pub const Capacity = struct {
    line_count_max: u32,
    output_bytes_max: u32,
    report_bytes_max: u32,
};

pub const Options = struct {
    colored: bool,
    format: Format,
    output_file: ?[]const u8,
    quiet: bool,
    silent: bool,
};

pub const FileRows = struct {
    document: Document.View,
    fixes: *const Fixes,
    rules: *const Rules,
    selected: []const u32,

    fn diagnostic(rows: *const FileRows, index: u32) *const Diagnostic {
        assert(index < rows.selected.len);

        const at = rows.selected[index];
        const held = rows.document.state.diagnostics.slice();

        assert(at < held.len);

        return &held[at];
    }

    fn fix_of(rows: *const FileRows, index: u32) ?Fixes.Fix {
        return rows.fixes.fix_of(rows.diagnostic(index));
    }

    pub fn count(rows: *const FileRows) u32 {
        return @intCast(rows.selected.len);
    }

    pub fn edit(rows: *const FileRows, index: u32, at: u32) Report.Row.Edit {
        const held = rows.fix_of(index).?;
        const edits = rows.fixes.edits_of(&held);

        assert(at < edits.len);

        return .{ .replacement = rows.fixes.replacement_of(&edits[at]), .span = edits[at].span };
    }

    pub fn edit_count(rows: *const FileRows, index: u32) u32 {
        const held = rows.fix_of(index) orelse return 0;
        return held.edit_count;
    }

    pub fn related(rows: *const FileRows, index: u32, at: u32) Report.Row.Related {
        const diagnostics = &rows.document.state.diagnostics;
        const held = diagnostics.related_of(rows.diagnostic(index));

        assert(at < held.len);

        return .{
            .file = FileID.of(0),
            .message = diagnostics.related_message_of(&held[at]),
            .span = held[at].span,
        };
    }

    pub fn related_count(rows: *const FileRows, index: u32) u32 {
        return rows.diagnostic(index).related_count;
    }

    pub fn row(rows: *const FileRows, index: u32) Report.Row {
        const held = rows.diagnostic(index);
        const fix = rows.fix_of(index);
        const rule_found = rows.rules.of(held);

        return .{
            .code = held.code,
            .file = FileID.of(0),
            .fix = if (fix) |found| .{
                .applicability = found.applicability,
                .title = rows.fixes.title_of(&found),
            } else null,
            .message = rows.document.state.diagnostics.message_of(held),
            .rule = if (rule_found) |found| found.name else "",
            .severity = held.severity,
            .span = held.span,
        };
    }

    pub fn text(rows: *const FileRows, file_id: FileID) Report.Text {
        assert(file_id.index() == 0);

        return .{
            .lines = rows.document.text.lines_index(),
            .path = rows.document.text.uri(),
            .source = rows.document.text.text_bytes(),
        };
    }
};

const note_bytes_max: u32 = 1 << 10;

const tool: Report.Tool = .{
    .information_uri = "https://github.com/braycarlson/tigerstyle-lsp",
    .name = "tigerstyle-lsp",
    .rule_uri_prefix = "https://github.com/braycarlson/tigerstyle-lsp/blob/main/docs/rules/",
    .rule_uri_suffix = ".md",
    .version = @import("cli.zig").version,
};

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    capacity: *const Capacity,
    options: *const Options,
) std.mem.Allocator.Error!Reporter {
    assert(capacity.output_bytes_max > 0);
    assert(capacity.report_bytes_max >= capacity.output_bytes_max);

    var terminal: Terminal = try .init(gpa, &.{
        .buffer_bytes_max = capacity.output_bytes_max,
        .colored = options.colored,
        .target = target_of(io, options.output_file),
    });

    errdefer terminal.deinit(gpa);

    if (options.silent) terminal.silence();

    var diff: scylla.Diff = try .init(gpa, capacity.line_count_max);
    errdefer diff.deinit(gpa);

    const held: Report = try .init(gpa, .{
        .body_bytes_max = capacity.report_bytes_max,
        .line_count_max = capacity.line_count_max,
    }, &.{ .format = options.format, .tool = tool });

    return .{
        .diff = diff,
        .format = options.format,
        .quiet = options.quiet,
        .report = held,
        .terminal = terminal,
    };
}

pub fn deinit(reporter: *Reporter, gpa: std.mem.Allocator) void {
    assert(reporter.terminal.capacity() > 0);

    reporter.diff.deinit(gpa);
    reporter.report.deinit(gpa);
    reporter.terminal.deinit(gpa);
    reporter.* = undefined;
}

pub fn begin(reporter: *Reporter) void {
    reporter.report.begin(&reporter.terminal);

    assert(reporter.report.streamed_count() == 0);
}

pub fn bytes(reporter: *Reporter, text: []const u8) void {
    assert(std.unicode.utf8ValidateSlice(text));

    reporter.terminal.push(text);
}

pub fn diff_write(
    reporter: *Reporter,
    path: []const u8,
    before: []const u8,
    after: []const u8,
) void {
    assert(path.len > 0);

    const texts: scylla.Diff.Texts = .{ .after = after, .before = before };
    const terminal = &reporter.terminal;

    reporter.diff.write_unified(terminal, path, &texts, .{}) catch |err| switch (err) {
        error.LinesExhausted => log.line("{s} has more lines than the diff reads", .{path}),
    };
}

pub fn end(reporter: *Reporter, rules: *const Rules) void {
    reporter.report.end(&reporter.terminal, &rules.registry);

    if (reporter.report.is_truncated()) {
        log.line("the report outgrew the report buffer; it is written short", .{});
    }

    reporter.flush();
}

pub fn error_note(
    reporter: *const Reporter,
    io: std.Io,
    path: []const u8,
    reason: []const u8,
) void {
    assert(reason.len > 0);

    if (reporter.terminal.is_silent()) return;

    note(io, "error: cannot read {s}: {s}", .{ path, reason });
}

pub fn file(reporter: *Reporter, rows: *const FileRows) void {
    reporter.report.render_file(FileRows, &reporter.terminal, rows);
}

pub fn flush(reporter: *Reporter) void {
    reporter.terminal.flush();

    if (reporter.terminal.is_failed()) {
        log.line("the report could not be written in full; the rest is dropped", .{});
    }
}

pub fn is_failed(reporter: *const Reporter) bool {
    return reporter.terminal.is_failed();
}

pub fn line(reporter: *Reporter, comptime format: []const u8, arguments: anytype) void {
    comptime assert(format.len > 0);

    reporter.terminal.push_line(format, arguments);
}

pub fn statistics_json(reporter: *Reporter, counted: []const Report.Count) void {
    assert(reporter.format == .json);
    assert(counted.len <= scylla.limits.report_tally_rows_max);

    reporter.report.tally_fill(counted);

    const written = reporter.report.statistics(&reporter.terminal);

    assert(written);
}

pub fn trailer(reporter: *const Reporter, io: std.Io, safe: u32, refused: u32) void {
    if (!reporter.format.colors()) return;
    if (reporter.quiet) return;
    if (reporter.terminal.is_silent()) return;

    if (refused > 0) {
        note(io, "[*] {d} fixable with the --unsafe-fixes option.", .{refused});

        return;
    }

    if (safe > 0) note(io, "[*] {d} fixable with the `--fix` option.", .{safe});
}

fn target_of(io: std.Io, output_file: ?[]const u8) Terminal.Target {
    const path = output_file orelse return .{ .stdout = io };

    assert(path.len > 0);

    const created = scylla.path.create(io, path) catch {
        log.line("the output file could not be opened; writing to standard output", .{});

        return .{ .stdout = io };
    };

    return .{ .file = .{ .handle = created, .io = io } };
}

fn note(io: std.Io, comptime format: []const u8, arguments: anytype) void {
    var buffer: [note_bytes_max]u8 = undefined;
    const text = std.mem.print(&buffer, format ++ "\n", arguments) catch return;

    std.Io.File.stderr().writeStreamingAll(io, text) catch return;
}

test "only the human formats color" {
    try std.testing.expect(Format.full.colors());
    try std.testing.expect(Format.concise.colors());
    try std.testing.expect(Format.grouped.colors());
    try std.testing.expect(!Format.json.colors());
}
