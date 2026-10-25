const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const catalog = @import("../rules/catalog.zig");
const scan = @import("../scan.zig");
const toml = @import("toml");
const CodeSet = scylla.rule.CodeSet;
const Complaint = Draft.Complaint;
const Draft = @import("draft.zig");
const Limits = @import("../limits.zig");
const Options = @import("../cli.zig").Options;
const Problem = Draft.Problem;
const Registry = scylla.rule.Registry;
const Resolver = scylla.config.Resolver;
const Selection = scylla.rule.Selection;
const Span = scylla.Span;
const log = scylla.log;

complaint: Complaint,
document: toml.Document,
draft: Draft,
path: ?Span,
resolver: Resolver,
search_reported: bool,
storage: toml.Storage,

const Configuration = @This();

pub const Capacity = struct {
    draft: Draft.Capacity,
    resolver: Resolver.Capacity,
};

pub const InputError = Resolver.InputError || error{ ConfigInvalid, ExtendInvalid };
pub const LoadError = error{ Usage, VersionUnsupported };
pub const ReadError = Resolver.CapacityError || InputError || scylla.path.SystemError;

const Extend = union(enum) {
    absent,
    target: []const u8,
};

const resolver_options: Resolver.Options = .{
    .file_names = &.{ ".tigerstyle.toml", "tigerstyle.toml" },
    .section_file_name = null,
};

pub fn init(
    gpa: std.mem.Allocator,
    capacity: *const Capacity,
) std.mem.Allocator.Error!Configuration {
    assert(capacity.resolver.path_bytes_max > 0);
    assert(capacity.draft.glob_count_max > 0);

    var draft: Draft = try .init(gpa, capacity.draft);
    errdefer draft.deinit(gpa);

    var storage: toml.Storage = try .init(gpa, document_capacity(&capacity.resolver));
    errdefer storage.deinit(gpa);

    const resolver: Resolver = try .init(gpa, capacity.resolver, resolver_options);

    assert(resolver.chain_count() == 0);

    return .{
        .complaint = .{ .column = 0, .line = 0, .problem = .key_unknown },
        .document = undefined,
        .draft = draft,
        .path = null,
        .resolver = resolver,
        .search_reported = false,
        .storage = storage,
    };
}

pub fn deinit(configuration: *Configuration, gpa: std.mem.Allocator) void {
    if (configuration.path) |path| assert(path.length > 0);

    configuration.resolver.deinit(gpa);
    configuration.storage.deinit(gpa);
    configuration.draft.deinit(gpa);
    configuration.* = undefined;
}

pub fn discover(
    configuration: *Configuration,
    io: std.Io,
    start: []const u8,
    origin: Resolver.Origin,
) ?Span {
    assert(start.len > 0);

    const found = configuration.resolver.discover(io, start, origin) catch |err| {
        if (!configuration.search_reported) {
            log.line("the search for a configuration stopped: {s}; the defaults stand", .{
                search_failure(err),
            });
        }

        configuration.search_reported = true;

        return null;
    };

    return switch (found) {
        .absent => null,
        .found => |span| span,
    };
}

pub fn diagnostic(configuration: *const Configuration) Complaint {
    assert(configuration.complaint.line > 0);

    return configuration.complaint;
}

pub fn load(
    configuration: *Configuration,
    io: std.Io,
    registry: *const Registry,
    options: *const Options,
) LoadError!void {
    assert(registry.count() > 0);
    assert(configuration.path == null);

    if (!options.isolated) try configuration.load_rooted(io, registry, options);
    if (!flags_apply(&configuration.draft, registry, options)) return error.Usage;
}

pub fn read(
    configuration: *Configuration,
    io: std.Io,
    path: Span,
    registry: *const Registry,
) ReadError!void {
    assert(path.length > 0);
    assert(registry.count() > 0);

    try configuration.chain_collect(io, path);

    var files = Resolver.Files.init(&configuration.resolver, io);

    assert(files.remaining == configuration.resolver.chain_count());

    for (0..files.remaining) |_| {
        const file = try files.next();

        try configuration.applied(file.source, registry);
    }
}

