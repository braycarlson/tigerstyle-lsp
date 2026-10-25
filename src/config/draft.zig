const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const catalog = @import("../rules/catalog.zig");
const languages = @import("../languages.zig");
const scan = @import("../scan.zig");
const toml = @import("toml");
const Applicability = scylla.Fixes.Applicability;
const ArrayType = scylla.ArrayType;
const Buffer = scylla.Buffer;
const CodeSet = scylla.rule.CodeSet;
const GlobError = scylla.glob.Error;
const Language = scylla.Language;
const Limits = @import("../limits.zig");
const Patterns = scylla.glob.Patterns;
const Registry = scylla.rule.Registry;
const Scratch = scylla.glob.Patterns.Scratch;
const Selection = scylla.rule.Selection;
const Selector = scylla.rule.Selection.Selector;
const Settings = @import("../settings.zig");
const Severity = scylla.Diagnostics.Severity;
const Span = scylla.Span;
const StaticAllocator = scylla.StaticAllocator;
const Thresholds = Settings.Thresholds;
const rule_count_max = scylla.limits.rule_count_max;
const satisfies = scylla.version.satisfies;
const translated = scan.translated;
const version = @import("../cli.zig").version;

cache_directory: Span,
excludes: ArrayType(Span),
extend: Span,
file_ignores: ArrayType(FileIgnore),
force_exclude: bool,
globs: Buffer,
includes: ArrayType(Span),
language_overrides: std.EnumArray(Language, Overrides),
language_selections: Selections,
line: u32,
patterns: Patterns,
respect_gitignore: bool,
safe_fixes: CodeSet,
scratch: Scratch,
selection: Selection,
selectors: ArrayType(Selector),
severity: [rule_count_max]?Severity,
thresholds: Thresholds,
unsafe_fixes: CodeSet,

const Draft = @This();

pub const Capacity = struct {
    glob_bytes_max: u32,
    glob_count_max: u32,
};

pub const Complaint = struct {
    column: u32,
    line: u32,
    problem: Problem,
};

pub const Error = GlobError || error{
    KeyUnknown,
    LanguageUnknown,
    PreviewInLanguage,
    SelectorUnknown,
    SeverityUnknown,
    TooMany,
    ValueKind,
    ValueZero,
    VersionUnsupported,
};

const FileIgnore = struct {
    codes: CodeSet,
    end: u32,
    first: u32,
    pattern: Span,
};

pub const FileIgnorePatterns = struct {
    globs: *const Buffer,
    ignores: []const FileIgnore,
    remaining: u32,

    pub const Pattern = struct {
        codes: CodeSet,
        pattern: []const u8,
    };

    pub fn next(iterator: *FileIgnorePatterns) ?Pattern {
        assert(iterator.remaining <= iterator.ignores.len);

        if (iterator.remaining == 0) return null;

        const ignore = iterator.ignores[iterator.ignores.len - iterator.remaining];

        iterator.remaining -= 1;

        assert(ignore.pattern.length > 0);

        return .{ .codes = ignore.codes, .pattern = iterator.globs.slice_of(ignore.pattern) };
    }
};

pub const GlobPatterns = struct {
    globs: *const Buffer,
    remaining: u32,
    spans: []const Span,

    pub fn next(iterator: *GlobPatterns) ?[]const u8 {
        assert(iterator.remaining <= iterator.spans.len);

        if (iterator.remaining == 0) return null;

        const span = iterator.spans[iterator.spans.len - iterator.remaining];

        iterator.remaining -= 1;

        assert(span.length > 0);

        return iterator.globs.slice_of(span);
    }
};

pub const Problem = union(enum) {
    glob: GlobError,
    key_unknown,
    language_unknown,
    preview_in_language,
    selector_unknown,
    severity_unknown,
    syntax: toml.Document.Error,
    too_many,
    value_kind,
    value_zero,
    version_unsupported,

    pub fn of(err: Error) Problem {
        const problem: Problem = switch (err) {
            error.BraceTooDeep,
            error.BraceUnclosed,
            error.BytesExhausted,
            error.ClassUnclosed,
            error.ClassesExhausted,
            error.DoubleStarComponent,
            error.Empty,
            error.EscapeUnfinished,
            error.PatternsExhausted,
            error.VariantsExhausted,
            => |glob_error| .{ .glob = glob_error },
            error.KeyUnknown => .key_unknown,
            error.LanguageUnknown => .language_unknown,
            error.PreviewInLanguage => .preview_in_language,
            error.SelectorUnknown => .selector_unknown,
            error.SeverityUnknown => .severity_unknown,
            error.TooMany => .too_many,
            error.ValueKind => .value_kind,
            error.ValueZero => .value_zero,
            error.VersionUnsupported => .version_unsupported,
        };

        assert(problem.text().len > 0);

        return problem;
    }

    pub fn text(problem: Problem) []const u8 {
        const result = switch (problem) {
            .glob => |err| scylla.glob.message(err),
            .key_unknown => "the key is not a tigerstyle-lsp option",
            .language_unknown => "the language is not one tigerstyle-lsp lints",
            .preview_in_language => "preview is a top-level key, not a per-language one",
            .selector_unknown => "the selector names no rule",
            .severity_unknown => "the severity is not error, warning, or info",
            .syntax => |err| toml.message(err),
            .too_many => "the option holds more entries than tigerstyle-lsp reserves",
            .value_kind => "the value is not of the option's kind",
            .value_zero => "the limit is zero",
            .version_unsupported => "this tigerstyle-lsp does not satisfy required_version",
        };

        assert(result.len > 0);

        return result;
    }
};

