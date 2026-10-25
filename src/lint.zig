const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const cache_module = @import("cache.zig");
const cli = @import("cli.zig");
const languages = @import("languages.zig");
const scan = @import("scan.zig");
const timing = @import("timing.zig");
const Analysis = @import("analysis.zig");
const Baseline = scylla.Baseline;
const Buffer = scylla.Buffer;
const Cache = scylla.Cache;
const CodeSet = scylla.rule.CodeSet;
const Configuration = @import("config/configuration.zig");
const Diagnostic = scylla.Diagnostics.Diagnostic;
const Document = @import("document.zig");
const Environment = std.process.Environ.Map;
const Facts = scylla.path.Stat;
const Fixes = scylla.Fixes;
const Grammar = @import("grammar.zig");
const Language = scylla.Language;
const Limits = @import("limits.zig");
const Options = cli.Options;
const Parallel = @import("parallel.zig");
const Reporter = @import("reporter.zig");
const Rules = @import("rules.zig");
const Settings = @import("settings.zig");
const Watch = @import("watch.zig");
const Workspace = @import("workspace.zig");
const log = scylla.log;
const rule_count_max = scylla.limits.rule_count_max;

analysis: Analysis,
baseline: Baseline,
baseline_partial: bool,
baseline_path: Buffer,
cache: ?Cache,
configuration: Configuration,
counts: [rule_count_max]u32,
document: Document,
exit_non_zero_on_fix: bool,
exit_zero: bool,
file_ignores: scylla.ArrayType(CodeSet),
filtering: bool,
fixable_counts: [rule_count_max]u32,
fixable_safe: u32,
fixable_unsafe: u32,
fixed: u32,
ignores: Workspace.Ignores,
io: std.Io,
language: ?Language,
limits: *const Limits,
mode: Repair,
options: *const Options,
original: Buffer,
output: Reporter,
parallel: ?Parallel,
recording: bool,
rules: Rules,
scratch: Buffer,
selected: scylla.ArrayType(u32),
settings: Settings,
statistics: bool,
stdin: Buffer,
unsafe_fixes: bool,
watch: ?Watch,
workspace: Workspace,

const Lint = @This();

pub const Repair = enum {
    diff,
    fix,
    fix_only,
    report,
    suppress,
};

pub const Error = std.mem.Allocator.Error || Configuration.LoadError;

const Drainer = struct {
    lint: *Lint,
    progress: *Progress,

    pub fn drain(drainer: *Drainer) bool {
        return drainer.lint.drained(drainer.progress);
    }
};

const Progress = struct {
    cursor: u32,
    tally: Tally,
};

const Ranked = struct {
    index: u32,
    nanoseconds: u64,

    fn slower(_: void, left: Ranked, right: Ranked) bool {
        return left.nanoseconds > right.nanoseconds;
    }
};

const Tally = struct {
    failures: u32,
    findings: u32,
};

const cache_directory_variable = "TIGERSTYLE_CACHE_DIR";
const rule_rank_max: u32 = 10;

pub fn init(
    lint: *Lint,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    limits: *const Limits,
    environment: *const Environment,
) Error!void {
    assert(options.mode == .lint);
    assert(!options.paths.empty());
    assert(!options.show_files);
    assert(!options.show_settings);

    lint.io = io;
    lint.limits = limits;
    lint.options = options;
    lint.mode = repair_of(options);
    lint.exit_zero = options.exit_zero;
    lint.exit_non_zero_on_fix = options.exit_non_zero_on_fix;
    lint.unsafe_fixes = options.unsafe_fixes;
    lint.statistics = options.statistics;
    lint.filtering = options.baseline != null;
    lint.recording = options.write_baseline != null;
    lint.baseline_partial = false;
    lint.counts = @splat(0);
    lint.fixable_counts = @splat(0);
    lint.fixable_safe = 0;
    lint.fixable_unsafe = 0;
    lint.fixed = 0;
    lint.cache = null;
    lint.parallel = null;
    lint.watch = null;

    lint.rules = try .init(gpa);

    try lint.configure(gpa, options);
    try lint.walk(gpa, options);

    assert(lint.workspace.count() <= limits.workspace_file_count_max);

    try lint.cache_reserve(gpa, options, environment);
    try lint.reserve(gpa, options, environment);
    try lint.parallel_reserved(gpa);

    if (options.watch) lint.watch = try Watch.init(gpa, limits.watch());
}

