const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const cli = @import("../cli.zig");
const Analysis = @import("../analysis.zig");
const Buffer = scylla.Buffer;
const Configuration = @import("../config/configuration.zig");
const Diagnostic = scylla.Diagnostics.Diagnostic;
const Diagnostics = scylla.Diagnostics;
const Document = @import("../document.zig");
const Documents = @import("../documents.zig");
const Editor = @import("editor.zig");
const Encoding = scylla.LineIndex.Encoding;
const Grammar = @import("../grammar.zig");
const Handle = scylla.Documents.Handle;
const Id = scylla.transport.rpc.Id;
const Limits = @import("../limits.zig");
const Options = @import("../cli.zig").Options;
const Rejection = scylla.TextDocument.Error;
const Roots = scylla.lsp.Roots;
const Rules = @import("../rules.zig");
const Sender = @import("sender.zig");
const Settings = @import("../settings.zig");
const Span = scylla.Span;
const View = Document.View;
const json = @import("json");
const log = scylla.log;
const lsp = scylla.lsp;

analysis: Analysis,
apply_edit: bool,
config: Buffer,
configuration: Configuration,
configured: Configured,
documents: Documents,
editors: [Editor.editor_count]Editor,
encoding: Encoding,
exit_code: u8,
faults: Editor.Faults,
folders: Roots,
io: std.Io,
isolated: bool,
path: Buffer,
pull: bool,
resolve: bool,
rules: Rules,
sender: Sender,
settings: Settings,
state: State,
uri_text: Buffer,

const Session = @This();

pub const Configured = struct {
    directory: Buffer,
    editor_index: u32,
    located: bool,
    valid: bool,
};

pub const State = enum {
    exited,
    initialized,
    shutting_down,
    uninitialized,
};

pub const configuration_request: i64 = 4;
const fix_on_save_request: i64 = 3;
const register_request: i64 = 1;
pub const source = "tigerstyle-lsp";
const configuration_patterns = [_][]const u8{ "**/tigerstyle.toml", "**/.tigerstyle.toml" };
const unnecessary = [_][]const u8{ "TS011", "TS013", "TS015", "TS020", "TS021" };

pub fn init(
    session: *Session,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    limits: *const Limits,
) std.mem.Allocator.Error!void {
    assert(options.mode == .server);
    assert(limits.document_count_max > 0);

    session.io = io;
    session.rules = try .init(gpa);
    session.configuration = try .init(gpa, &limits.configuration());
    session.settings = session.configuration.draft.settings(null, &session.rules.registry);
    session.config = try .init(gpa, limits.path_bytes_max);

    session.configured = .{
        .directory = try .init(gpa, limits.path_bytes_max),
        .editor_index = 0,
        .located = false,
        .valid = false,
    };

    session.config_take(options);

    try session.analysis.init(gpa, io, &limits.analysis());

    session.documents = try .init(gpa, &limits.documents());

    for (&session.editors) |*editor| editor.* = try .init(gpa);

    session.faults = try .init(gpa, Limits.selector_count_max);

    session.folders = try .init(gpa, .{
        .path_bytes_max = limits.path_bytes_max,
        .root_count_max = Editor.folder_count_max,
    });

    session.path = try .init(gpa, limits.path_bytes_max);
    session.uri_text = try .init(gpa, uri_text_bytes_max(limits));

    try session.sender.init(gpa, io, .{ .body_bytes_max = limits.message_bytes_max });

    session.apply_edit = false;
    session.encoding = .utf16;
    session.exit_code = cli.exit_failure;
    session.isolated = options.isolated;
    session.pull = false;
    session.resolve = false;
    session.state = .uninitialized;

    assert(session.documents.count() == 0);
    assert(session.folders.count() == 0);
}

fn config_take(session: *Session, options: *const Options) void {
    assert(session.config.empty());

    const path = options.config orelse return;

    session.config.push(path) catch |err| switch (err) {
        error.Overflow => {
            session.config.clear();

            log.line(
                "the --config path is longer than {d} bytes or is not text; it is ignored",
                .{session.config.capacity()},
            );
        },
    };
}

fn uri_text_bytes_max(limits: *const Limits) u32 {
    const bytes = scylla.uri.uri_bytes_max(limits.path_bytes_max);

    assert(bytes > limits.path_bytes_max);
    assert(bytes <= limits.uri_bytes_max);

    return bytes;
}

pub fn encoding_set(session: *Session, encoding: Encoding) void {
    session.encoding = encoding;

    session.documents.encoding_set(encoding);

    assert(session.encoding == encoding);
}