pub const Target = enum {
    exclude,
    include,
};

const Chosen = enum {
    extend_select,
    ignore,
    select,
};

const Fixes = enum {
    extend_fixable,
    fixable,
    unfixable,
};

const Key = enum {
    cache_dir,
    exclude,
    extend,
    extend_exclude,
    extend_fixable,
    extend_include,
    extend_safe_fixes,
    extend_select,
    extend_unsafe_fixes,
    fixable,
    force_exclude,
    ignore,
    include,
    preview,
    required_version,
    respect_gitignore,
    select,
    unfixable,
};

const Selections = std.EnumArray(Language, Selection);

const Overrides = struct {
    severity: [rule_count_max]?Severity,
    thresholds: Thresholds,

    const unset: Overrides = .{ .severity = @splat(null), .thresholds = .unset };
};

const file_ignore_tables = [_][]const u8{
    "extend-per-file-ignores",
    "extend_per_file_ignores",
    "per-file-ignores",
    "per_file_ignores",
};

const key_bytes_max = 32;

pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Draft {
    assert(capacity.glob_bytes_max > 0);
    assert(capacity.glob_count_max > 0);

    var excludes: ArrayType(Span) = try .init(gpa, capacity.glob_count_max);
    errdefer excludes.deinit(gpa);

    var file_ignores: ArrayType(FileIgnore) = try .init(gpa, capacity.glob_count_max);
    errdefer file_ignores.deinit(gpa);

    var globs: Buffer = try .init(gpa, capacity.glob_bytes_max);
    errdefer globs.deinit(gpa);

    var includes: ArrayType(Span) = try .init(gpa, capacity.glob_count_max);
    errdefer includes.deinit(gpa);

    var language_selections = try selections_init(gpa);
    errdefer selections_deinit(&language_selections, gpa);

    var patterns: Patterns = try .init(gpa, .{
        .byte_count_max = capacity.glob_bytes_max,
        .class_count_max = Limits.glob_class_count_max,
        .pattern_count_max = capacity.glob_count_max,
    });

    errdefer patterns.deinit(gpa);

    var scratch = try patterns.scratch_init(gpa);
    errdefer scratch.deinit(gpa);

    var selection: Selection = try .init(gpa, Limits.selector_count_max);
    errdefer selection.deinit(gpa);

    const selectors: ArrayType(Selector) = try .init(gpa, Limits.selector_count_max);

    const draft: Draft = .{
        .cache_directory = .empty,
        .excludes = excludes,
        .extend = .empty,
        .file_ignores = file_ignores,
        .force_exclude = false,
        .globs = globs,
        .includes = includes,
        .language_overrides = .initFill(.unset),
        .language_selections = language_selections,
        .line = 0,
        .patterns = patterns,
        .respect_gitignore = true,
        .safe_fixes = .empty,
        .scratch = scratch,
        .selection = selection,
        .selectors = selectors,
        .severity = @splat(null),
        .thresholds = .default,
        .unsafe_fixes = .empty,
    };

    assert(draft.patterns.empty());
    assert(draft.thresholds.validate());

    return draft;
}

pub fn deinit(draft: *Draft, gpa: std.mem.Allocator) void {
    assert(draft.file_ignores.count() <= draft.patterns.count());

    draft.excludes.deinit(gpa);
    draft.file_ignores.deinit(gpa);
    draft.globs.deinit(gpa);
    draft.includes.deinit(gpa);
    selections_deinit(&draft.language_selections, gpa);
    draft.patterns.deinit(gpa);
    draft.scratch.deinit(gpa);
    draft.selection.deinit(gpa);
    draft.selectors.deinit(gpa);
    draft.* = undefined;
}

pub fn clear(draft: *Draft) void {
    assert(draft.file_ignores.count() <= draft.patterns.count());

    draft.cache_directory = .empty;

    draft.excludes.clear();
    draft.extend = .empty;

    draft.file_ignores.clear();
    draft.force_exclude = false;

    draft.globs.clear();
    draft.includes.clear();
    draft.language_overrides = .initFill(.unset);
    draft.line = 0;

    draft.patterns.clear();
    draft.respect_gitignore = true;
    draft.safe_fixes = .empty;

    draft.selection.clear();
    draft.selectors.clear();
    draft.severity = @splat(null);
    draft.thresholds = .default;
    draft.unsafe_fixes = .empty;

    for (&draft.language_selections.values) |*selection| selection.clear();

    assert(draft.patterns.empty());
    assert(draft.thresholds.validate());
}

pub fn apply(draft: *Draft, document: *const toml.Document, registry: *const Registry) Error!void {
    assert(registry.count() > 0);

    const root = document.root();
    var members = document.entries(root);

    for (0..members.remaining) |_| {
        const member = members.next() orelse break;

        draft.line_mark(document, member);
        try draft.root_member_apply(document, member, registry);
    }

    assert(members.remaining == 0);
    assert(draft.safe_fixes.intersect_with(draft.unsafe_fixes).is_empty());
    assert(draft.thresholds.validate());
}