fn cached(options: *const Options) bool {
    if (options.no_cache) return false;
    if (options.watch) return false;
    if (repair_of(options) != .report) return false;

    for (options.paths.const_slice()) |path| {
        if (std.mem.eql(u8, path, "-")) return false;
    }

    return true;
}

fn configure(lint: *Lint, gpa: std.mem.Allocator, options: *const Options) Error!void {
    assert(lint.rules.count() > 0);

    lint.configuration = try .init(gpa, &lint.limits.configuration());

    try lint.configuration.load(lint.io, &lint.rules.registry, options);

    lint.settings = lint.configuration.draft.settings(null, &lint.rules.registry);
}

fn walk(lint: *Lint, gpa: std.mem.Allocator, options: *const Options) std.mem.Allocator.Error!void {
    lint.workspace = try .init(gpa, &lint.limits.workspace());
    lint.ignores = try .init(gpa, lint.limits.ignores());

    lint.ignores.apply(&lint.configuration.draft);
    lint.workspace.collect(lint.io, options.paths.const_slice(), &lint.ignores);

    assert(lint.workspace.count() <= lint.limits.workspace_file_count_max);
}

fn cache_reserve(
    lint: *Lint,
    gpa: std.mem.Allocator,
    options: *const Options,
    environment: *const Environment,
) std.mem.Allocator.Error!void {
    assert(lint.cache == null);
    assert(lint.limits.path_bytes_max <= scylla.limits.path_bytes_max);

    if (!cached(options)) return;

    var buffer: [scylla.limits.path_bytes_max]u8 = undefined;
    const target = buffer[0..lint.limits.path_bytes_max];

    const directory = lint.cache_directory(options, environment, target) orelse {
        log.line("the cache directory does not fit; the cache is off", .{});

        return;
    };

    lint.cache = try .init(gpa, lint.limits.cache(), cache_module.magic);

    const key = cache_module.key_of(&lint.configuration.draft, &lint.rules.registry);

    lint.cache.?.open(lint.io, directory, key, "tigerstyle-lsp") catch |err| switch (err) {
        error.EntriesExhausted,
        error.PathTooLong,
        error.TextExhausted,
        error.AccessDenied,
        error.FileNotFound,
        error.IsDirectory,
        error.NameTooLong,
        error.NotDirectory,
        error.PathNotFound,
        error.PermissionDenied,
        error.SymlinkLoop,
        error.Unexpected,
        => lint.cache = null,
    };
}

fn cache_directory(
    lint: *const Lint,
    options: *const Options,
    environment: *const Environment,
    target: []u8,
) ?[]const u8 {
    const chosen = cache_module.directory_named(options.cache_dir) orelse
        cache_module.directory_named(environment.get(cache_directory_variable)) orelse
        lint.configuration.draft.cache_directory_path() orelse
        cache_module.directory_default;

    const root = lint.configuration.root();

    assert(chosen.len > 0);

    if (scylla.path.is_absolute(chosen)) return written_of(target, &.{chosen});
    if (root.len == 0) return written_of(target, &.{chosen});
    return written_of(target, &.{ root, "/", chosen });
}

fn written_of(target: []u8, parts: []const []const u8) ?[]const u8 {
    assert(parts.len > 0);

    const length = Buffer.written(target, parts) catch |err| switch (err) {
        error.Overflow => return null,
    };

    assert(length <= target.len);

    return target[0..length];
}

