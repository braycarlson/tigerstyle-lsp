const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const catalog = @import("rules/catalog.zig");
const cli = @import("cli.zig");
const languages = @import("languages.zig");
const scan = @import("scan.zig");
const Buffer = scylla.Buffer;
const Configuration = @import("config/configuration.zig");
const Environment = std.process.Environ.Map;
const Formatters = scylla.Formatters;
const Limits = @import("limits.zig");
const Options = cli.Options;
const Registry = scylla.rule.Registry;
const Reporter = @import("reporter.zig");
const Workspace = @import("workspace.zig");
const log = scylla.log;

check: bool,
configuration: Configuration,
diff: bool,
formatters: Formatters,
ignores: Workspace.Ignores,
io: std.Io,
original: Buffer,
output: Reporter,
refused: u32,
registry: Registry,
scratch: Buffer,
workspace: Workspace,
written: u32,

const Formatting = @This();
pub const Error = std.mem.Allocator.Error || Configuration.LoadError;
const read_buffer_bytes: u32 = 1 << 12;

pub fn init(
    formatting: *Formatting,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    limits: *const Limits,
    environment: *const Environment,
) Error!void {
    assert(options.mode == .format);
    assert(!options.paths.empty());

    formatting.io = io;
    formatting.check = options.check;
    formatting.diff = options.diff;
    formatting.refused = 0;
    formatting.written = 0;
    formatting.registry = try catalog.registry_init(gpa);
    formatting.configuration = try .init(gpa, &limits.configuration());

    try formatting.configuration.load(io, &formatting.registry, options);
    try formatting.walk(gpa, options, limits);
    try formatting.reserve(gpa, options, limits, environment);
}

fn walk(
    formatting: *Formatting,
    gpa: std.mem.Allocator,
    options: *const Options,
    limits: *const Limits,
) std.mem.Allocator.Error!void {
    formatting.workspace = try .init(gpa, &limits.workspace());
    formatting.ignores = try .init(gpa, limits.ignores());

    formatting.ignores.apply(&formatting.configuration.draft);
    formatting.workspace.collect(formatting.io, options.paths.const_slice(), &formatting.ignores);

    assert(formatting.workspace.count() <= limits.workspace_file_count_max);
}

fn reserve(
    formatting: *Formatting,
    gpa: std.mem.Allocator,
    options: *const Options,
    limits: *const Limits,
    environment: *const Environment,
) std.mem.Allocator.Error!void {
    assert(limits.file_bytes_max > 0);
    assert(formatting.registry.count() > 0);

    const color = options.colored(formatting.io, environment);

    try formatting.formatters.init(gpa, &limits.formatters(), languages.linted_set, &.{});
    formatting.original = try .init(gpa, limits.file_bytes_max);

    formatting.output = try .init(gpa, formatting.io, &limits.reporter(), &.{
        .colored = color,
        .format = options.format,
        .output_file = options.output_file,
        .quiet = options.quiet,
        .silent = options.silent,
    });

    formatting.scratch = try .init(gpa, limits.file_bytes_max);

    assert(formatting.formatters.languages().eql(languages.linted_set));
}

pub fn run(formatting: *Formatting) u8 {
    assert(formatting.written == 0);
    assert(formatting.refused == 0);

    for (0..formatting.workspace.count()) |index| formatting.one(@intCast(index));

    const noun = if (formatting.written == 1) "file" else "files";

    formatting.output.line("formatted {d} {s}, {d} refused", .{
        formatting.written,
        noun,
        formatting.refused,
    });

    formatting.output.flush();

    if (formatting.refused > 0) return cli.exit_failure;

    if (formatting.check) {
        if (formatting.written > 0) return cli.exit_failure;
    }

    return cli.exit_success;
}

fn one(formatting: *Formatting, index: u32) void {
    const path = formatting.workspace.path(index);
    const language = languages.of_path(path) orelse return;

    if (!formatting.read(index)) return;

    const source_type = languages.source_type(language, path);
    const source = formatting.original.const_slice();
    const formatted = formatting.formatters.format(source_type, source, &formatting.scratch);

    formatted catch |err| switch (err) {
        error.DepthExceeded,
        error.DiagnosticsExhausted,
        error.EventsExhausted,
        error.IntermediatesExhausted,
        error.LinesExhausted,
        error.NodesExhausted,
        error.OutputExhausted,
        error.PragmasExhausted,
        error.SourceInvalid,
        error.TagsExhausted,
        error.TokensExhausted,
        => {
            formatting.refused += 1;

            log.line("{s} is left alone", .{scan.utf8_or(path, "<line>")});

            return;
        },
    };

    if (std.mem.eql(u8, formatting.scratch.const_slice(), formatting.original.const_slice())) {
        return;
    }

    formatting.written += 1;

    if (formatting.diff) {
        formatting.report_diff(index);

        return;
    }

    if (formatting.check) {
        const named = scan.utf8_or(path, "<line>");

        formatting.output.line("{s} would be reformatted", .{named});

        return;
    }

    if (!formatting.write(index)) formatting.refused += 1;
}

fn read(formatting: *Formatting, index: u32) bool {
    const path = formatting.workspace.path(index);

    formatting.original.clear();

    const opened = scylla.path.open(formatting.io, path) catch {
        log.line("a file could not be opened for formatting", .{});

        return false;
    };

    defer opened.close(formatting.io);

    var buffer: [read_buffer_bytes]u8 = undefined;
    var reader = opened.reader(formatting.io, &buffer);

    formatting.original.read_from(&reader.interface) catch |err| switch (err) {
        error.Overflow, error.ReadFailed => {
            log.line("{s} outgrew the file buffer", .{scan.utf8_or(path, "<line>")});

            formatting.refused += 1;

            return false;
        },
    };

    assert(formatting.original.count() <= formatting.original.capacity());

    return true;
}

fn report_diff(formatting: *Formatting, index: u32) void {
    const named = scan.utf8_or(formatting.workspace.path(index), "<line>");
    const before = formatting.original.const_slice();
    const after = formatting.scratch.const_slice();

    assert(!std.mem.eql(u8, before, after));

    formatting.output.diff_write(named, before, after);
}

fn write(formatting: *const Formatting, index: u32) bool {
    const path = formatting.workspace.path(index);

    assert(path.len > 0);
    assert(formatting.written > 0);

    const created = scylla.path.create(formatting.io, path) catch {
        log.line("a formatted file could not be written", .{});

        return false;
    };

    defer created.close(formatting.io);

    created.writeStreamingAll(formatting.io, formatting.scratch.const_slice()) catch return false;

    return true;
}

test "a source formats through the linted formatters" {
    const gpa = std.testing.allocator;
    const formatters = try gpa.create(Formatters);
    defer gpa.destroy(formatters);

    try formatters.init(gpa, &Limits.default.formatters(), languages.linted_set, &.{});
    defer formatters.deinit(gpa);

    var out: Buffer = try .init(gpa, 1 << 12);
    defer out.deinit(gpa);

    const source_type = languages.source_type(.rust, "main.rs");

    try formatters.format(source_type, "fn main(){let x=1;}\n", &out);
    try std.testing.expectEqualStrings("fn main() {\n    let x = 1;\n}\n", out.const_slice());
}