pub fn state_set(session: *Session, state: State) void {
    assert(session.state != .exited);
    assert(session.state != state);

    session.state = state;
}

pub fn analyze(session: *Session, handle: Handle) void {
    session.configure(handle);

    const entry = session.documents.get_mut(handle);

    entry.state.diagnostics.clear();
    session.analysis.run(entry, &session.rules, &session.settings);

    assert(entry.state.diagnostics.count() <= entry.state.diagnostics.capacity());
}

pub fn reject(session: *Session, handle: Handle, rejection: Rejection) void {
    session.configure(handle);

    const entry = session.documents.get_mut(handle);

    entry.state.diagnostics.clear();
    rejection_push(&entry.state.diagnostics, rejection);

    assert(entry.state.diagnostics.count() == 1);
}

fn rejection_push(diagnostics: *Diagnostics, rejection: Rejection) void {
    assert(diagnostics.empty());

    diagnostics.push(.{
        .code = Analysis.code_unnamed,
        .fix = null,
        .message = .{ .static = Document.rejection_text(rejection) },
        .related_count = 0,
        .related_start = 0,
        .rule = null,
        .severity = .warning,
        .span = .{ .offset = 0, .length = 0 },
    }) catch |err| switch (err) {
        error.RelatedExhausted, error.RowsExhausted => unreachable,
    };

    assert(diagnostics.count() == 1);
}

pub fn configuration_stale(session: *Session) void {
    session.configured.valid = false;

    assert(!session.configured.valid);
}

fn configure(session: *Session, handle: Handle) void {
    const language = session.documents.get(handle).state.language;
    const located = session.path_locate(handle);
    const draft = &session.configuration.draft;

    if (!session.configured_current(located)) session.draft_build(located);

    session.settings = draft.settings(language, &session.rules.registry);

    session.settings.ignore(draft.ignored_for(session.path.const_slice()));

    assert(session.configured.valid);
    assert(draft.thresholds.validate());
}

fn configured_current(session: *const Session, located: bool) bool {
    const configured = &session.configured;

    if (!configured.valid) return false;
    if (configured.located != located) return false;
    if (configured.editor_index != session.editor_index()) return false;

    return std.mem.eql(u8, configured.directory.const_slice(), session.path_directory());
}

fn draft_build(session: *Session, located: bool) void {
    const index = session.editor_index();
    const editor = &session.editors[index];
    const preference = editor.preference;
    const draft = &session.configuration.draft;

    draft.clear();

    if (preference == .filesystem_first) editor.apply(draft);
    if (preference != .editor_only) session.chain_apply(located);
    if (preference != .filesystem_first) editor.apply(draft);
    if (!draft.thresholds.validate()) draft.clear();

    session.configured_record(index, located);

    assert(draft.thresholds.validate());
}

fn configured_record(session: *Session, index: u32, located: bool) void {
    const configured = &session.configured;
    const directory = session.path_directory();

    assert(index <= Editor.folder_count_max);
    assert(directory.len <= configured.directory.capacity());

    configured.directory.clear();

    configured.directory.push(directory) catch |err| switch (err) {
        error.Overflow => unreachable,
    };

    configured.editor_index = index;
    configured.located = located;
    configured.valid = true;
}

fn path_directory(session: *const Session) []const u8 {
    const path = session.path.const_slice();
    const result = std.Io.Dir.path.dirname(path) orelse "";

    assert(result.len <= path.len);

    return result;
}

fn chain_apply(session: *Session, located: bool) void {
    if (session.isolated) return;

    session.configuration.resolver.clear();

    const found = session.chain_found(located) orelse return;
    const registry = &session.rules.registry;

    session.configuration.read(session.io, found, registry) catch {
        log.line("the configuration could not be read; the previous settings stand", .{});
    };
}

fn chain_found(session: *Session, located: bool) ?Span {
    const configuration = &session.configuration;

    assert(!session.isolated);

    if (!session.config.empty()) {
        assert(configuration.resolver.chain_count() == 0);
        assert(session.config.count() <= session.config.capacity());

        return configuration.resolver.record(session.config.const_slice()) catch unreachable;
    }

    if (!located) return null;
    return configuration.discover(session.io, session.path.const_slice(), .file);
}

fn path_locate(session: *Session, handle: Handle) bool {
    const uri = session.documents.get(handle).text.uri();

    assert(uri.len > 0);

    scylla.uri.decode(&session.path, uri) catch |err| switch (err) {
        error.Overflow, error.SchemeNotFile => {
            session.path.clear();

            return false;
        },
    };

    assert(session.path.count() <= uri.len);

    return true;
}