fn reserve(
    lint: *Lint,
    gpa: std.mem.Allocator,
    options: *const Options,
    environment: *const Environment,
) std.mem.Allocator.Error!void {
    const limits = lint.limits;
    const file_count = lint.workspace.count();
    const color = options.colored(lint.io, environment);
    const draft = &lint.configuration.draft;

    lint.baseline = try .init(gpa, limits.baseline());

    if (options.baseline) |path| lint.baseline_load(path);

    lint.file_ignores = try .init(gpa, @max(file_count, 1));

    for (0..file_count) |index| {
        lint.file_ignores.push(draft.ignored_for(lint.workspace.path(@intCast(index))));
    }

    try lint.analysis.init(gpa, lint.io, &limits.analysis());
    lint.baseline_path = try path_reserved(gpa, limits, options.write_baseline orelse "");
    lint.document = try .init(gpa, &limits.document());
    lint.language = language_of_options(options);
    lint.original = try .init(gpa, limits.file_bytes_max);
    lint.stdin = try stdin_path_of(gpa, limits, options);

    lint.output = try .init(gpa, lint.io, &limits.reporter(), &.{
        .colored = color,
        .format = options.format,
        .output_file = options.output_file,
        .quiet = options.quiet,
        .silent = options.silent,
    });

    lint.scratch = try .init(gpa, limits.file_bytes_max);
    lint.selected = try .init(gpa, limits.diagnostic_count_max);

    assert(lint.file_ignores.count() == file_count);
    assert(!lint.stdin.empty());
}

fn baseline_load(lint: *Lint, path: []const u8) void {
    assert(lint.filtering);
    assert(lint.baseline.count() == 0);

    lint.baseline.load(lint.io, path) catch |err| switch (err) {
        error.EntriesExhausted,
        error.TextExhausted,
        error.AccessDenied,
        error.FileNotFound,
        error.IsDirectory,
        error.NameTooLong,
        error.NotDirectory,
        error.PathNotFound,
        error.PermissionDenied,
        error.SymlinkLoop,
        error.Unexpected,
        => log.line("the baseline file could not be read", .{}),
    };
}

fn path_reserved(
    gpa: std.mem.Allocator,
    limits: *const Limits,
    path: []const u8,
) std.mem.Allocator.Error!Buffer {
    assert(limits.path_bytes_max > 0);

    var reserved: Buffer = try .init(gpa, limits.path_bytes_max);

    if (path.len > limits.path_bytes_max) {
        log.line("a path longer than {d} bytes is ignored", .{limits.path_bytes_max});

        return reserved;
    }

    if (!std.unicode.utf8ValidateSlice(path)) {
        log.line("a path that is not UTF-8 is ignored", .{});

        return reserved;
    }

    reserved.push(path) catch unreachable;

    return reserved;
}

fn stdin_path_of(
    gpa: std.mem.Allocator,
    limits: *const Limits,
    options: *const Options,
) std.mem.Allocator.Error!Buffer {
    var stdin = try path_reserved(gpa, limits, options.stdin_filename orelse "-");
    if (stdin.empty()) stdin.push("-") catch unreachable;

    assert(stdin.count() > 0);
    assert(stdin.count() <= limits.path_bytes_max);

    return stdin;
}

fn language_of_options(options: *const Options) ?Language {
    const name = options.language orelse return null;
    const language = languages.of_name(name) orelse return null;

    assert(languages.linted_set.contains(language));

    return language;
}

fn parallel_reserved(lint: *Lint, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    assert(lint.parallel == null);
    assert(lint.file_ignores.count() == lint.workspace.count());

    if (!lint.parallel_eligible()) return;

    const file_count = lint.workspace.count();
    const capacity = lint.limits.parallel();
    const reserved = Parallel.init(gpa, lint.io, &capacity, file_count);

    lint.parallel = reserved catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unstarted => {
            log.line("a worker thread could not be started; the files are checked in turn", .{});

            return;
        },
    };
}

fn parallel_eligible(lint: *const Lint) bool {
    const workspace = &lint.workspace;

    if (lint.mode != .report) return false;
    if (lint.options.watch) return false;
    if (lint.options.statistics) return false;
    if (workspace.count() < Parallel.file_count_min) return false;

    for (0..workspace.count()) |index| {
        if (std.mem.eql(u8, workspace.path(@intCast(index)), "-")) return false;
    }

    return true;
}

fn repair_of(options: *const Options) Repair {
    if (options.add_suppressions) return .suppress;
    if (options.diff) return .diff;
    if (options.fix_only) return .fix_only;
    if (options.fix) return .fix;
    return .report;
}