pub fn reload(
    configuration: *Configuration,
    io: std.Io,
    registry: *const Registry,
    options: *const Options,
) void {
    const located = configuration.path orelse return;
    const held = configuration.resolver.path_of(located);

    assert(held.len <= scylla.limits.path_bytes_max);

    var buffer: [scylla.limits.path_bytes_max]u8 = undefined;
    const path = buffer[0..held.len];

    @memcpy(path, held);
    configuration.resolver.clear();
    configuration.path = configuration.resolver.record(path) catch unreachable;

    configuration.resolve(io, configuration.path.?, registry) catch |err| {
        configuration.failure_report(err, path);
        configuration.draft.clear();
    };

    if (!configuration.draft.thresholds.validate()) configuration.draft.clear();

    const applied_flags = flags_apply(&configuration.draft, registry, options);

    assert(applied_flags);
}

pub fn root(configuration: *const Configuration) []const u8 {
    const located = configuration.path orelse return "";
    const directory = scylla.path.directory_of(configuration.resolver.path_of(located));

    assert(directory.len > 0);
    assert(directory.len <= configuration.resolver.path_of(located).len);

    return directory;
}

fn load_rooted(
    configuration: *Configuration,
    io: std.Io,
    registry: *const Registry,
    options: *const Options,
) error{VersionUnsupported}!void {
    assert(!options.isolated);

    const path = configuration.path_located(io, options) orelse return;

    configuration.path = path;

    configuration.resolve(io, path, registry) catch |err| {
        configuration.failure_report(err, configuration.resolver.path_of(path));

        if (configuration.version_unsupported(err)) return error.VersionUnsupported;

        configuration.draft.clear();

        return;
    };

    if (configuration.draft.thresholds.validate()) return;

    log.line("a configuration limit is zero; the defaults stand", .{});
    configuration.draft.clear();
}

fn version_unsupported(configuration: *const Configuration, err: ReadError) bool {
    const unsupported = switch (err) {
        error.ConfigInvalid => configuration.diagnostic().problem == .version_unsupported,
        else => false,
    };

    if (unsupported) assert(configuration.complaint.line > 0);

    return unsupported;
}

fn path_located(configuration: *Configuration, io: std.Io, options: *const Options) ?Span {
    const resolver = &configuration.resolver;

    if (options.config) |path| {
        return resolver.record(path) catch {
            log.line("the configuration file does not fit the path table", .{});

            return null;
        };
    }

    const start = if (options.paths.empty()) "." else options.paths.get(0);
    const origin: Resolver.Origin = if (scylla.path.is_directory(io, start)) .directory else .file;

    return configuration.discover(io, start, origin);
}

fn search_failure(err: Resolver.CapacityError) []const u8 {
    const text: []const u8 = switch (err) {
        error.DepthExceeded => "the start lies more directories deep than the search climbs",
        error.FileTooBig => "a configuration it found is larger than tigerstyle-lsp reads",
        error.PathTooLong => "the start path is longer than the path table holds",
        error.PathsExhausted => "the path table is full",
    };

    assert(text.len > 0);
    assert(std.mem.startsWith(u8, text, "the ") or std.mem.startsWith(u8, text, "a "));

    return text;
}

fn resolve(
    configuration: *Configuration,
    io: std.Io,
    path: Span,
    registry: *const Registry,
) ReadError!void {
    assert(path.length > 0);

    configuration.draft.clear();

    return configuration.read(io, path, registry);
}