pub fn settings(draft: *const Draft, language: ?Language, registry: *const Registry) Settings {
    assert(registry.count() <= rule_count_max);
    assert(draft.safe_fixes.intersect_with(draft.unsafe_fixes).is_empty());

    var result: Settings = .{
        .fixable = draft.selection.resolve_fixable(registry),
        .rules = draft.selection.resolve(registry),
        .safe_fixes = draft.safe_fixes,
        .severity = draft.severity,
        .thresholds = draft.thresholds,
        .unsafe_fixes = draft.unsafe_fixes,
    };

    const chosen = language orelse return result;
    const overrides = draft.language_overrides.getPtrConst(chosen);
    const overlay = draft.language_selections.getPtrConst(chosen);

    assert(languages.linted_set.contains(chosen));

    result.thresholds = result.thresholds.merged(overrides.thresholds);

    for (overrides.severity, 0..) |severity, rule_index| {
        if (severity) |held| result.severity[rule_index] = held;
    }

    result.rules = draft.selection.resolve_language(overlay, registry);

    return result;
}

pub fn ignored_for(draft: *Draft, path: []const u8) CodeSet {
    assert(draft.file_ignores.count() <= draft.patterns.count());

    var codes: CodeSet = .empty;

    for (draft.file_ignores.const_slice()) |ignore| {
        assert(ignore.first < ignore.end);
        assert(ignore.end <= draft.patterns.count());

        const rows = Span.between(ignore.first, ignore.end);

        if (draft.patterns.matches_within(&draft.scratch, rows, path)) {
            codes = codes.union_with(ignore.codes);
        }
    }

    return codes;
}

pub fn cache_directory_path(draft: *const Draft) ?[]const u8 {
    if (draft.cache_directory.length == 0) return null;

    assert(draft.cache_directory.end() <= draft.globs.count());

    const path = draft.globs.slice_of(draft.cache_directory);

    assert(path.len == draft.cache_directory.length);

    return path;
}

pub fn file_ignore_patterns(draft: *const Draft) FileIgnorePatterns {
    const ignores = draft.file_ignores.const_slice();

    for (ignores) |ignore| {
        assert(ignore.first < ignore.end);
        assert(ignore.pattern.end() <= draft.globs.count());
    }

    return .{ .globs = &draft.globs, .ignores = ignores, .remaining = @intCast(ignores.len) };
}

pub fn glob_patterns(draft: *const Draft, target: Target) GlobPatterns {
    const spans = switch (target) {
        .exclude => draft.excludes.const_slice(),
        .include => draft.includes.const_slice(),
    };

    for (spans) |span| {
        assert(span.length > 0);
        assert(span.end() <= draft.globs.count());
    }

    return .{ .globs = &draft.globs, .remaining = @intCast(spans.len), .spans = spans };
}

pub fn file_ignore_add(
    draft: *Draft,
    pattern: []const u8,
    codes: CodeSet,
) (GlobError || error{ TooMany, ValueKind })!void {
    if (pattern.len == 0) return error.ValueKind;
    if (draft.file_ignores.full()) return error.TooMany;

    const first = draft.patterns.count();
    errdefer draft.patterns.truncate(first);

    try draft.patterns.push_unanchored(pattern);

    const span = try draft.path_push(pattern);

    draft.file_ignores.push(.{
        .codes = codes,
        .end = draft.patterns.count(),
        .first = first,
        .pattern = span,
    });

    assert(draft.patterns.count() > first);
    assert(draft.file_ignores.count() > 0);
}

pub fn glob_add(
    draft: *Draft,
    pattern: []const u8,
    target: Target,
) error{ TooMany, ValueKind }!void {
    const list = draft.glob_list(target);
    const span = try draft.path_push(pattern);

    if (list.full()) return error.TooMany;

    list.push(span);

    assert(span.end() <= draft.globs.count());
    assert(std.mem.eql(u8, draft.globs.slice_of(span), pattern));
}

pub fn threshold_set(
    draft: *Draft,
    name: []const u8,
    limit: u32,
) error{ KeyUnknown, ValueZero }!void {
    assert(draft.thresholds.validate());

    if (limit == 0) return error.ValueZero;

    const field = threshold_field(&draft.thresholds, name) orelse return error.KeyUnknown;

    field.* = limit;

    assert(draft.thresholds.validate());
}

fn line_mark(draft: *Draft, document: *const toml.Document, node: toml.Node) void {
    const position = document.position_of(node) orelse {
        draft.line = @max(draft.line, 1);

        return;
    };

    assert(position.line > 0);

    draft.line = position.line;
}

fn root_member_apply(
    draft: *Draft,
    document: *const toml.Document,
    member: toml.Node,
    registry: *const Registry,
) Error!void {
    assert(registry.count() > 0);

    const key = document.key_of(member);

    if (document.kind_of(member) != .table) return draft.root_apply(document, member, registry);
    if (std.mem.eql(u8, key, "language")) return draft.languages_apply(document, member, registry);

    if (std.mem.eql(u8, key, "severity")) {
        return draft.severities_apply(document, member, registry, &draft.severity);
    }

    if (file_ignore_table(key)) return draft.file_ignores_apply(document, member, registry);
    return error.KeyUnknown;
}