pub fn run(lint: *Lint) u8 {
    if (lint.watch) |*watch| return watch.run(lint);

    if (!lint.statistics) lint.output.begin();

    const tally = if (lint.parallel == null) lint.run_serial() else lint.run_chunked();

    if (lint.statistics) {
        lint.statistics_write();
    } else {
        lint.output.end(&lint.rules);
    }

    lint.trailer();

    if (lint.cache) |*cache| {
        cache.persist(lint.io) catch |err| switch (err) {
            error.AccessDenied,
            error.FileNotFound,
            error.IsDirectory,
            error.NameTooLong,
            error.NotDirectory,
            error.PathNotFound,
            error.PermissionDenied,
            error.SymlinkLoop,
            error.Unexpected,
            => {},
        };
    }

    if (lint.recording) {
        lint.baseline_write();

        if (lint.output.is_failed()) return cli.exit_failure;
        return cli.exit_success;
    }

    return lint.verdict(tally.findings + tally.failures);
}

fn run_serial(lint: *Lint) Tally {
    var tally: Tally = .{ .failures = 0, .findings = 0 };

    for (0..lint.workspace.count()) |index| {
        if (lint.file(@intCast(index))) |count| {
            tally.findings += count;
        } else |err| switch (err) {
            error.Skipped => tally.failures += 1,
        }
    }

    assert(tally.failures <= lint.workspace.count());

    return tally;
}

fn run_chunked(lint: *Lint) Tally {
    const parallel = &lint.parallel.?;
    const task = lint.parallel_task(parallel);

    assert(parallel.clean_files.empty());
    assert(task.checkers.len > 0);

    var progress: Progress = .{ .cursor = 0, .tally = .{ .failures = 0, .findings = 0 } };
    var drainer: Drainer = .{ .lint = lint, .progress = &progress };

    parallel.run(Drainer, &task, &drainer);

    assert(progress.cursor == lint.workspace.count());

    lint.clean_recorded(parallel);

    return progress.tally;
}

fn parallel_task(lint: *const Lint, parallel: *Parallel) Parallel.Check {
    assert(parallel.checkers.len == parallel.slot_states.len);
    assert(lint.file_ignores.count() == lint.workspace.count());

    return .{
        .analyses = parallel.analyses,
        .cache = if (lint.cache) |*cache| cache else null,
        .checkers = parallel.checkers,
        .draft = &lint.configuration.draft,
        .file_ignores = lint.file_ignores.const_slice(),
        .io = lint.io,
        .rules = &lint.rules,
        .slot_states = parallel.slot_states,
        .workspace = &lint.workspace,
    };
}

fn drained(lint: *Lint, progress: *Progress) bool {
    const parallel = &lint.parallel.?;
    const file_count = lint.workspace.count();
    const slot_count: u32 = @intCast(parallel.checkers.len);

    assert(slot_count > 0);
    assert(progress.cursor <= file_count);

    for (progress.cursor..file_count) |_| {
        const cursor = progress.cursor;
        const state = &parallel.slot_states[cursor % slot_count];
        const ready_for_round = (cursor / slot_count) * 2 + 1;
        if (state.load(.acquire) != ready_for_round) return false;

        if (lint.slot_reported(parallel, cursor)) |counted| {
            progress.tally.findings += counted;
        } else |err| switch (err) {
            error.Skipped => progress.tally.failures += 1,
        }

        state.store(ready_for_round + 1, .release);
        progress.cursor += 1;
    }

    assert(progress.cursor == file_count);

    return true;
}

fn slot_reported(lint: *Lint, parallel: *Parallel, index: u32) error{Skipped}!u32 {
    const slot_count: u32 = @intCast(parallel.checkers.len);
    const checker = &parallel.checkers[index % slot_count];

    assert(index < lint.workspace.count());

    switch (checker.verdict) {
        .cached => return 0,
        .failed => return error.Skipped,
        .rejected => |reason| {
            const named = scan.utf8_or(lint.workspace.path(index), "<line>");

            lint.output.error_note(lint.io, named, reason);

            return error.Skipped;
        },
        .ready => {
            const counted = lint.report_with(&checker.document, &checker.fixes);
            const stamp = checker.stamp orelse return counted;

            if (checker.document.state.diagnostics.empty()) {
                parallel.clean_files.push(.{ .index = index, .stamp = stamp });
            }

            return counted;
        },
    }
}