fn editor_index(session: *const Session) u32 {
    const found = session.folders.deepest(session.path.const_slice()) orelse {
        return Editor.folder_count_max;
    };

    assert(found < session.folders.count());
    assert(found < Editor.folder_count_max);

    return found;
}

pub fn fixes_on_save(session: *Session, handle: Handle) bool {
    const located = session.path_locate(handle);
    const index = session.editor_index();

    if (!located) assert(index == Editor.folder_count_max);

    return session.editors[index].fix_on_save;
}

pub fn roots_read(session: *Session, message: *const json.Document, params: json.Node) void {
    assert(session.state == .uninitialized);

    session.folders.read(message, params) catch |err| switch (err) {
        error.Empty, error.Overflow => {
            log.line("dropping a workspace folder past the folder table", .{});
        },
    };

    assert(session.folders.count() <= Editor.folder_count_max);
}

pub fn editor_read(
    session: *Session,
    index: u32,
    message: *const json.Document,
    settings: json.Node,
) Sender.Error!void {
    assert(index < Editor.editor_count);

    session.faults.clear();
    session.editors[index].read(message, settings, &session.rules.registry, &session.faults);
    session.configuration_stale();

    for (session.faults.const_slice()) |faulted| {
        try session.show_message(faulted.field, faulted.fault.reason());
    }
}

fn show_message(session: *Session, field: []const u8, reason: []const u8) Sender.Error!void {
    assert(field.len > 0);
    assert(reason.len > 0);

    log.line("tigerstyle.{s}: {s} (named by the editor settings)", .{ field, reason });

    const writer = session.sender.notify_open("window/showMessage") orelse return;

    try session.sender.sent(shown_write(writer, field, reason));
}

fn shown_write(writer: *json.Writer, field: []const u8, reason: []const u8) json.Writer.Error!void {
    try writer.object_begin();
    try writer.key("type");
    try writer.integer(2);
    try writer.key("message");
    try writer.string_begin();
    try writer.string_part("tigerstyle.");
    try writer.string_part(field);
    try writer.string_part(": ");
    try writer.string_part(reason);
    try writer.string_part(" (named by the editor settings)");
    try writer.string_end();
    try writer.object_end();
}

pub fn configuration_pull(session: *Session) Sender.Error!void {
    assert(session.folders.count() <= Editor.folder_count_max);

    const writer = session.sender.request_open(
        configuration_request,
        "workspace/configuration",
    ) orelse return;

    try session.sender.sent(session.pulled_write(writer));
}

fn pulled_write(session: *Session, writer: *json.Writer) json.Writer.Error!void {
    try writer.object_begin();
    try writer.key("items");
    try writer.array_begin();

    for (0..session.folders.count()) |index| {
        const folder = session.folders.at(@intCast(index));

        scylla.uri.encode(&session.uri_text, folder) catch |err| switch (err) {
            error.Overflow => unreachable,
        };

        try writer.object_begin();
        try writer.key("scopeUri");
        try writer.string(session.uri_text.const_slice());
        try writer.key("section");
        try writer.string("tigerstyle");
        try writer.object_end();
    }

    try writer.object_begin();
    try writer.key("section");
    try writer.string("tigerstyle");
    try writer.object_end();
    try writer.array_end();
    try writer.object_end();
}

pub fn reload(session: *Session) Sender.Error!void {
    session.configuration_stale();

    var handles = session.documents.handles();

    for (0..handles.remaining + 1) |_| {
        const handle = handles.next() orelse break;

        session.analyze(handle);

        try session.publish(handle);
    } else unreachable;

    assert(handles.remaining == 0);
}

pub fn watchers_register(session: *Session) Sender.Error!void {
    assert(session.state == .initialized);

    const writer = session.sender.request_open(
        register_request,
        "client/registerCapability",
    ) orelse return;

    try session.sender.sent(registration_write(writer));
}

fn registration_write(writer: *json.Writer) json.Writer.Error!void {
    assert(configuration_patterns.len > 0);

    try writer.object_begin();
    try writer.key("registrations");
    try writer.array_begin();
    try writer.object_begin();
    try writer.key("id");
    try writer.string("tigerstyle-lsp-configuration");
    try writer.key("method");
    try writer.string("workspace/didChangeWatchedFiles");
    try writer.key("registerOptions");
    try writer.object_begin();
    try writer.key("watchers");
    try writer.array_begin();

    for (configuration_patterns) |pattern| {
        try writer.object_begin();
        try writer.key("globPattern");
        try writer.string(pattern);
        try writer.object_end();
    }

    try writer.array_end();
    try writer.object_end();
    try writer.object_end();
    try writer.array_end();
    try writer.object_end();
}