fn root_apply(
    draft: *Draft,
    document: *const toml.Document,
    value: toml.Node,
    registry: *const Registry,
) Error!void {
    var buffer: [key_bytes_max]u8 = undefined;
    const name = normalized(document.key_of(value), &buffer);

    assert(name.len > 0);

    if (threshold_field(&draft.thresholds, name)) |field| {
        field.* = try limit_of(document, value);

        assert(draft.thresholds.validate());

        return;
    }

    const key = std.meta.stringToEnum(Key, name) orelse return error.KeyUnknown;
    const selection = &draft.selection;
    const text = text_of(document, value);

    switch (key) {
        .cache_dir => draft.cache_directory = try draft.path_push(text),
        .exclude, .extend_exclude => try draft.globs_apply(document, value, .exclude),
        .extend => draft.extend = try draft.path_push(text),
        .extend_fixable => try draft.fixes_apply(document, value, registry, .extend_fixable),
        .extend_include, .include => try draft.globs_apply(document, value, .include),
        .extend_safe_fixes => try draft.applicability_apply(document, value, registry, .safe),
        .extend_select => {
            try draft.selection_apply(document, value, registry, selection, .extend_select);
        },
        .extend_unsafe_fixes => try draft.applicability_apply(document, value, registry, .unsafe),
        .fixable => try draft.fixes_apply(document, value, registry, .fixable),
        .force_exclude => draft.force_exclude = try boolean_of(document, value),
        .ignore => try draft.selection_apply(document, value, registry, selection, .ignore),
        .preview => selection.preview.enabled = try boolean_of(document, value),
        .required_version => {
            const check: scylla.version.Check = .{ .held = version, .requirement = text };

            const satisfied = satisfies(&check) catch |err| switch (err) {
                error.ClauseInvalid, error.ClausesExhausted => return error.ValueKind,
            };

            if (!satisfied) return error.VersionUnsupported;
        },
        .respect_gitignore => draft.respect_gitignore = try boolean_of(document, value),
        .select => try draft.selection_apply(document, value, registry, selection, .select),
        .unfixable => try draft.fixes_apply(document, value, registry, .unfixable),
    }
}

fn languages_apply(
    draft: *Draft,
    document: *const toml.Document,
    table: toml.Node,
    registry: *const Registry,
) Error!void {
    assert(document.kind_of(table) == .table);

    var members = document.entries(table);

    for (0..members.remaining) |_| {
        const member = members.next() orelse break;

        draft.line_mark(document, member);

        if (document.kind_of(member) != .table) return error.KeyUnknown;

        const name = document.key_of(member);
        const language = languages.of_name(name) orelse return error.LanguageUnknown;

        try draft.language_apply(document, member, language, registry);
    }

    assert(members.remaining == 0);
}

fn language_apply(
    draft: *Draft,
    document: *const toml.Document,
    table: toml.Node,
    language: Language,
    registry: *const Registry,
) Error!void {
    assert(document.kind_of(table) == .table);
    assert(languages.linted_set.contains(language));

    const overrides = draft.language_overrides.getPtr(language);
    var members = document.entries(table);

    for (0..members.remaining) |_| {
        const member = members.next() orelse break;
        var buffer: [key_bytes_max]u8 = undefined;
        const key = normalized(document.key_of(member), &buffer);

        const severity_table = document.kind_of(member) == .table and
            std.mem.eql(u8, key, "severity");

        draft.line_mark(document, member);

        if (severity_table) {
            try draft.severities_apply(document, member, registry, &overrides.severity);

            continue;
        }

        if (std.mem.eql(u8, key, "preview")) return error.PreviewInLanguage;

        if (std.meta.stringToEnum(Chosen, key)) |chosen| {
            const selection = draft.language_selections.getPtr(language);

            try draft.selection_apply(document, member, registry, selection, chosen);

            continue;
        }

        const limit = try limit_of(document, member);
        const field = threshold_field(&overrides.thresholds, key) orelse return error.KeyUnknown;

        field.* = limit;
    }

    assert(members.remaining == 0);
}

fn severities_apply(
    draft: *Draft,
    document: *const toml.Document,
    table: toml.Node,
    registry: *const Registry,
    severity: *[rule_count_max]?Severity,
) Error!void {
    assert(document.kind_of(table) == .table);

    var members = document.entries(table);

    for (0..members.remaining) |_| {
        const member = members.next() orelse break;

        draft.line_mark(document, member);

        const rule_index = try rule_index_of(document.key_of(member), registry);
        const named = text_of(document, member);

        assert(rule_index < registry.count());

        severity[rule_index] = Severity.of(named) orelse return error.SeverityUnknown;
    }

    assert(members.remaining == 0);
}

fn file_ignores_apply(
    draft: *Draft,
    document: *const toml.Document,
    table: toml.Node,
    registry: *const Registry,
) Error!void {
    assert(document.kind_of(table) == .table);

    var members = document.entries(table);

    for (0..members.remaining) |_| {
        const member = members.next() orelse break;

        draft.line_mark(document, member);
        try draft.file_ignore_apply(document, member, registry);
    }

    assert(members.remaining == 0);
}