fn clean_recorded(lint: *Lint, parallel: *Parallel) void {
    assert(parallel.clean_files.count() <= lint.workspace.count());

    if (lint.cache != null) {
        for (parallel.clean_files.const_slice()) |clean| {
            lint.cache_record(clean.index, clean.stamp);
        }
    }

    parallel.clean_files.clear();

    assert(parallel.clean_files.empty());
}

fn cache_record(lint: *Lint, index: u32, stamp: Facts) void {
    const path = lint.workspace.path(index);

    assert(path.len > 0);

    lint.cache.?.record(lint.io, path, stamp) catch |err| switch (err) {
        error.EntriesExhausted, error.PathTooLong, error.TextExhausted => {},
    };
}

pub fn reconfigure(lint: *Lint) void {
    lint.configuration.reload(lint.io, &lint.rules.registry, lint.options);
    lint.settings = lint.configuration.draft.settings(null, &lint.rules.registry);
}

pub fn sweep(lint: *Lint) u8 {
    var findings: u32 = 0;

    if (!lint.statistics) lint.output.begin();

    lint.counts = @splat(0);
    lint.fixable_counts = @splat(0);
    lint.fixable_safe = 0;
    lint.fixable_unsafe = 0;

    for (0..lint.workspace.count()) |index| {
        const count = lint.file(@intCast(index)) catch |err| switch (err) {
            error.Skipped => continue,
        };

        findings += count;
    }

    if (lint.statistics) {
        lint.statistics_write();
    } else {
        lint.output.end(&lint.rules);
    }

    lint.trailer();

    if (findings > 0) return cli.exit_failure;
    if (lint.output.is_failed()) return cli.exit_failure;
    return cli.exit_success;
}

fn trailer(lint: *const Lint) void {
    const refused = if (lint.unsafe_fixes) 0 else lint.fixable_unsafe;

    lint.output.trailer(lint.io, lint.fixable_safe, refused);
}

fn verdict(lint: *const Lint, findings: u32) u8 {
    if (lint.output.is_failed()) return cli.exit_failure;
    if (lint.exit_zero) return cli.exit_success;
    if (findings > 0) return cli.exit_failure;

    if (lint.exit_non_zero_on_fix) {
        if (lint.fixed > 0) return cli.exit_failure;
    }

    return cli.exit_success;
}

fn file(lint: *Lint, index: u32) error{Skipped}!u32 {
    const piped = std.mem.eql(u8, lint.workspace.path(index), "-");
    const path = lint.path_of(index, piped);
    const named = languages.of_path(path);
    const chosen = if (piped) (lint.language orelse named) else named;

    const language = chosen orelse {
        log.line("no language checks the path", .{});

        return error.Skipped;
    };

    if (piped) assert(lint.cache == null);

    const stamp = lint.stamp_of(path);

    if (stamp) |recorded| {
        if (lint.cache.?.is_clean(path, recorded)) return 0;
    }

    try lint.loaded(index, language, piped);

    if (lint.mode == .report) return lint.reported(index, stamp);
    return lint.repaired(index);
}

fn path_of(lint: *const Lint, index: u32, piped: bool) []const u8 {
    const path = lint.workspace.path(index);

    assert(path.len > 0);
    assert(piped == std.mem.eql(u8, path, "-"));

    if (piped) return lint.stdin.const_slice();
    return path;
}

fn stamp_of(lint: *const Lint, path: []const u8) ?Facts {
    assert(path.len > 0);

    if (lint.cache == null) return null;
    return scylla.path.stat_of(lint.io, path);
}

fn reported(lint: *Lint, index: u32, stamp: ?Facts) u32 {
    lint.analyze();

    const count = lint.report();

    if (stamp) |recorded| {
        if (lint.document.state.diagnostics.empty()) lint.cache_record(index, recorded);
    }

    assert(count <= lint.document.state.diagnostics.count());

    return count;
}

