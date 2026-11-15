const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = scylla.scan;
const Diagnostic = scylla.Diagnostics.Diagnostic;
const Envelope = scylla.transport.rpc.Envelope;
const Fixes = scylla.Fixes;
const json = @import("json");
const lsp = scylla.lsp;
const Sender = scylla.transport.Sender;
const Session = @import("session.zig");
const View = @import("../linter/document.zig").View;

const Only = struct {
    fix_all: bool,
    quickfix: bool,

    pub const every: Only = .{ .fix_all = true, .quickfix = true };
};

const Action = struct {
    data: ?json.Node,
    diagnostics: ?json.Node,
    kind: ?json.Node,
    title: ?json.Node,

    const empty: Action = .{ .data = null, .diagnostics = null, .kind = null, .title = null };
};

const Offered = struct {
    deferred: bool,
    document: View,
    fixes: *const Fixes,
    only: Only,
    prefix: []const u8,
};

const Payload = struct {
    file: bool,
    line: u32,
    rule_bytes: [scylla.limits.rule_code_bytes_max]u8,
    rule_length: u8,
    uri: json.Node,

    fn rule(payload: *const Payload) []const u8 {
        assert(payload.rule_length <= payload.rule_bytes.len);

        return payload.rule_bytes[0..payload.rule_length];
    }
};

const Resolved = struct {
    action: Action,
    message: *const json.Document,
    target: ?Target,
};

const Target = struct {
    document: View,
    payload: Payload,
    prefix: []const u8,
};

const kind_file = "suppressFile";
const kind_line = "suppressLine";