fn file_ignore_apply(
    draft: *Draft,
    document: *const toml.Document,
    value: toml.Node,
    registry: *const Registry,
) Error!void {
    if (document.kind_of(value) != .array) return error.ValueKind;

    const key = document.key_of(value);
    const first = draft.patterns.count();

    try draft.pattern_push(key);

    const end = draft.patterns.count();
    const pattern = try draft.path_push(key);
    var items = document.items(value);
    var codes: CodeSet = .empty;

    assert(first < end);

    for (0..items.remaining) |_| {
        const item = items.next() orelse break;
        const selector = try selector_of(document, item, registry);

        codes = codes.union_with(codes_matched(&selector, registry));
    }

    assert(items.remaining == 0);

    if (draft.file_ignores.full()) return error.TooMany;

    draft.file_ignores.push(.{
        .codes = codes,
        .end = end,
        .first = first,
        .pattern = pattern,
    });
}

fn applicability_apply(
    draft: *Draft,
    document: *const toml.Document,
    value: toml.Node,
    registry: *const Registry,
    graded: Applicability,
) Error!void {
    assert(graded != .display_only);

    try draft.selectors_read(document, value, registry);

    var named: CodeSet = .empty;

    for (draft.selectors.const_slice()) |*selector| {
        named = named.union_with(codes_matched(selector, registry));
    }

    switch (graded) {
        .display_only => unreachable,
        .safe => {
            draft.safe_fixes = draft.safe_fixes.union_with(named);
            draft.unsafe_fixes = draft.unsafe_fixes.difference_with(named);
        },
        .unsafe => {
            draft.unsafe_fixes = draft.unsafe_fixes.union_with(named);
            draft.safe_fixes = draft.safe_fixes.difference_with(named);
        },
    }

    assert(draft.safe_fixes.intersect_with(draft.unsafe_fixes).is_empty());
}

fn fixes_apply(
    draft: *Draft,
    document: *const toml.Document,
    value: toml.Node,
    registry: *const Registry,
    fixes: Fixes,
) Error!void {
    const selection = &draft.selection;

    try draft.selectors_read(document, value, registry);

    if (fixes == .fixable) selection.replace(.fixable);

    const list: Selection.List = switch (fixes) {
        .extend_fixable => .extend_fixable,
        .fixable => .fixable,
        .unfixable => .unfixable,
    };

    try selectors_push(selection, list, draft.selectors.const_slice());

    assert(selection.count_of(list) >= draft.selectors.count());

    if (fixes == .fixable) assert(selection.count_of(list) == draft.selectors.count());
}

fn selection_apply(
    draft: *Draft,
    document: *const toml.Document,
    value: toml.Node,
    registry: *const Registry,
    selection: *Selection,
    chosen: Chosen,
) Error!void {
    try draft.selectors_read(document, value, registry);

    if (chosen == .select) selection.replace(.select);

    const list: Selection.List = switch (chosen) {
        .extend_select => .extend_select,
        .ignore => .ignore,
        .select => .select,
    };

    try selectors_push(selection, list, draft.selectors.const_slice());

    assert(selection.count_of(list) >= draft.selectors.count());

    if (chosen == .select) assert(selection.count_of(list) == draft.selectors.count());
}

fn selectors_read(
    draft: *Draft,
    document: *const toml.Document,
    value: toml.Node,
    registry: *const Registry,
) Error!void {
    if (document.kind_of(value) != .array) return error.ValueKind;

    var items = document.items(value);

    draft.selectors.clear();

    for (0..items.remaining) |_| {
        const item = items.next() orelse break;
        const selector = try selector_of(document, item, registry);

        if (draft.selectors.full()) return error.TooMany;

        draft.selectors.push(selector);
    }

    assert(items.remaining == 0);
    assert(draft.selectors.count() <= document.count_of(value));
}

fn globs_apply(
    draft: *Draft,
    document: *const toml.Document,
    value: toml.Node,
    target: Target,
) Error!void {
    if (document.kind_of(value) != .array) return error.ValueKind;

    const list = draft.glob_list(target);
    const span_count_before = list.count();
    var items = document.items(value);

    for (0..items.remaining) |_| {
        const item = items.next() orelse break;
        const text = document.string_of(item) orelse return error.ValueKind;
        const span = try draft.glob_push(text);

        if (list.full()) return error.TooMany;

        list.push(span);
    }

    assert(items.remaining == 0);
    assert(list.count() >= span_count_before);
}

fn glob_push(draft: *Draft, text: []const u8) (GlobError || error{ TooMany, ValueKind })!Span {
    const first = draft.patterns.count();

    try draft.pattern_push(text);

    draft.patterns.truncate(first);

    assert(draft.patterns.count() == first);

    const span = try draft.path_push(text);

    assert(std.mem.eql(u8, draft.globs.slice_of(span), text));

    return span;
}

fn pattern_push(draft: *Draft, text: []const u8) GlobError!void {
    assert(draft.file_ignores.count() <= draft.patterns.count());

    const first = draft.patterns.count();
    errdefer draft.patterns.truncate(first);

    try draft.patterns.push_unanchored(text);

    assert(draft.patterns.count() > first);
}

fn path_push(draft: *Draft, text: []const u8) error{ TooMany, ValueKind }!Span {
    if (text.len == 0) return error.ValueKind;

    const span = draft.globs.intern(text) catch |err| switch (err) {
        error.Overflow => return error.TooMany,
    };

    assert(span.length == text.len);
    assert(span.end() == draft.globs.count());

    return span;
}

fn glob_list(draft: *Draft, target: Target) *ArrayType(Span) {
    const list = switch (target) {
        .exclude => &draft.excludes,
        .include => &draft.includes,
    };

    assert(list.capacity() == draft.file_ignores.capacity());

    return list;
}