fn loaded(lint: *Lint, index: u32, language: Language, piped: bool) error{Skipped}!void {
    const path = lint.path_of(index, piped);
    const draft = &lint.configuration.draft;
    const codes = if (piped) draft.ignored_for(path) else lint.file_ignores.get(index);

    assert(path.len > 0);
    assert(languages.linted_set.contains(language));

    lint.settings = draft.settings(language, &lint.rules.registry);

    lint.settings.ignore(codes);
    lint.document.reset();

    lint.document.text.uri_set(path) catch {
        log.line("skipping a path longer than the document uri buffer", .{});

        return error.Skipped;
    };

    lint.document.state.language = language;

    const loading = if (piped)
        lint.document.text_load_stdin(lint.io)
    else
        lint.document.text_load(lint.io, path);

    loading catch |err| switch (err) {
        error.FileUnreadable => return error.Skipped,
        error.LinesExhausted, error.TextExhausted, error.Utf8Invalid => |rejection| {
            const named = scan.utf8_or(lint.document.text.uri(), "<line>");

            lint.output.error_note(lint.io, named, Document.rejection_text(rejection));

            return error.Skipped;
        },
    };
}

fn analyze(lint: *Lint) void {
    lint.document.state.diagnostics.clear();
    lint.analysis.run(lint.document.entry(), &lint.rules, &lint.settings);

    if (lint.document.state.diagnostics.is_overflowed()) {
        log.line("a file reported past the {d} finding bound; the rest were dropped", .{
            lint.limits.diagnostic_count_max,
        });
    }
}

fn repaired(lint: *Lint, index: u32) error{Skipped}!u32 {
    lint.original.clear();

    lint.original.push(lint.document.text.text_bytes()) catch {
        log.line("skipping a file larger than the fix buffer", .{});

        return error.Skipped;
    };

    const passes = lint.converge(index);

    if (lint.mode == .diff) return lint.diff_report(index);

    if (passes > 0) {
        if (!lint.write(index)) return error.Skipped;

        lint.fixed += 1;
    }

    lint.analyze();

    if (lint.mode == .fix_only) return 0;
    return lint.report();
}

fn converge(lint: *Lint, index: u32) u32 {
    const minimum: scylla.Fixes.Applicability = if (lint.unsafe_fixes) .unsafe else .safe;
    const named = scan.utf8_or(lint.workspace.path(index), "<line>");

    for (0..lint.limits.fix_pass_count_max) |passes| {
        lint.analyze();

        if (lint.mode == .suppress) lint.suppressions_plan();

        const source = lint.document.text.text_bytes();
        const fixes = &lint.analysis.fixes;

        const applied = fixes.apply(&lint.scratch, source, minimum) catch |err| switch (err) {
            error.EditsExhausted, error.TargetExhausted, error.TextExhausted => {
                log.line(
                    "{s} outgrew the fix buffer; the pass is abandoned and the file is left alone",
                    .{named},
                );

                return @intCast(passes);
            },
        };

        if (applied == 0) return @intCast(passes);
        if (!lint.adopt()) return @intCast(passes);
    }

    log.line("{s} did not converge in {d} passes; report it at the issue tracker", .{
        named,
        lint.limits.fix_pass_count_max,
    });

    return lint.limits.fix_pass_count_max;
}

fn suppressions_plan(lint: *Lint) void {
    assert(lint.mode == .suppress);

    const prefix = if (lint.document.state.language) |language|
        Grammar.of(language).comment_prefix
    else
        "//";

    assert(prefix.len > 0);

    lint.analysis.suppressions_plan(lint.document.entry(), prefix);
}

fn adopt(lint: *Lint) bool {
    const balanced = scan.balanced(lint.document.text.text_bytes());
    const candidate = scan.balanced(lint.scratch.const_slice());

    if (balanced) {
        if (!candidate) {
            log.line("a fix pass unbalanced the file; the pass is reverted", .{});

            return false;
        }
    }

    lint.document.text.text_replace(lint.scratch.const_slice()) catch return false;

    return true;
}