pub fn code_action(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.WriteError!void {
    if (!envelope.id.is_request()) return;

    const parameters = envelope.params orelse return empty_respond(session, envelope);

    const uri = lsp.text_document_string(message, parameters, "uri") orelse {
        return empty_respond(session, envelope);
    };

    const handle = session.documents.find_text(message, uri) orelse {
        return empty_respond(session, envelope);
    };

    const offered: Offered = .{
        .deferred = session.resolve,
        .document = session.documents.get(handle),
        .fixes = &session.analysis.fixes,
        .only = context_only(message, parameters),
        .prefix = session.prefix_of(handle),
    };

    assert(offered.prefix.len > 0);

    const writer = session.sender.respond_open(&envelope.id) catch |err| {
        return session.sender.dropped(err);
    };

    try session.sender.delivered(offered_write(writer, &offered));
}

fn context_only(message: *const json.Document, parameters: json.Node) Only {
    const context = message.member(parameters, "context") orelse return .every;
    const kinds = message.member(context, "only") orelse return .every;
    if (message.kind_of(kinds) != .array) return .every;

    var only: Only = .{ .fix_all = false, .quickfix = false };
    var items = message.items(kinds);

    for (0..items.remaining + 1) |_| {
        const requested = items.next() orelse break;

        if (lsp.kind_covers(message, requested, "quickfix")) only.quickfix = true;
        if (lsp.kind_covers(message, requested, "source.fixAll.tigerstyle")) only.fix_all = true;
    } else unreachable;

    return only;
}

fn empty_respond(session: *Session, envelope: *const Envelope) Sender.WriteError!void {
    const writer = session.sender.respond_open(&envelope.id) catch |err| {
        return session.sender.dropped(err);
    };

    try session.sender.delivered(empty_write(writer));
}

fn empty_write(writer: *json.Writer) json.Writer.Error!void {
    try writer.array_begin();
    try writer.array_end();
}

fn offered_write(writer: *json.Writer, offered: *const Offered) json.Writer.Error!void {
    const document = offered.document;

    try writer.array_begin();

    if (!offered.only.quickfix) {
        if (offered.only.fix_all) try fix_all_write(writer, document, offered.fixes);

        try writer.array_end();

        return;
    }

    for (document.state.diagnostics.slice()) |*diagnostic| {
        try quickfix_write(writer, document, offered.fixes, diagnostic);
    }

    try suppress_line_write(writer, offered);
    try suppress_file_write(writer, offered);

    if (offered.only.fix_all) try fix_all_write(writer, document, offered.fixes);

    try writer.array_end();
}

fn quickfix_write(
    writer: *json.Writer,
    document: View,
    fixes: *const Fixes,
    diagnostic: *const Diagnostic,
) json.Writer.Error!void {
    assert(document.file.uri().len > 0);

    const fix = fixes.fix_of(diagnostic) orelse return;
    if (!fix.applicability.reaches(.safe)) return;

    assert(fix.applicability != .display_only);

    try writer.object_begin();
    try writer.key("title");
    try writer.string(fixes.title_of(&fix));
    try writer.key("kind");
    try writer.string("quickfix");
    try writer.key("edit");
    try edit_open(writer, document);

    for (fixes.edits_of(&fix)) |*edit| {
        try Session.text_edit_write(writer, document, edit.span, fixes.replacement_of(edit));
    }

    try edit_close(writer);
    try writer.object_end();
}

fn fix_all_write(writer: *json.Writer, document: View, fixes: *const Fixes) json.Writer.Error!void {
    assert(document.file.uri().len > 0);

    var edits: u32 = 0;

    for (document.state.diagnostics.slice()) |*diagnostic| {
        const fix = fixes.fix_of(diagnostic) orelse continue;

        if (fix.applicability.reaches(.safe)) edits += fix.edit_count;
    }

    if (edits == 0) return;

    try writer.object_begin();
    try writer.key("title");
    try writer.string("Fix all TigerStyle findings");
    try writer.key("kind");
    try writer.string("source.fixAll.tigerstyle");
    try writer.key("edit");
    try edit_open(writer, document);
    try Session.safe_edits_write(writer, document, fixes);
    try edit_close(writer);
    try writer.object_end();
}

fn suppress_line_write(writer: *json.Writer, offered: *const Offered) json.Writer.Error!void {
    const document = offered.document;
    const diagnostics = document.state.diagnostics.slice();
    if (diagnostics.len == 0) return;

    try writer.object_begin();
    try writer.key("title");
    try writer.string("Suppress this finding on its line");
    try writer.key("kind");
    try writer.string("quickfix");

    const first = &diagnostics[0];

    try diagnostics_write(writer, document, first);

    const code = Session.code_wire(first);
    const line = document.file.point_of(first.span.offset).line;

    if (offered.deferred) {
        try data_write(writer, document, .{ .code = code, .kind = kind_line }, line);
        try writer.object_end();

        return;
    }

    try writer.key("edit");
    try suppress_line_edit(writer, document, .{ .code = code, .prefix = offered.prefix }, line);
    try writer.object_end();
}

fn suppress_file_write(writer: *json.Writer, offered: *const Offered) json.Writer.Error!void {
    const document = offered.document;
    const diagnostics = document.state.diagnostics.slice();
    if (diagnostics.len == 0) return;

    try writer.object_begin();
    try writer.key("title");
    try writer.string("Suppress every finding in this file");
    try writer.key("kind");
    try writer.string("quickfix");
    try diagnostics_write(writer, document, &diagnostics[0]);

    if (offered.deferred) {
        try data_write(writer, document, .{ .code = "*", .kind = kind_file }, 0);
        try writer.object_end();

        return;
    }

    try writer.key("edit");
    try suppress_file_edit(writer, document, .{ .codes = "*", .prefix = offered.prefix });
    try writer.object_end();
}

fn data_write(
    writer: *json.Writer,
    document: View,
    options: struct { code: []const u8, kind: []const u8 },
    line: u32,
) json.Writer.Error!void {
    assert(document.file.uri().len > 0);
    assert(line < document.file.line_count());
    assert(options.kind.len > 0);

    try writer.key("data");
    try writer.object_begin();
    try writer.key("kind");
    try writer.string(options.kind);
    try writer.key("line");
    try writer.integer(line);
    try writer.key("rule");
    try writer.string(options.code);
    try writer.key("uri");
    try writer.string(document.file.uri());
    try writer.object_end();
}

fn diagnostics_write(
    writer: *json.Writer,
    document: View,
    diagnostic: *const Diagnostic,
) json.Writer.Error!void {
    assert(document.state.diagnostics.count() > 0);

    try writer.key("diagnostics");
    try writer.array_begin();
    try Session.diagnostic_write(writer, document, diagnostic);
    try writer.array_end();
}

fn suppress_line_edit(
    writer: *json.Writer,
    document: View,
    options: struct { code: []const u8, prefix: []const u8 },
    line: u32,
) json.Writer.Error!void {
    assert(document.file.uri().len > 0);
    assert(line < document.file.line_count());

    const end = document.file.line_end_offset(line);

    assert(options.prefix.len > 0);
    assert(end <= document.file.text_count());

    try edit_open(writer, document);
    try writer.object_begin();
    try writer.key("range");
    try lsp.range_write(writer, document.file.range_of(.{ .offset = end, .length = 0 }));
    try writer.key("newText");
    try writer.string_begin();
    try writer.string_part("  ");
    try writer.string_part(options.prefix);
    try writer.string_part(" tigerstyle-ignore: ");
    try writer.string_part(options.code);
    try writer.string_end();
    try writer.object_end();
    try edit_close(writer);
}

pub fn suppress_file_edit(
    writer: *json.Writer,
    document: View,
    options: struct { codes: []const u8, prefix: []const u8 },
) json.Writer.Error!void {
    assert(document.file.uri().len > 0);

    const shebang = std.mem.startsWith(u8, document.file.line(0), "#!");
    const line: u32 = if (shebang) 1 else 0;
    const offset = document.file.line_start_offset(line);

    assert(options.prefix.len > 0);
    assert(offset <= document.file.text_count());

    try edit_open(writer, document);
    try writer.object_begin();
    try writer.key("range");
    try lsp.range_write(writer, document.file.range_of(.{ .offset = offset, .length = 0 }));
    try writer.key("newText");
    try writer.string_begin();
    try writer.string_part(options.prefix);
    try writer.string_part(" tigerstyle-file-ignore: ");
    try writer.string_part(options.codes);
    try writer.string_part("\n");
    try writer.string_end();
    try writer.object_end();
    try edit_close(writer);
}

fn edit_open(writer: *json.Writer, document: View) json.Writer.Error!void {
    assert(document.file.uri().len > 0);

    try writer.object_begin();
    try writer.key("changes");
    try writer.object_begin();
    try writer.key(document.file.uri());
    try writer.array_begin();
}

fn edit_close(writer: *json.Writer) json.Writer.Error!void {
    try writer.array_end();
    try writer.object_end();
    try writer.object_end();
}

pub fn code_action_resolve(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.WriteError!void {
    if (!envelope.id.is_request()) return;

    const parameters = envelope.params orelse {
        return session.sender.respond_null(&envelope.id) catch |err| session.sender.dropped(err);
    };

    var resolved: Resolved = .{
        .action = action_of(message, parameters),
        .message = message,
        .target = null,
    };

    if (resolved.action.data) |data| {
        if (payload_of(message, data)) |payload| {
            resolved.target = target_of(session, message, payload);
        }
    }

    const writer = session.sender.respond_open(&envelope.id) catch |err| {
        return session.sender.dropped(err);
    };

    try session.sender.delivered(resolved_write(writer, &resolved));
}

fn action_of(message: *const json.Document, parameters: json.Node) Action {
    if (message.kind_of(parameters) != .object) return .empty;

    return .{
        .data = message.member(parameters, "data"),
        .diagnostics = message.member(parameters, "diagnostics"),
        .kind = message.member(parameters, "kind"),
        .title = message.member(parameters, "title"),
    };
}

fn payload_of(message: *const json.Document, data: json.Node) ?Payload {
    const named = message.member(data, "kind") orelse return null;

    const file = file: {
        if (message.text_is(named, kind_file)) break :file true;
        if (message.text_is(named, kind_line)) break :file false;
        return null;
    };

    const line = message.member(data, "line") orelse return null;
    const rule = message.member(data, "rule") orelse return null;
    const uri = message.member(data, "uri") orelse return null;
    if (message.kind_of(uri) != .string) return null;
    if (message.kind_of(rule) != .string) return null;

    const line_number = message.unsigned_of(line) orelse return null;
    const decoded = message.text_of(rule) orelse return null;
    if (decoded.len > scylla.limits.rule_code_bytes_max) return null;

    var payload: Payload = .{
        .file = file,
        .line = std.math.cast(u32, line_number) orelse return null,
        .rule_bytes = undefined,
        .rule_length = 0,
        .uri = uri,
    };

    @memcpy(payload.rule_bytes[0..decoded.len], decoded);
    payload.rule_length = @intCast(decoded.len);

    return payload;
}

fn target_of(session: *Session, message: *const json.Document, payload: Payload) ?Target {
    assert(message.kind_of(payload.uri) == .string);

    const handle = session.documents.find_text(message, payload.uri) orelse return null;
    const document = session.documents.get(handle);

    if (!payload.file) {
        if (payload.line >= document.file.line_count()) return null;
    }

    return .{ .document = document, .payload = payload, .prefix = session.prefix_of(handle) };
}

fn resolved_write(writer: *json.Writer, resolved: *const Resolved) json.Writer.Error!void {
    const action = resolved.action;

    const fields = [_]struct { []const u8, ?json.Node }{
        .{ "title", action.title },
        .{ "kind", action.kind },
        .{ "diagnostics", action.diagnostics },
        .{ "data", action.data },
    };

    try writer.object_begin();

    for (fields) |field| {
        const held = field[1] orelse continue;

        try writer.key(field[0]);
        try writer.raw(resolved.message.source_of(held));
    }

    if (resolved.target) |target| {
        const rule = scan.utf8_or(target.payload.rule(), "*");

        try writer.key("edit");

        if (target.payload.file) {
            try suppress_file_edit(writer, target.document, .{
                .codes = rule,
                .prefix = target.prefix,
            });
        } else {
            try suppress_line_edit(
                writer,
                target.document,
                .{ .code = rule, .prefix = target.prefix },
                target.payload.line,
            );
        }
    }

    try writer.object_end();
}