fn codes_matched(selector: *const Selector, registry: *const Registry) CodeSet {
    assert(registry.count() <= rule_count_max);

    var codes: CodeSet = .empty;

    for (registry.slice(), 0..) |*item, index| {
        if (selector.matches(item.code)) codes.insert(@intCast(index));
    }

    assert(codes.count() <= registry.count());

    return codes;
}

fn file_ignore_table(table: []const u8) bool {
    assert(table.len > 0);

    for (file_ignore_tables) |name| {
        if (std.mem.eql(u8, table, name)) return true;
    }

    return false;
}

fn boolean_of(document: *const toml.Document, value: toml.Node) error{ValueKind}!bool {
    return document.boolean_of(value) orelse error.ValueKind;
}

fn limit_of(document: *const toml.Document, value: toml.Node) error{ ValueKind, ValueZero }!u32 {
    const number = document.integer_of(value) orelse return error.ValueKind;
    const limit = std.math.cast(u32, number) orelse return error.ValueKind;
    if (limit == 0) return error.ValueZero;

    assert(limit == number);

    return limit;
}

fn normalized(key: []const u8, buffer: *[key_bytes_max]u8) []const u8 {
    const length: u32 = @intCast(@min(key.len, buffer.len));
    const written = translated(buffer, key[0..length], .{ .from = '-', .to = '_' });

    assert(written != null);
    assert(written.? == length);

    return buffer[0..length];
}

fn rule_index_of(key: []const u8, registry: *const Registry) error{SelectorUnknown}!u32 {
    if (registry.index_of(key)) |by_code| {
        assert(by_code < registry.count());

        return by_code;
    }

    const by_name = registry.index_of_name(key) orelse return error.SelectorUnknown;

    assert(by_name < registry.count());
    assert(std.mem.eql(u8, registry.at(by_name).name, key));

    return by_name;
}

fn selector_of(
    document: *const toml.Document,
    value: toml.Node,
    registry: *const Registry,
) error{ SelectorUnknown, ValueKind }!Selector {
    assert(registry.count() > 0);

    const text = document.string_of(value) orelse return error.ValueKind;
    const selector = Selector.named(registry, text) orelse return error.SelectorUnknown;

    assert(!codes_matched(&selector, registry).is_empty());

    return selector;
}

fn selections_init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Selections {
    var selections: Selections = undefined;
    var initialised: u32 = 0;
    errdefer for (selections.values[0..initialised]) |*selection| selection.deinit(gpa);

    for (&selections.values) |*selection| {
        selection.* = try .init(gpa, Limits.selector_count_max);
        initialised += 1;
    }

    assert(initialised == selections.values.len);
    assert(initialised == Language.count);

    return selections;
}

fn selections_deinit(selections: *Selections, gpa: std.mem.Allocator) void {
    assert(selections.values.len == Language.count);

    for (&selections.values) |*selection| selection.deinit(gpa);
}

fn selectors_push(
    selection: *Selection,
    list: Selection.List,
    selectors: []const Selector,
) error{TooMany}!void {
    assert(selectors.len <= Limits.selector_count_max);

    const selector_count_before = selection.count_of(list);

    for (selectors) |selector| {
        selection.push(list, selector) catch |err| switch (err) {
            error.SelectorsExhausted => return error.TooMany,
        };
    }

    assert(selection.count_of(list) == selector_count_before + selectors.len);
}

fn text_of(document: *const toml.Document, value: toml.Node) []const u8 {
    return document.string_of(value) orelse "";
}

fn threshold_field(thresholds: *Thresholds, name: []const u8) ?*u32 {
    inline for (@typeInfo(Thresholds).@"struct".field_names) |field_name| {
        if (std.mem.eql(u8, name, field_name)) return &@field(thresholds, field_name);
    }

    return null;
}

const TestDocument = toml.DocumentType(.{
    .line_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
});

const Fixture = struct {
    document: TestDocument,
    draft: Draft,
    registry: Registry,
    static_allocator: StaticAllocator,

    fn init(fixture: *Fixture) !void {
        fixture.static_allocator = .init(std.testing.allocator);
        errdefer fixture.static_allocator.deinit();

        const gpa = fixture.static_allocator.allocator();

        fixture.registry = try catalog.registry_init(gpa);
        errdefer fixture.registry.deinit(gpa);

        fixture.draft = try .init(gpa, Limits.default.draft());
    }

    fn deinit(fixture: *Fixture) void {
        const gpa = fixture.static_allocator.allocator();

        fixture.draft.deinit(gpa);
        fixture.registry.deinit(gpa);
        fixture.static_allocator.deinit();
    }

    fn accepted(fixture: *Fixture, source: []const u8) !void {
        const complaint = fixture.applied(source);

        try std.testing.expect(complaint == null);
    }

    fn applied(fixture: *Fixture, source: []const u8) ?Complaint {
        fixture.document.parse(source, .{}) catch |err| {
            const position = fixture.document.diagnostic();

            return .{
                .column = position.column,
                .line = position.line,
                .problem = .{ .syntax = err },
            };
        };

        fixture.draft.apply(&fixture.document.document, &fixture.registry) catch |err| {
            return .{ .column = 0, .line = fixture.draft.line, .problem = .of(err) };
        };

        return null;
    }

    fn enabled(fixture: *Fixture, language: ?Language, code: []const u8) !bool {
        const index = try fixture.row(code);
        return fixture.settings_at(language).rules.contains(index);
    }

    fn language_of(fixture: *const Fixture, name: []const u8) !Language {
        assert(fixture.registry.count() > 0);

        return languages.of_name(name) orelse error.TestUnexpectedResult;
    }

    fn rejected(fixture: *Fixture, source: []const u8) !Complaint {
        return fixture.applied(source) orelse error.TestUnexpectedResult;
    }

    fn row(fixture: *const Fixture, code: []const u8) !u32 {
        return fixture.registry.index_of(code) orelse error.TestUnexpectedResult;
    }

    fn settings_at(fixture: *Fixture, language: ?Language) Settings {
        var scope = fixture.static_allocator.freeze_scope();
        defer scope.leave();

        return fixture.draft.settings(language, &fixture.registry);
    }
};