fn failure_report(configuration: *const Configuration, err: ReadError, path: []const u8) void {
    assert(path.len > 0);

    const text = scan.utf8_or(path, "the configuration file");

    switch (err) {
        error.ExtendCycle => log.line("{s} extends itself; the defaults stand", .{text}),
        error.ConfigInvalid => {
            const complaint = configuration.diagnostic();

            log.line("{s}:{d}: {s}", .{ text, complaint.line, complaint.problem.text() });
        },
        error.FileTooBig, error.PathEmpty, error.PathTooLong, error.PathsExhausted => {
            log.line("{s} is larger than tigerstyle-lsp reads", .{text});
        },
        error.DepthExceeded => log.line("{s} extends deeper than tigerstyle-lsp follows", .{text}),
        error.AccessDenied,
        error.ExtendInvalid,
        error.FileNotFound,
        error.IsDirectory,
        error.NameTooLong,
        error.NotDirectory,
        error.PathNotFound,
        error.PermissionDenied,
        error.SymlinkLoop,
        error.Unexpected,
        error.Utf8Invalid,
        => log.line("{s} could not be read; the defaults stand", .{text}),
    }
}

fn chain_collect(configuration: *Configuration, io: std.Io, path: Span) ReadError!void {
    var chain = Resolver.Chain.init(&configuration.resolver, io, path);

    assert(chain.remaining > 0);

    for (0..chain.remaining + 1) |_| {
        if (!chain.pending()) return;

        const file = try chain.next();

        try configuration.parsed(file.source);

        switch (try extend_of(&configuration.document)) {
            .absent => return,
            .target => |target| try chain.extend(target),
        }
    }

    unreachable;
}

fn applied(
    configuration: *Configuration,
    source: []const u8,
    registry: *const Registry,
) error{ConfigInvalid}!void {
    assert(registry.count() > 0);

    try configuration.parsed(source);

    configuration.draft.apply(&configuration.document, registry) catch |err| {
        const line = configuration.draft.line;

        assert(line > 0);

        configuration.complaint = .{ .column = 0, .line = line, .problem = .of(err) };

        return error.ConfigInvalid;
    };
}

fn parsed(configuration: *Configuration, source: []const u8) error{ConfigInvalid}!void {
    assert(source.len <= configuration.storage.text.len);

    configuration.document.parse(configuration.storage, source, .{}) catch |err| {
        const position = configuration.document.diagnostic;

        configuration.complaint = .{
            .column = position.column,
            .line = position.line,
            .problem = .{ .syntax = err },
        };

        return error.ConfigInvalid;
    };
}

fn document_capacity(resolver: *const Resolver.Capacity) toml.Capacity {
    assert(resolver.config_bytes_max > 0);

    return .{
        .line_count_max = null,
        .node_count_max = resolver.config_bytes_max / 2 + 2,
        .text_bytes_max = resolver.config_bytes_max,
    };
}

fn extend_of(document: *const toml.Document) error{ExtendInvalid}!Extend {
    const value = document.member(document.root(), Resolver.extend_key) orelse return .absent;
    const target = document.string_of(value) orelse return error.ExtendInvalid;

    return .{ .target = target };
}

fn flags_apply(draft: *Draft, registry: *const Registry, options: *const Options) bool {
    assert(registry.count() > 0);

    if (options.preview) draft.selection.preview.enabled = true;
    if (options.force_exclude) draft.force_exclude = true;
    if (options.respect_gitignore) |respect| draft.respect_gitignore = respect;

    const thresholds_valid = thresholds_apply(options, draft);

    globs_apply(options, draft);

    const valid = thresholds_valid and file_ignores_apply(options, registry, draft);

    if (!options.select.empty()) draft.selection.replace(.select);
    if (!options.fixable.empty()) draft.selection.replace(.fixable);

    const pushes = [_]struct { []const []const u8, Selection.List }{
        .{ options.select.const_slice(), .select },
        .{ options.extend_select.const_slice(), .extend_select },
        .{ options.ignore.const_slice(), .ignore },
        .{ options.fixable.const_slice(), .fixable },
        .{ options.extend_fixable.const_slice(), .extend_fixable },
        .{ options.unfixable.const_slice(), .unfixable },
    };

    for (pushes) |push| selectors_push(push[0], registry, &draft.selection, push[1]);

    return valid;
}

