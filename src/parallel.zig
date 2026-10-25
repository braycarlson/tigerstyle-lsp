const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const languages = @import("languages.zig");
const Analysis = @import("analysis.zig");
const Cache = scylla.Cache;
const CodeSet = scylla.rule.CodeSet;
const Document = @import("document.zig");
const Draft = @import("config/draft.zig");
const Facts = scylla.path.Stat;
const Fixes = scylla.Fixes;
const Language = scylla.Language;
const Rules = @import("rules.zig");
const StaticAllocator = scylla.StaticAllocator;
const Workspace = @import("workspace.zig");
const log = scylla.log;

analyses: []Analysis,
checkers: []Checker,
clean_files: scylla.ArrayType(CleanFile),
pool: *scylla.Pool,
slot_states: []std.atomic.Value(u32),

const Parallel = @This();

pub const Capacity = struct {
    analysis: Analysis.Capacity,
    document: Document.Capacity,
};

pub const Check = struct {
    analyses: []Analysis,
    cache: ?*const Cache,
    checkers: []Checker,
    draft: *const Draft,
    file_ignores: []const CodeSet,
    io: std.Io,
    rules: *const Rules,
    slot_states: []std.atomic.Value(u32),
    workspace: *const Workspace,

    pub const State = Analysis;

    pub fn run(task: *const Check, analysis: *Analysis, index: u32) scylla.Pool.JobError!void {
        assert(index < task.workspace.count());

        task.check(analysis, index);
    }

    pub fn states(task: *const Check) []Analysis {
        assert(task.analyses.len > 0);

        return task.analyses;
    }

    fn check(task: *const Check, analysis: *Analysis, index: u32) void {
        const slot_count: u32 = @intCast(task.checkers.len);

        assert(slot_count > 0);
        assert(index < task.workspace.count());

        const slot = index % slot_count;
        const state = &task.slot_states[slot];
        const open_for_round = (index / slot_count) * 2;

        slot_await(task.io, state, open_for_round);
        task.checked(analysis, &task.checkers[slot], index);
        state.store(open_for_round + 1, .release);
    }

    fn checked(task: *const Check, analysis: *Analysis, checker: *Checker, index: u32) void {
        const path = task.workspace.path(index);

        assert(index < task.file_ignores.len);

        checker.verdict = .failed;
        checker.stamp = task.stamp_of(path);

        const language = languages.of_path(path) orelse {
            log.line("no language checks the path", .{});

            return;
        };

        if (checker.stamp) |stamp| {
            if (task.cache.?.is_clean(path, stamp)) {
                checker.verdict = .cached;

                return;
            }
        }

        checker.document.reset();

        checker.document.text.uri_set(path) catch {
            log.line("skipping a path longer than the document uri buffer", .{});

            return;
        };

        checker.document.state.language = language;

        checker.document.text_load(task.io, path) catch |err| switch (err) {
            error.FileUnreadable => return,
            error.LinesExhausted, error.TextExhausted, error.Utf8Invalid => |rejection| {
                checker.verdict = .{ .rejected = Document.rejection_text(rejection) };

                return;
            },
        };

        task.analyzed(analysis, checker, language, index);
    }

    fn analyzed(
        task: *const Check,
        analysis: *Analysis,
        checker: *Checker,
        language: Language,
        index: u32,
    ) void {
        assert(languages.linted_set.contains(language));
        assert(checker.verdict == .failed);

        var settings = task.draft.settings(language, &task.rules.registry);

        settings.ignore(task.file_ignores[index]);
        checker.document.state.diagnostics.clear();
        analysis.run(checker.document.entry(), task.rules, &settings);
        analysis.fixes_swap(&checker.fixes);
        checker.verdict = .ready;
    }

    fn stamp_of(task: *const Check, path: []const u8) ?Facts {
        assert(path.len > 0);

        if (task.cache == null) return null;
        return scylla.path.stat_of(task.io, path);
    }
};