fn write(lint: *Lint, index: u32) bool {
    const path = lint.workspace.path(index);
    const text = lint.document.text.text_bytes();

    if (std.mem.eql(u8, path, "-")) {
        lint.output.bytes(text);

        return true;
    }

    const created = scylla.path.create(lint.io, path) catch {
        log.line("a fixed file could not be written", .{});

        return false;
    };

    defer created.close(lint.io);

    created.writeStreamingAll(lint.io, text) catch return false;

    return true;
}

fn diff_report(lint: *Lint, index: u32) u32 {
    const named = scan.utf8_or(lint.workspace.path(index), "<line>");
    const before = lint.original.const_slice();
    const after = lint.document.text.text_bytes();
    if (std.mem.eql(u8, before, after)) return 0;

    lint.output.diff_write(named, before, after);

    return 1;
}

fn report(lint: *Lint) u32 {
    return lint.report_with(&lint.document, &lint.analysis.fixes);
}

fn report_with(lint: *Lint, document: *const Document, fixes: *const Fixes) u32 {
    const diagnostics = &document.state.diagnostics;
    const minimum: scylla.Fixes.Applicability = if (lint.unsafe_fixes) .unsafe else .safe;

    lint.selected.clear();

    for (diagnostics.slice(), 0..) |*diagnostic, index| {
        if (lint.baseline_claims(document, diagnostic)) continue;

        lint.selected.push(@intCast(index));

        if (diagnostic.rule) |counted| lint.counts[counted] += 1;

        const held = fixes.fix_of(diagnostic) orelse continue;

        switch (held.applicability) {
            .safe => lint.fixable_safe += 1,
            .unsafe => lint.fixable_unsafe += 1,
            .display_only => {},
        }

        if (!held.applicability.reaches(minimum)) continue;

        if (diagnostic.rule) |counted| lint.fixable_counts[counted] += 1;
    }

    if (lint.recording) return 0;

    if (!lint.statistics) {
        lint.output.file(&.{
            .document = document.view(),
            .fixes = fixes,
            .rules = &lint.rules,
            .selected = lint.selected.const_slice(),
        });
    }

    return lint.selected.count();
}

fn baseline_claims(lint: *Lint, document: *const Document, diagnostic: *const Diagnostic) bool {
    if (!lint.filtering) {
        if (!lint.recording) return false;
    }

    const key = baseline_key_of(document, diagnostic);

    if (lint.filtering) {
        if (lint.baseline.covers(key)) return true;
    }

    if (!lint.recording) return false;

    lint.baseline_record(key);

    return true;
}

fn baseline_key_of(document: *const Document, diagnostic: *const Diagnostic) u64 {
    const text = &document.text;
    const offset = diagnostic.span.offset;

    assert(offset <= text.text_bytes().len);
    assert(diagnostic.code.len > 0);

    const line = text.lines_index().line_of(offset);
    const unnamed = std.mem.eql(u8, diagnostic.code, Analysis.code_unnamed);
    const code = if (unnamed) "" else diagnostic.code;

    return Baseline.key_of(.{ .code = code, .line = text.line(line), .path = text.uri() });
}

fn baseline_record(lint: *Lint, key: u64) void {
    assert(lint.recording);

    lint.baseline.record(key) catch |err| switch (err) {
        error.EntriesExhausted, error.TextExhausted => {
            if (lint.baseline_partial) return;

            lint.baseline_partial = true;

            log.line("the baseline filled at {d} findings; no baseline is written", .{
                lint.baseline.count(),
            });
        },
    };
}

fn baseline_write(lint: *Lint) void {
    assert(lint.recording);

    if (lint.baseline_path.empty()) return;

    if (lint.baseline_partial) {
        log.line("refusing to write a baseline that is missing findings", .{});

        return;
    }

    lint.original.clear();

    for (0..lint.baseline.count()) |index| {
        var digits: [scan.decimal_bytes_max]u8 = undefined;
        const length = scan.decimal_write(&digits, lint.baseline.key_at(@intCast(index)));

        lint.original.push(digits[0..length]) catch return baseline_overflowed();
        lint.original.push("\n") catch return baseline_overflowed();
    }

    const path = lint.baseline_path.const_slice();
    const written: scylla.path.Write = .{ .content = lint.original.const_slice(), .path = path };

    scylla.path.write(lint.io, written) catch |err| switch (err) {
        error.AccessDenied,
        error.FileNotFound,
        error.IsDirectory,
        error.NameTooLong,
        error.NotDirectory,
        error.PathNotFound,
        error.PermissionDenied,
        error.SymlinkLoop,
        error.Unexpected,
        => log.line("the baseline file could not be written", .{}),
    };
}