test "a limit reads in both spellings" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("line-length-max = 88\nfunction_lines_max = 60\n");

    const thresholds = fixture.settings_at(null).thresholds;

    try std.testing.expectEqual(@as(u32, 88), thresholds.line_length_max);
    try std.testing.expectEqual(@as(u32, 60), thresholds.function_lines_max);
}

test "a zero limit is rejected" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const complaint = try fixture.rejected("line_length_max = 0\n");

    try std.testing.expectEqual(Problem.value_zero, complaint.problem);
}

test "an unknown key is rejected by name" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const complaint = try fixture.rejected("nonsense = 1\n");

    try std.testing.expectEqual(Problem.key_unknown, complaint.problem);
    try std.testing.expectEqual(@as(u32, 1), complaint.line);
}

test "select replaces the default set" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("select = [\"TS004\"]\n");

    try std.testing.expect(try fixture.enabled(null, "TS004"));
    try std.testing.expect(!try fixture.enabled(null, "TS001"));
}

test "a severity override reads" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("[severity]\nTS002 = \"error\"\nno-lambda = \"info\"\n");

    const severity = fixture.settings_at(null).severity;
    const function_too_long = try fixture.row("TS002");
    const no_lambda = try fixture.row("TS015");

    try std.testing.expectEqual(@as(?Severity, .@"error"), severity[function_too_long]);
    try std.testing.expectEqual(@as(?Severity, .information), severity[no_lambda]);
}

test "a language block overrides a limit" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("line_length_max = 100\n[language.python]\nline_length_max = 88\n");

    const python = try fixture.language_of("python");
    const rust = try fixture.language_of("rust");
    const thresholds_python = fixture.settings_at(python).thresholds;
    const thresholds_rust = fixture.settings_at(rust).thresholds;

    try std.testing.expectEqual(@as(u32, 88), thresholds_python.line_length_max);
    try std.testing.expectEqual(@as(u32, 100), thresholds_rust.line_length_max);
}

test "a global limit survives a language lookup" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("nesting_depth_max = 2\n");

    const rust = try fixture.language_of("rust");
    const thresholds = fixture.settings_at(rust).thresholds;

    try std.testing.expectEqual(@as(u32, 2), thresholds.nesting_depth_max);
}

test "a language block leaves the other limits global" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted(
        "nesting_depth_max = 2\nparameters_max = 3\n[language.rust]\nparameters_max = 9\n",
    );

    const rust = try fixture.language_of("rust");
    const thresholds = fixture.settings_at(rust).thresholds;

    try std.testing.expectEqual(@as(u32, 2), thresholds.nesting_depth_max);
    try std.testing.expectEqual(@as(u32, 9), thresholds.parameters_max);
}

test "a language block replaces the selection" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("[language.python]\nselect = [\"TS004\"]\n");

    const python = try fixture.language_of("python");
    const rust = try fixture.language_of("rust");

    try std.testing.expect(try fixture.enabled(python, "TS004"));
    try std.testing.expect(!try fixture.enabled(python, "TS001"));
    try std.testing.expect(try fixture.enabled(rust, "TS001"));
}

test "a language select clears the inherited extension" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("extend_select = [\"TS032\"]\n[language.python]\nselect = [\"TS004\"]\n");

    const python = try fixture.language_of("python");

    try std.testing.expect(!try fixture.enabled(python, "TS032"));
}

test "a language extend select appends to the inherited set" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("[language.python]\nextend_select = [\"TS004\"]\n");

    const python = try fixture.language_of("python");
    const rust = try fixture.language_of("rust");

    try std.testing.expect(try fixture.enabled(python, "TS004"));
    try std.testing.expect(try fixture.enabled(python, "TS001"));
    try std.testing.expect(!try fixture.enabled(rust, "TS004"));
}

test "a language ignore appends to the inherited list" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("ignore = [\"TS002\"]\n[language.python]\nignore = [\"TS003\"]\n");

    const python = try fixture.language_of("python");
    const rust = try fixture.language_of("rust");

    try std.testing.expect(!try fixture.enabled(python, "TS002"));
    try std.testing.expect(!try fixture.enabled(python, "TS003"));
    try std.testing.expect(!try fixture.enabled(rust, "TS002"));
    try std.testing.expect(try fixture.enabled(rust, "TS003"));
}

test "a language block resolves under the top level preview flag" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("preview = true\n[language.python]\nextend_select = [\"TS050\"]\n");

    const python = try fixture.language_of("python");

    try std.testing.expect(try fixture.enabled(python, "TS050"));
}