fn selectors_push(
    texts: []const []const u8,
    registry: *const Registry,
    selection: *Selection,
    list: Selection.List,
) void {
    for (texts) |text| {
        const selector = Selection.Selector.named(registry, text) orelse {
            log.line("a selector on the command line names no rule", .{});

            continue;
        };

        selection.push(list, selector) catch |err| switch (err) {
            error.SelectorsExhausted => {
                log.line("more selectors than tigerstyle-lsp reserves", .{});
            },
        };
    }
}

fn file_ignores_apply(options: *const Options, registry: *const Registry, draft: *Draft) bool {
    for (options.per_file_ignores.const_slice()) |entry| {
        const split = std.mem.findScalarLast(u8, entry, ':') orelse return false;
        const pattern = scan.trim_ascii(entry[0..split]);

        var codes: CodeSet = .empty;
        var names = std.mem.tokenizeAny(u8, entry[split + 1 ..], "|,");

        for (0..entry.len) |_| {
            const name = names.next() orelse break;
            const trimmed = scan.trim_ascii(name);
            if (trimmed.len == 0) continue;

            const selector = Selection.Selector.named(registry, trimmed) orelse {
                log.line("a per-file selector names no rule", .{});

                continue;
            };

            for (registry.slice(), 0..) |*rule, rule_index| {
                if (selector.matches(rule.code)) codes.insert(@intCast(rule_index));
            }
        }

        draft.file_ignore_add(pattern, codes) catch {
            log.line("more per-file exemptions than tigerstyle-lsp reserves", .{});
        };
    }

    return true;
}

fn thresholds_apply(options: *const Options, draft: *Draft) bool {
    for (options.thresholds.const_slice()) |threshold| {
        const value = std.fmt.parseUnsigned(u32, threshold.value, 10) catch return false;

        draft.threshold_set(threshold.key, value) catch return false;
    }

    return true;
}

fn globs_apply(options: *const Options, draft: *Draft) void {
    const lists = [_]struct { []const []const u8, Draft.Target }{
        .{ options.includes.const_slice(), .include },
        .{ options.excludes.const_slice(), .exclude },
    };

    for (lists) |list| {
        for (list[0]) |pattern| {
            var parts = std.mem.splitScalar(u8, pattern, ',');

            for (0..pattern.len + 1) |_| {
                const part = parts.next() orelse break;
                const trimmed = scan.trim_ascii(part);
                if (trimmed.len == 0) continue;

                draft.glob_add(trimmed, list[1]) catch {
                    log.line("more patterns than tigerstyle-lsp reserves", .{});
                };
            }
        }
    }
}

const Fixture = struct {
    configuration: Configuration,
    registry: Registry,
    root_bytes: [scylla.limits.path_bytes_max]u8,
    root_length: usize,
    tmp: std.testing.TmpDir,

    fn init(fixture: *Fixture) !void {
        const gpa = std.testing.allocator;

        fixture.tmp = std.testing.tmpDir(.{});
        errdefer fixture.tmp.cleanup();

        fixture.root_length = try fixture.tmp.dir.realPath(std.testing.io, &fixture.root_bytes);
        fixture.registry = try catalog.registry_init(gpa);
        errdefer fixture.registry.deinit(gpa);

        fixture.configuration = try .init(gpa, &Limits.default.configuration());

        assert(fixture.root_length > 0);
        assert(fixture.configuration.path == null);
    }

    fn deinit(fixture: *Fixture) void {
        const gpa = std.testing.allocator;

        fixture.configuration.deinit(gpa);
        fixture.registry.deinit(gpa);
        fixture.tmp.cleanup();
    }

    fn recorded(fixture: *Fixture, name: []const u8) !Span {
        assert(name.len > 0);
        assert(fixture.root_length > 0);

        var path_bytes: [scylla.limits.path_bytes_max]u8 = undefined;
        const root_path = fixture.root_bytes[0..fixture.root_length];
        const path = try std.mem.print(&path_bytes, "{s}/{s}", .{ root_path, name });

        fixture.configuration.resolver.clear();

        return fixture.configuration.resolver.record(path);
    }

    fn resolved(fixture: *Fixture, name: []const u8) !void {
        const span = try fixture.recorded(name);
        return fixture.configuration.resolve(std.testing.io, span, &fixture.registry);
    }

    fn seed(fixture: *Fixture, name: []const u8, text: []const u8) !void {
        assert(name.len > 0);
        assert(text.len > 0);

        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = text });
    }
};

