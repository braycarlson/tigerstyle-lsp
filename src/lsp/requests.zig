const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../scan.zig");
const Clock = scylla.timing.Clock;
const Diagnostic = scylla.Diagnostics.Diagnostic;
const Encoding = scylla.LineIndex.Encoding;
const Envelope = scylla.transport.rpc.Envelope;
const Handle = scylla.Documents.Handle;
const Rule = scylla.rule.Rule;
const json = @import("json");
const log = scylla.log;
const lsp = scylla.lsp;
const Sender = @import("sender.zig");
const Session = @import("session.zig");
const View = @import("../document.zig").View;
const actions = @import("actions.zig");
const cli = @import("../cli.zig");

const Command = enum {
    debug,
    suppress_all,
    suppress_file,
    unknown,
};

const Hovered = struct {
    document: View,
    finding: Diagnostic,
    rule: ?*const Rule,
};

const Progress = struct {
    begun: bool,
    message: *const json.Document,
    opened: Clock,
    token: ?json.Node,

    const Kind = enum {
        begin,
        end,
        report,
    };

    fn report(progress: *Progress, session: *Session, checked: u32, count: u32) Sender.Error!void {
        assert(checked > 0);
        assert(checked <= count);

        if (progress.token == null) return;
        if (progress.opened.nanoseconds() < progress_delay_ns) return;

        try progress.begin(session);

        const scaled: u64 = @as(u64, checked) * 100;
        const percentage = @divFloor(scaled, @as(u64, @max(count, 1)));

        try progress.send(session, .report, @intCast(percentage));
    }

    fn begin(progress: *Progress, session: *Session) Sender.Error!void {
        assert(progress.token != null);

        if (progress.begun) return;

        progress.begun = true;

        try progress.send(session, .begin, 0);
    }

    fn finish(progress: *Progress, session: *Session) Sender.Error!void {
        if (!progress.begun) return;

        progress.begun = false;

        assert(progress.token != null);

        try progress.send(session, .end, 0);
    }

    fn send(
        progress: *const Progress,
        session: *Session,
        kind: Kind,
        percentage: i64,
    ) Sender.Error!void {
        assert(percentage >= 0);
        assert(percentage <= 100);

        const writer = session.sender.notify_open("$/progress") orelse return;

        try session.sender.sent(progress.step_write(writer, kind, percentage));
    }

    fn step_write(
        progress: *const Progress,
        writer: *json.Writer,
        kind: Kind,
        percentage: i64,
    ) json.Writer.Error!void {
        try writer.object_begin();
        try writer.key("token");

        if (progress.token) |token| {
            try writer.raw(progress.message.source_of(token));
        } else {
            try writer.null_value();
        }

        try writer.key("value");
        try writer.object_begin();
        try writer.key("kind");
        try writer.string(@tagName(kind));

        switch (kind) {
            .begin => {
                try writer.key("title");
                try writer.string("tigerstyle-lsp");
                try writer.key("message");
                try writer.string("Checking the workspace");
            },
            .end => {},
            .report => {
                try writer.key("percentage");
                try writer.integer(percentage);
            },
        }

        try writer.object_end();
        try writer.object_end();
    }
};

const label_all = "TigerStyle: Suppress every finding in this file";
const label_file = "TigerStyle: Suppress this file";
const listing_bytes_max: u32 = scylla.limits.rule_count_max * 7;
const progress_delay_ns: u64 = 250 * std.time.ns_per_ms;
const suppress_request: i64 = 2;