pub fn debug_log(session: *const Session) void {
    assert(session.state == .initialized);

    log.line("tigerstyle-lsp {s}", .{cli.version});
    log.line("encoding: {s}", .{session.encoding.name()});
    log.line("pull diagnostics: {}", .{session.pull});
    log.line("open documents: {d}", .{session.documents.count()});
    log.line("rules: {d}", .{session.rules.count()});
}

pub fn publish(session: *Session, handle: Handle) Sender.Error!void {
    if (session.pull) return;

    const document = session.documents.get(handle);

    assert(document.text.uri().len > 0);

    const writer = session.sender.notify_open("textDocument/publishDiagnostics") orelse return;

    try session.sender.sent(published_write(writer, document));
}

fn published_write(writer: *json.Writer, document: View) json.Writer.Error!void {
    const diagnostics = &document.state.diagnostics;

    try writer.object_begin();
    try writer.key("uri");
    try writer.string(document.text.uri());
    try writer.key("version");
    try writer.integer(document.text.version_get());
    try writer.key("diagnostics");
    try writer.array_begin();

    for (diagnostics.slice()) |*diagnostic| try diagnostic_write(writer, document, diagnostic);

    if (diagnostics.is_overflowed()) try overflow_write(writer, document);

    try writer.array_end();
    try writer.object_end();
}

pub fn fix_on_save(session: *Session, handle: Handle) Sender.Error!void {
    assert(session.apply_edit);

    const document = session.documents.get(handle);

    const writer = session.sender.request_open(
        fix_on_save_request,
        "workspace/applyEdit",
    ) orelse return;

    try session.sender.sent(saved_write(writer, document, &session.analysis.fixes));
}

fn saved_write(
    writer: *json.Writer,
    document: View,
    fixes: *const scylla.Fixes,
) json.Writer.Error!void {
    assert(document.text.uri().len > 0);

    try writer.object_begin();
    try writer.key("label");
    try writer.string("TigerStyle: Fix all on save");
    try writer.key("edit");
    try writer.object_begin();
    try writer.key("changes");
    try writer.object_begin();
    try writer.key(document.text.uri());
    try writer.array_begin();

    try safe_edits_write(writer, document, fixes);

    try writer.array_end();
    try writer.object_end();
    try writer.object_end();
    try writer.object_end();
}

pub fn safe_edits_write(
    writer: *json.Writer,
    document: View,
    fixes: *const scylla.Fixes,
) json.Writer.Error!void {
    var cursor: u32 = 0;

    for (document.state.diagnostics.slice()) |*diagnostic| {
        const fix = fixes.fix_of(diagnostic) orelse continue;
        if (!fix.applicability.reaches(.safe)) continue;

        for (fixes.edits_of(&fix)) |*edit| {
            if (edit.span.offset < cursor) continue;

            try text_edit_write(writer, document, edit.span, fixes.replacement_of(edit));
            cursor = edit.span.end();
        }
    }

    assert(cursor <= document.text.text_count());
}

pub fn text_edit_write(
    writer: *json.Writer,
    document: View,
    span: Span,
    text: []const u8,
) json.Writer.Error!void {
    assert(span.end() <= document.text.text_count());

    try writer.object_begin();
    try writer.key("range");
    try lsp.range_write(writer, document.text.range_of(span));
    try writer.key("newText");
    try writer.string(text);
    try writer.object_end();
}

pub fn respond_report(session: *Session, id: Id, handle: Handle) Sender.Error!void {
    assert(id.is_request());

    const document = session.documents.get(handle);
    const writer = session.sender.respond_open(id) orelse return;

    try session.sender.sent(reported_write(writer, document, report_identifier(document)));
}

fn reported_write(writer: *json.Writer, document: View, result: i64) json.Writer.Error!void {
    assert(result >= 0);

    try writer.object_begin();
    try writer.key("kind");
    try writer.string("full");
    try writer.key("resultId");
    try writer.integer(result);
    try writer.key("items");
    try writer.array_begin();

    for (document.state.diagnostics.slice()) |*diagnostic| {
        try diagnostic_write(writer, document, diagnostic);
    }

    try writer.array_end();
    try writer.object_end();
}

pub fn respond_workspace_report(
    session: *Session,
    id: Id,
    message: *const json.Document,
    params: ?json.Node,
) Sender.Error!void {
    assert(id.is_request());

    const writer = session.sender.respond_open(id) orelse return;

    try session.sender.sent(session.swept_write(writer, message, params));
}