fn baseline_overflowed() void {
    log.line("the baseline outgrew its buffer; no baseline is written", .{});
}

fn statistics_json_write(lint: *Lint) void {
    assert(lint.statistics);
    assert(lint.output.format == .json);

    var counted: [rule_count_max]scylla.report.Report.Count = undefined;
    var counted_count: u32 = 0;

    for (0..lint.rules.count()) |rule_index| {
        const count = lint.counts[rule_index];
        if (count == 0) continue;

        const rule = lint.rules.at(@intCast(rule_index));

        counted[counted_count] = .{
            .code = rule.code,
            .count = count,
            .fixable_count = lint.fixable_counts[rule_index],
            .rule = rule.name,
        };

        counted_count += 1;
    }

    assert(counted_count <= rule_count_max);

    lint.output.statistics_json(counted[0..counted_count]);
}

fn statistics_text_write(lint: *Lint) void {
    assert(lint.statistics);

    var total: u32 = 0;

    for (0..lint.rules.count()) |rule_index| {
        const count = lint.counts[rule_index];
        if (count == 0) continue;

        const rule = lint.rules.at(@intCast(rule_index));

        lint.output.line("{d:>7}  {s} {s}", .{ count, rule.code, rule.name });
        total += count;
    }

    assert(total >= lint.counts[0]);

    lint.output.line("{d:>7}  total", .{total});
    lint.timings_stages_write();
    lint.timings_rules_write();
}

fn statistics_write(lint: *Lint) void {
    assert(lint.statistics);

    if (lint.output.format == .json) {
        lint.statistics_json_write();
    } else {
        lint.statistics_text_write();
    }

    lint.output.flush();
}

fn timings_stages_write(lint: *Lint) void {
    const timings = &lint.analysis.timings;
    const total = timings.total();
    if (total == 0) return;

    assert(timings.document_count() > 0);

    lint.output.line("{d:>7}  documents in {d}us", .{
        timings.document_count(),
        @divFloor(total, 1_000),
    });

    var ranked: [timing.stage_count]Ranked = undefined;

    for (std.enums.values(timing.Stage), &ranked) |stage, *entry| {
        entry.* = .{ .index = stage.index(), .nanoseconds = timings.stage_at(stage) };
    }

    std.sort.insertion(Ranked, &ranked, {}, Ranked.slower);

    for (ranked) |entry| {
        assert(entry.nanoseconds <= total);

        lint.output.line("{d:>7}us {d:>3}%  {s}", .{
            @divFloor(entry.nanoseconds, 1_000),
            @divFloor(entry.nanoseconds * 100, total),
            timing.stage_names[entry.index],
        });
    }
}

fn timings_rules_write(lint: *Lint) void {
    const timings = &lint.analysis.timings;
    const total = timings.total();
    if (total == 0) return;

    var ranked: [rule_count_max]Ranked = undefined;

    for (&ranked, 0..) |*entry, rule_index| {
        entry.* = .{
            .index = @intCast(rule_index),
            .nanoseconds = timings.rule_at(@intCast(rule_index)),
        };
    }

    std.sort.insertion(Ranked, &ranked, {}, Ranked.slower);

    assert(ranked[0].nanoseconds >= ranked[rule_count_max - 1].nanoseconds);

    for (ranked[0..rule_rank_max]) |entry| {
        if (entry.nanoseconds == 0) continue;

        const rule = lint.rules.at(entry.index);

        lint.output.line("{d:>7}us {d:>3}%  {s} {s}", .{
            @divFloor(entry.nanoseconds, 1_000),
            @divFloor(entry.nanoseconds * 100, total),
            rule.code,
            rule.name,
        });
    }
}