test "preview inside a language block is refused" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const complaint = try fixture.rejected("[language.python]\npreview = true\n");

    try std.testing.expectEqual(Problem.preview_in_language, complaint.problem);
}

test "a language severity block overrides one code" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("[language.python.severity]\nTS002 = \"error\"\n");

    const python = try fixture.language_of("python");
    const rust = try fixture.language_of("rust");
    const function_too_long = try fixture.row("TS002");
    const severity_python = fixture.settings_at(python).severity[function_too_long];
    const severity_rust = fixture.settings_at(rust).severity[function_too_long];

    try std.testing.expectEqual(@as(?Severity, .@"error"), severity_python);
    try std.testing.expectEqual(@as(?Severity, null), severity_rust);
}

test "an unknown language is rejected" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const complaint = try fixture.rejected("[language.cobol]\nline_length_max = 88\n");

    try std.testing.expectEqual(Problem.language_unknown, complaint.problem);
}

test "a per file ignore reads its codes" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("[per-file-ignores]\n\"tests/*\" = [\"TS004\"]\n");

    const row = try fixture.row("TS004");

    try std.testing.expectEqual(@as(u32, 1), fixture.draft.file_ignores.count());
    try std.testing.expect(fixture.draft.file_ignores.get(0).codes.contains(row));
}

test "a required version clause is checked" {
    try std.testing.expect(try satisfies(&.{ .held = version, .requirement = ">=0.1" }));
    try std.testing.expect(try satisfies(&.{ .held = version, .requirement = ">=0.1, <9.0" }));
    try std.testing.expect(!try satisfies(&.{ .held = version, .requirement = ">=9.0" }));
    try std.testing.expect(try satisfies(&.{ .held = version, .requirement = "~=0.1" }));
}

test "an unsatisfied version is rejected" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const complaint = try fixture.rejected("required_version = \">=9.0\"\n");

    try std.testing.expectEqual(Problem.version_unsupported, complaint.problem);
}

test "a per file ignore matches its paths and reads back its pattern" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("[per-file-ignores]\n\"tests/*\" = [\"TS004\"]\n");

    var bit: CodeSet = .empty;

    bit.insert(try fixture.row("TS004"));

    try fixture.draft.file_ignore_add("docs/**", bit);

    var scope = fixture.static_allocator.freeze_scope();
    defer scope.leave();

    var patterns = fixture.draft.file_ignore_patterns();
    const first = patterns.next() orelse return error.TestUnexpectedResult;
    const second = patterns.next() orelse return error.TestUnexpectedResult;
    const rest = patterns.next();

    try std.testing.expectEqualStrings("tests/*", first.pattern);
    try std.testing.expectEqual(bit, first.codes);
    try std.testing.expectEqualStrings("docs/**", second.pattern);
    try std.testing.expect(rest == null);
    try std.testing.expectEqual(bit, fixture.draft.ignored_for("tests/a.py"));
    try std.testing.expectEqual(bit, fixture.draft.ignored_for("docs/guide/a.md"));
    try std.testing.expectEqual(CodeSet.empty, fixture.draft.ignored_for("src/a.py"));
}

test "the globs and the cache directory read back what was added" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("exclude = [\"vendor/**\"]\ncache_dir = \".cache\"\n");
    try fixture.draft.glob_add("build/**", .exclude);
    try fixture.draft.glob_add("src/**", .include);
    try std.testing.expectError(error.ValueKind, fixture.draft.glob_add("", .exclude));
    try std.testing.expectError(error.ValueZero, fixture.draft.threshold_set("line_length_max", 0));
    try std.testing.expectError(error.KeyUnknown, fixture.draft.threshold_set("nonsense", 3));
    try fixture.draft.threshold_set("line_length_max", 120);

    var excludes = fixture.draft.glob_patterns(.exclude);
    const vendor = excludes.next() orelse return error.TestUnexpectedResult;
    const build = excludes.next() orelse return error.TestUnexpectedResult;
    const excludes_rest = excludes.next();

    try std.testing.expectEqualStrings("vendor/**", vendor);
    try std.testing.expectEqualStrings("build/**", build);
    try std.testing.expect(excludes_rest == null);

    var includes = fixture.draft.glob_patterns(.include);
    const source = includes.next() orelse return error.TestUnexpectedResult;
    const includes_rest = includes.next();
    const cache = fixture.draft.cache_directory_path() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("src/**", source);
    try std.testing.expect(includes_rest == null);
    try std.testing.expectEqualStrings(".cache", cache);
    try std.testing.expectEqual(@as(u32, 120), fixture.draft.thresholds.line_length_max);
}

test "the later applicability wins and unfixable leaves the fixable set" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    try fixture.accepted("extend_safe_fixes = [\"TS031\"]\n" ++
        "extend_unsafe_fixes = [\"TS031\"]\n" ++
        "unfixable = [\"TS017\"]\n");

    const resolved = fixture.settings_at(null);
    const comment_form = try fixture.row("TS031");
    const check_return_value = try fixture.row("TS017");

    try std.testing.expect(resolved.unsafe_fixes.contains(comment_form));
    try std.testing.expect(!resolved.safe_fixes.contains(comment_form));
    try std.testing.expect(resolved.fixable.contains(comment_form));
    try std.testing.expect(!resolved.fixable.contains(check_return_value));
}