test read {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const draft = &fixture.configuration.draft;

    try fixture.seed("base.toml", "line_length_max = 90\nfunction_lines_max = 50\n");
    try fixture.seed("tigerstyle.toml", "extend = \"base.toml\"\nline_length_max = 80\n");
    try fixture.resolved("tigerstyle.toml");
    try std.testing.expectEqual(@as(u32, 80), draft.thresholds.line_length_max);
    try std.testing.expectEqual(@as(u32, 50), draft.thresholds.function_lines_max);
    try std.testing.expectEqual(@as(u32, 2), fixture.configuration.resolver.chain_count());
}

test diagnostic {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.seed("tigerstyle.toml", "line_length_max = 80\nnonsense = 1\n");
    try std.testing.expectError(error.ConfigInvalid, fixture.resolved("tigerstyle.toml"));

    const complaint = fixture.configuration.diagnostic();

    try std.testing.expectEqual(Problem.key_unknown, complaint.problem);
    try std.testing.expectEqual(@as(u32, 2), complaint.line);
    try std.testing.expectEqual(@as(u32, 0), complaint.column);
}

test "a syntax failure is a complaint at its column" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.seed("tigerstyle.toml", "line_length_max =\n");
    try std.testing.expectError(error.ConfigInvalid, fixture.resolved("tigerstyle.toml"));

    const complaint = fixture.configuration.diagnostic();
    const expected: Problem = .{ .syntax = error.ValueMissing };

    try std.testing.expectEqual(expected, complaint.problem);
    try std.testing.expectEqual(@as(u32, 1), complaint.line);
    try std.testing.expectEqual(@as(u32, 18), complaint.column);
}

test "the extend key is read from the top level only" {
    const Document = toml.DocumentType(.{
        .line_count_max = null,
        .node_count_max = 64,
        .text_bytes_max = 256,
    });

    var document: Document = undefined;

    try document.parse("select = [\"GL\"]\nextend = \"../base.toml\"\n", .{});

    const base = try extend_of(&document.document);

    try std.testing.expectEqualStrings("../base.toml", base.target);
    try document.parse("[tool]\nextend = \"x\"\n", .{});
    try std.testing.expect(try extend_of(&document.document) == .absent);
    try document.parse("extend = 3\n", .{});
    try std.testing.expectError(error.ExtendInvalid, extend_of(&document.document));
    try document.parse("extend = \"a\\tb\"\n", .{});

    const tabbed = try extend_of(&document.document);

    try std.testing.expectEqualStrings("a\tb", tabbed.target);
    try document.parse("x = 1\n", .{});
    try std.testing.expect(try extend_of(&document.document) == .absent);
}

test "an extend that names itself is a cycle and a missing extend is unreadable" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.seed("loop.toml", "extend = \"loop.toml\"\n");
    try fixture.seed("dangling.toml", "extend = \"absent.toml\"\n");
    try std.testing.expectError(error.ExtendCycle, fixture.resolved("loop.toml"));
    try std.testing.expectError(error.FileNotFound, fixture.resolved("dangling.toml"));
}

test "a resolve clears what the draft held and a read keeps it" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const draft = &fixture.configuration.draft;

    try fixture.seed("tigerstyle.toml", "line_length_max = 80\n");
    try draft.threshold_set("parameters_max", 3);
    try fixture.resolved("tigerstyle.toml");
    try std.testing.expectEqual(@as(u32, 7), draft.thresholds.parameters_max);
    try draft.threshold_set("parameters_max", 3);

    const span = try fixture.recorded("tigerstyle.toml");

    try fixture.configuration.read(std.testing.io, span, &fixture.registry);
    try std.testing.expectEqual(@as(u32, 3), draft.thresholds.parameters_max);
    try std.testing.expectEqual(@as(u32, 80), draft.thresholds.line_length_max);
}