fn swept_write(
    session: *const Session,
    writer: *json.Writer,
    message: *const json.Document,
    params: ?json.Node,
) json.Writer.Error!void {
    var handles = session.documents.handles();

    try writer.object_begin();
    try writer.key("items");
    try writer.array_begin();

    for (0..handles.remaining + 1) |_| {
        const handle = handles.next() orelse break;

        try swept_item_write(writer, session.documents.get(handle), message, params);
    } else unreachable;

    try writer.array_end();
    try writer.object_end();
}

fn swept_item_write(
    writer: *json.Writer,
    document: View,
    message: *const json.Document,
    params: ?json.Node,
) json.Writer.Error!void {
    const result = report_identifier(document);
    const previous = identifier_previous(message, params, document.text.uri());
    const unchanged = if (previous) |held| held == result else false;

    try writer.object_begin();
    try writer.key("kind");
    try writer.string(if (unchanged) "unchanged" else "full");
    try writer.key("uri");
    try writer.string(document.text.uri());
    try writer.key("version");
    try writer.integer(document.text.version_get());
    try writer.key("resultId");
    try writer.integer(result);

    if (!unchanged) {
        try writer.key("items");
        try writer.array_begin();

        for (document.state.diagnostics.slice()) |*diagnostic| {
            try diagnostic_write(writer, document, diagnostic);
        }

        try writer.array_end();
    }

    try writer.object_end();
}

fn identifier_previous(message: *const json.Document, params: ?json.Node, uri: []const u8) ?i64 {
    const held = params orelse return null;
    const listed = message.member(held, "previousResultIds") orelse return null;
    if (message.kind_of(listed) != .array) return null;

    var items = message.items(listed);

    for (0..items.remaining + 1) |_| {
        const item = items.next() orelse return null;
        const named = message.member(item, "uri") orelse continue;
        if (!message.text_is(named, uri)) continue;

        const value = message.member(item, "value") orelse return null;
        return message.integer_of(value);
    } else unreachable;
}

fn report_identifier(document: View) i64 {
    var hasher = std.hash.Fnv1a_64.init();

    for (document.state.diagnostics.slice()) |*diagnostic| {
        var offset: [4]u8 = undefined;

        std.mem.writeInt(u32, &offset, diagnostic.span.offset, .little);
        hasher.update(code_wire(diagnostic));
        hasher.update(&offset);
    }

    const value = hasher.final();
    const magnitude: u64 = if (value <= std.math.maxInt(i64)) value else 0 -% value;
    const result = std.math.cast(i64, magnitude) orelse std.math.maxInt(i64);

    assert(result >= 0);

    return result;
}

pub fn code_wire(diagnostic: *const Diagnostic) []const u8 {
    assert(diagnostic.code.len > 0);

    if (std.mem.eql(u8, diagnostic.code, Analysis.code_unnamed)) return "";
    return diagnostic.code;
}

pub fn diagnostic_write(
    writer: *json.Writer,
    document: View,
    diagnostic: *const Diagnostic,
) json.Writer.Error!void {
    const code = code_wire(diagnostic);

    try writer.object_begin();
    try writer.key("range");
    try lsp.range_write(writer, document.text.range_of(diagnostic.span));
    try writer.key("severity");
    try writer.integer(diagnostic.severity.lsp_code());

    if (code.len > 0) {
        try writer.key("code");
        try writer.string(code);
    }

    if (is_unnecessary(code)) {
        try writer.key("tags");
        try writer.array_begin();
        try writer.integer(1);
        try writer.array_end();
    }

    try writer.key("source");
    try writer.string(source);
    try writer.key("message");
    try writer.string(document.state.diagnostics.message_of(diagnostic));
    try writer.object_end();
}

fn is_unnecessary(code: []const u8) bool {
    for (unnecessary) |listed| {
        if (std.mem.eql(u8, listed, code)) return true;
    }

    return false;
}

fn overflow_write(writer: *json.Writer, document: View) json.Writer.Error!void {
    assert(document.state.diagnostics.is_overflowed());

    try writer.object_begin();
    try writer.key("range");
    try lsp.range_write(writer, document.text.range_of(.{ .offset = 0, .length = 0 }));
    try writer.key("severity");
    try writer.integer(scylla.Diagnostics.Severity.information.lsp_code());
    try writer.key("source");
    try writer.string(source);
    try writer.key("message");
    try writer.string("the findings for this file were truncated");
    try writer.object_end();
}

pub fn prefix_of(session: *const Session, handle: Handle) []const u8 {
    const language = session.documents.get(handle).state.language orelse return "//";
    const grammar = Grammar.of(language);

    assert(grammar.comment_prefix.len > 0);

    return grammar.comment_prefix;
}