pub fn initialize(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.Error!void {
    if (!envelope.id.is_request()) return;

    if (session.state != .uninitialized) {
        return session.sender.respond_error(
            envelope.id,
            .invalid_request,
            "the server is already initialized",
        );
    }

    if (envelope.params) |params| {
        session.encoding_set(lsp.encoding_negotiate(message, params));
        session.pull = capability_of(message, params, "textDocument", "diagnostic") != null;
        session.apply_edit = applies_edits(message, params);
        session.resolve = resolves_actions(message, params);

        session.roots_read(message, params);
    }

    const writer = session.sender.respond_open(envelope.id) orelse return;

    try session.sender.sent(advertised_write(writer, session.encoding, session.resolve));
    session.state_set(.initialized);

    assert(session.state == .initialized);
}

fn capability_of(
    message: *const json.Document,
    params: json.Node,
    outer: []const u8,
    inner: []const u8,
) ?json.Node {
    assert(outer.len > 0);
    assert(inner.len > 0);

    const capabilities = message.member(params, "capabilities") orelse return null;
    const held = message.member(capabilities, outer) orelse return null;

    return message.member(held, inner);
}

fn applies_edits(message: *const json.Document, params: json.Node) bool {
    const held = capability_of(message, params, "workspace", "applyEdit") orelse return false;
    const applies = message.boolean_of(held) orelse return false;

    assert(message.kind_of(held) == .boolean);

    return applies;
}

fn resolves_actions(message: *const json.Document, params: json.Node) bool {
    const code_action = capability_of(message, params, "textDocument", "codeAction") orelse {
        return false;
    };

    const resolves = message.member(code_action, "resolveSupport") != null;

    if (resolves) assert(message.kind_of(code_action) == .object);

    return resolves;
}

fn advertised_write(
    writer: *json.Writer,
    encoding: Encoding,
    resolve: bool,
) json.Writer.Error!void {
    try writer.object_begin();
    try writer.key("capabilities");
    try writer.object_begin();
    try writer.key("positionEncoding");
    try writer.string(encoding.name());
    try writer.key("textDocumentSync");
    try writer.object_begin();
    try writer.key("openClose");
    try writer.boolean(true);
    try writer.key("change");
    try writer.integer(2);
    try writer.key("save");
    try writer.object_begin();
    try writer.key("includeText");
    try writer.boolean(false);
    try writer.object_end();
    try writer.object_end();
    try writer.key("hoverProvider");
    try writer.boolean(true);
    try writer.key("diagnosticProvider");
    try writer.object_begin();
    try writer.key("identifier");
    try writer.string("tigerstyle-lsp");
    try writer.key("interFileDependencies");
    try writer.boolean(false);
    try writer.key("workspaceDiagnostics");
    try writer.boolean(true);
    try writer.object_end();
    try providers_write(writer, resolve);
    try writer.object_end();
    try writer.key("serverInfo");
    try writer.object_begin();
    try writer.key("name");
    try writer.string("tigerstyle-lsp");
    try writer.key("version");
    try writer.string(cli.version);
    try writer.object_end();
    try writer.object_end();
}

fn providers_write(writer: *json.Writer, resolve: bool) json.Writer.Error!void {
    try writer.key("codeActionProvider");
    try writer.object_begin();
    try writer.key("codeActionKinds");
    try writer.array_begin();
    try writer.string("quickfix");
    try writer.string("source.fixAll");
    try writer.string("source.fixAll.tigerstyle");
    try writer.array_end();
    try writer.key("resolveProvider");
    try writer.boolean(resolve);
    try writer.object_end();
    try writer.key("workspace");
    try writer.object_begin();
    try writer.key("workspaceFolders");
    try writer.object_begin();
    try writer.key("changeNotifications");
    try writer.boolean(true);
    try writer.key("supported");
    try writer.boolean(true);
    try writer.object_end();
    try writer.object_end();
    try writer.key("executeCommandProvider");
    try writer.object_begin();
    try writer.key("commands");
    try writer.array_begin();
    try writer.string("tigerstyle.suppressFile");
    try writer.string("tigerstyle.suppressAll");
    try writer.string("tigerstyle.printDebugInformation");
    try writer.array_end();
    try writer.object_end();
}

pub fn shutdown(session: *Session, envelope: *const Envelope) Sender.Error!void {
    if (!envelope.id.is_request()) return;

    assert(session.state == .initialized);

    try session.sender.respond_null(envelope.id);
    session.state_set(.shutting_down);
}

pub fn hover(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.Error!void {
    if (!envelope.id.is_request()) return;

    const hovered = hovered_of(session, message, envelope) orelse {
        return session.sender.respond_null(envelope.id);
    };

    assert(hovered.finding.code.len > 0);

    const writer = session.sender.respond_open(envelope.id) orelse return;

    try session.sender.sent(hovered_write(writer, &hovered));
}

fn hovered_of(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) ?Hovered {
    const params = envelope.params orelse return null;
    const uri = lsp.text_document_string(message, params, "uri") orelse return null;
    const handle = session.documents.find_text(message, uri) orelse return null;
    const position = lsp.position_of(message, params) orelse return null;
    const document = session.documents.get(handle);
    const offset = document.text.offset_of(position) orelse return null;
    const finding = finding_at(document, offset) orelse return null;

    assert(offset >= finding.span.offset);

    return .{
        .document = document,
        .finding = finding,
        .rule = session.rules.of(&finding),
    };
}

fn finding_at(document: View, offset: u32) ?Diagnostic {
    assert(offset <= document.text.text_count());

    for (document.state.diagnostics.slice()) |held| {
        if (offset < held.span.offset) continue;
        if (offset > held.span.end()) continue;
        return held;
    }

    return null;
}

fn hovered_write(writer: *json.Writer, hovered: *const Hovered) json.Writer.Error!void {
    const document = hovered.document;
    const message = document.state.diagnostics.message_of(&hovered.finding);

    try writer.object_begin();
    try writer.key("contents");
    try writer.object_begin();
    try writer.key("kind");
    try writer.string("markdown");
    try writer.key("value");
    try writer.string_begin();

    if (hovered.rule) |rule| {
        try writer.string_part("**");
        try writer.string_part(rule.code);
        try writer.string_part(" ");
        try writer.string_part(rule.name);
        try writer.string_part("**\n\n");
        try writer.string_part(rule.description);
        try writer.string_part("\n\n");
    }

    try writer.string_part(scan.utf8_or(message, ""));
    try writer.string_end();
    try writer.object_end();
    try writer.key("range");
    try lsp.range_write(writer, document.text.range_of(hovered.finding.span));
    try writer.object_end();
}

pub fn diagnostic(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.Error!void {
    if (!envelope.id.is_request()) return;

    const params = envelope.params orelse return empty_respond(session, envelope);

    const uri = lsp.text_document_string(message, params, "uri") orelse {
        return empty_respond(session, envelope);
    };

    const handle = session.documents.find_text(message, uri) orelse {
        return empty_respond(session, envelope);
    };

    assert(session.documents.count() > 0);

    try session.respond_report(envelope.id, handle);
}

fn empty_respond(session: *Session, envelope: *const Envelope) Sender.Error!void {
    const writer = session.sender.respond_open(envelope.id) orelse return;

    try session.sender.sent(empty_write(writer));
}

fn empty_write(writer: *json.Writer) json.Writer.Error!void {
    try writer.object_begin();
    try writer.key("kind");
    try writer.string("full");
    try writer.key("items");
    try writer.array_begin();
    try writer.array_end();
    try writer.object_end();
}

pub fn workspace_diagnostic(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.Error!void {
    if (!envelope.id.is_request()) return;

    const count = session.documents.count();
    const token = if (envelope.params) |params| message.member(params, "workDoneToken") else null;

    var progress: Progress = .{
        .begun = false,
        .message = message,
        .opened = .init(session.io),
        .token = token,
    };

    var handles = session.documents.handles();
    var checked: u32 = 0;

    for (0..handles.remaining + 1) |_| {
        const handle = handles.next() orelse break;

        session.analyze(handle);
        checked += 1;

        try progress.report(session, checked, count);
    } else unreachable;

    assert(checked == count);

    try progress.finish(session);
    try session.respond_workspace_report(envelope.id, message, envelope.params);
}

pub fn command(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.Error!void {
    if (!envelope.id.is_request()) return;

    const params = envelope.params orelse return session.sender.respond_null(envelope.id);
    const named_node = message.member(params, "command");
    const arguments = message.member(params, "arguments");
    const named: Command = if (named_node) |held| command_of(message, held) else .unknown;
    const uri = if (arguments) |listed| argument_uri(message, listed) else null;

    switch (named) {
        .debug => session.debug_log(),
        .suppress_all => try suppress(session, message, uri, .listed),
        .suppress_file => try suppress(session, message, uri, .star),
        .unknown => {},
    }

    try session.sender.respond_null(envelope.id);
}

fn command_of(message: *const json.Document, name: json.Node) Command {
    const commands = [_]struct { []const u8, Command }{
        .{ "tigerstyle.printDebugInformation", .debug },
        .{ "tigerstyle.suppressAll", .suppress_all },
        .{ "tigerstyle.suppressFile", .suppress_file },
    };

    for (commands) |held| {
        if (message.text_is(name, held[0])) return held[1];
    }

    return .unknown;
}

fn argument_uri(message: *const json.Document, arguments: json.Node) ?json.Node {
    if (message.kind_of(arguments) != .array) return null;

    var items = message.items(arguments);

    for (0..items.remaining + 1) |_| {
        const item = items.next() orelse return null;
        if (message.kind_of(item) == .string) return item;
    } else unreachable;
}

const Codes = enum {
    listed,
    star,
};

fn suppress(
    session: *Session,
    message: *const json.Document,
    uri: ?json.Node,
    codes: Codes,
) Sender.Error!void {
    if (!session.apply_edit) {
        log.line("the client does not support workspace/applyEdit", .{});

        return;
    }

    const named = uri orelse {
        log.line("dropping a suppress command without a document uri", .{});

        return;
    };

    const handle = session.documents.find_text(message, named) orelse {
        log.line("dropping a suppress command for a document that is not open", .{});

        return;
    };

    var listing: [listing_bytes_max]u8 = undefined;

    const length = switch (codes) {
        .listed => codes_written(session, handle, &listing),
        .star => star_written(&listing),
    };

    if (length == 0) return;

    const label = switch (codes) {
        .listed => label_all,
        .star => label_file,
    };

    const writer = session.sender.request_open(suppress_request, "workspace/applyEdit") orelse {
        return;
    };

    try session.sender.sent(suppressed_write(
        writer,
        label,
        session.documents.get(handle),
        session.prefix_of(handle),
        scan.utf8_or(listing[0..length], "*"),
    ));
}

fn suppressed_write(
    writer: *json.Writer,
    label: []const u8,
    document: View,
    prefix: []const u8,
    codes: []const u8,
) json.Writer.Error!void {
    assert(label.len > 0);

    try writer.object_begin();
    try writer.key("label");
    try writer.string(label);
    try writer.key("edit");
    try actions.suppress_file_edit(writer, document, prefix, codes);
    try writer.object_end();
}

fn codes_written(session: *const Session, handle: Handle, listing: *[listing_bytes_max]u8) u32 {
    const document = session.documents.get(handle);
    var named: scylla.rule.CodeSet = .empty;

    for (document.state.diagnostics.slice()) |held| {
        const code = held.rule orelse continue;

        named.insert(code);
    }

    const registry = &session.rules.registry;

    const length = registry.codes_written(listing, named) catch |err| switch (err) {
        error.TargetExhausted => return 0,
    };

    assert(length <= listing.len);

    return length;
}

fn star_written(listing: *[listing_bytes_max]u8) u32 {
    assert(listing.len > 0);

    listing[0] = '*';

    return 1;
}