pub const Checker = struct {
    document: Document,
    fixes: Fixes,
    stamp: ?Facts,
    verdict: Verdict,

    pub const Verdict = union(enum) {
        cached,
        failed,
        ready,
        rejected: []const u8,
    };

    fn init(gpa: std.mem.Allocator, capacity: *const Capacity) std.mem.Allocator.Error!Checker {
        assert(capacity.analysis.fixes.fix_count_max > 0);
        assert(capacity.document.diagnostic_count_max > 0);

        var document: Document = try .init(gpa, &capacity.document);
        errdefer document.deinit(gpa);

        const fixes: Fixes = try .init(gpa, capacity.analysis.fixes);

        return .{
            .document = document,
            .fixes = fixes,
            .stamp = null,
            .verdict = .failed,
        };
    }
};

pub const CleanFile = struct {
    index: u32,
    stamp: Facts,
};

pub const Error = std.mem.Allocator.Error || error{Unstarted};
pub const file_count_min: u32 = 8;
const files_per_worker: u32 = 8;
const slot_count_max: u32 = 1024;
const slots_per_worker: u32 = 64;
const worker_count_max: u32 = scylla.limits.pool_worker_count_max;

comptime {
    assert(file_count_min > 0);
    assert(files_per_worker > 0);
    assert(slot_count_max >= file_count_min);
    assert(slots_per_worker > 0);
    assert(worker_count_max <= slot_count_max);
}

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    capacity: *const Capacity,
    file_count: u32,
) Error!Parallel {
    assert(file_count >= file_count_min);
    assert(capacity.document.text_bytes_max > 0);

    const worker_count = worker_count_of(file_count);
    const slot_count = @min(file_count, worker_count * slots_per_worker, slot_count_max);
    const analyses = try StaticAllocator.reserve(Analysis, gpa, worker_count);
    const checkers = try StaticAllocator.reserve(Checker, gpa, slot_count);
    const slot_states = try StaticAllocator.reserve(std.atomic.Value(u32), gpa, slot_count);

    for (analyses) |*analysis| try analysis.init(gpa, io, &capacity.analysis);
    for (checkers) |*checker| checker.* = try .init(gpa, capacity);
    for (slot_states) |*state| state.* = .init(0);

    const clean_files: scylla.ArrayType(CleanFile) = try .init(gpa, file_count);
    const pool = try StaticAllocator.create(scylla.Pool, gpa);

    pool.init(io, .{
        .stack_bytes = scylla.Pool.stack_bytes_default,
        .worker_count = worker_count,
    }) catch return error.Unstarted;

    assert(analyses.len <= worker_count_max);
    assert(checkers.len == slot_states.len);
    assert(pool.count() == analyses.len);

    return .{
        .analyses = analyses,
        .checkers = checkers,
        .clean_files = clean_files,
        .pool = pool,
        .slot_states = slot_states,
    };
}

pub fn run(
    parallel: *Parallel,
    comptime Drainer: type,
    task: *const Check,
    drainer: *Drainer,
) void {
    const worker_count: u32 = @intCast(parallel.analyses.len);

    assert(worker_count > 0);
    assert(worker_count == parallel.pool.count());
    assert(task.checkers.len == parallel.checkers.len);
    assert(task.analyses.len == parallel.analyses.len);

    const file_count = task.workspace.count();

    parallel.pool.run_reporting(Check, Drainer, task, drainer, file_count) catch |err| {
        switch (err) {
            error.Poisoned => unreachable,
        }
    };
}

fn worker_count_of(file_count: u32) u32 {
    assert(file_count > 0);

    const wanted = @max(@divCeil(file_count, files_per_worker), 1);
    const worker_count = scylla.Pool.worker_count_for(wanted);

    assert(worker_count >= 1);
    assert(worker_count <= worker_count_max);

    return worker_count;
}

fn slot_await(io: std.Io, state: *const std.atomic.Value(u32), open_for_round: u32) void {
    assert(open_for_round % 2 == 0);

    for (0..scylla.limits.pool_wait_count_max) |spin| {
        const held = state.load(.acquire);
        if (held == open_for_round) return;

        assert(held < open_for_round);

        scylla.Pool.waited(io, spin);
    } else unreachable;
}

test worker_count_of {
    try std.testing.expectEqual(@as(u32, 1), worker_count_of(1));
    try std.testing.expect(worker_count_of(file_count_min * files_per_worker) >= 1);
    try std.testing.expect(worker_count_of(std.math.maxInt(u16)) <= worker_count_max);
}
