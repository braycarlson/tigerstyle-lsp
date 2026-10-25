const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const languages = @import("../languages.zig");
const Encoding = scylla.LineIndex.Encoding;
const Envelope = scylla.transport.rpc.Envelope;
const Handle = scylla.Documents.Handle;
const Rejection = scylla.TextDocument.Error;
const log = scylla.log;
const lsp = scylla.lsp;
const json = @import("json");
const Entry = @import("../document.zig").Entry;
const Sender = @import("sender.zig");
const Session = @import("session.zig");

const ChangeError = Rejection || error{ RangeBackward, RangeOutside };
const refuse_backward = "the change runs backward";
const refuse_range = "the change lies outside the document";

pub fn did_open(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.Error!void {
    const params = envelope.params orelse return;

    const uri = lsp.text_document_string(message, params, "uri") orelse {
        log.line("dropping an open without a uri", .{});

        return;
    };

    const handle = session.documents.open_text(message, uri) catch |err| switch (err) {
        error.DocumentsExhausted => {
            log.line("refusing an open past {d} documents", .{session.documents.count()});

            return;
        },
        error.UriInvalid, error.UriTooLong => {
            log.line("dropping an open with an unusable uri", .{});

            return;
        },
    };

    const entry = session.documents.get_mut(handle);
    const version = lsp.text_document_integer(message, params, "version") orelse 0;

    entry.state.language = languages.of_path(entry.text.uri());

    entry.text.version_set(version);

    const text = lsp.text_document_string(message, params, "text") orelse {
        log.line("dropping an open without text", .{});

        return;
    };

    entry.state.desynced = false;

    if (entry.text.text_set(message, text)) |_| {
        session.analyze(handle);
    } else |rejection| {
        session.reject(handle, rejection);
    }

    try session.publish(handle);
}

pub fn did_change(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.Error!void {
    const params = envelope.params orelse return;

    const uri = lsp.text_document_string(message, params, "uri") orelse {
        log.line("dropping a change without a uri", .{});

        return;
    };

    const handle = session.documents.find_text(message, uri) orelse {
        log.line("dropping a change for a document that is not open", .{});

        return;
    };

    if (session.documents.get(handle).state.desynced) {
        log.line("dropping a change for a document that is out of step with its client", .{});

        return;
    }

    var changes = lsp.Changes.init(message, params) catch |err| switch (err) {
        error.Malformed => {
            log.line("dropping a change that did not parse", .{});

            return;
        },
    };

    const version = lsp.text_document_integer(message, params, "version") orelse 0;
    const entry = session.documents.get_mut(handle);
    var applied: u32 = 0;
    var rejection: ?Rejection = null;

    for (0..changes.remaining) |_| {
        const change = changes.next() orelse break;

        change_apply(entry, message, session.encoding, change) catch |err| switch (err) {
            error.RangeBackward => return change_refused(session, handle, applied, refuse_backward),
            error.RangeOutside => return change_refused(session, handle, applied, refuse_range),
            error.LinesExhausted, error.TextExhausted, error.Utf8Invalid => |reason| {
                rejection = reason;

                break;
            },
        };

        applied += 1;
    }

    entry.text.version_set(version);

    if (rejection) |reason| {
        session.reject(handle, reason);
    } else {
        session.analyze(handle);
    }

    try session.publish(handle);
}

fn change_apply(
    entry: Entry,
    message: *const json.Document,
    encoding: Encoding,
    change: lsp.Changes.Change,
) ChangeError!void {
    assert(message.kind_of(change.text) == .string);

    const range = change.range orelse {
        entry.state.desynced = false;

        return entry.text.text_set(message, change.text);
    };

    const first = entry.text.offset_in(range.start, encoding) orelse return error.RangeOutside;
    const last = entry.text.offset_in(range.end, encoding) orelse return error.RangeOutside;
    if (first > last) return error.RangeBackward;
    return entry.text.splice_text(.between(first, last), message, change.text);
}

fn change_refused(
    session: *Session,
    handle: Handle,
    applied: u32,
    reason: []const u8,
) Sender.Error!void {
    assert(reason.len > 0);

    if (applied > 0) {
        session.documents.get_mut(handle).state.desynced = true;

        log.line("marking a document out of step with its client: {s}", .{reason});

        return;
    }

    log.line("rejecting a change the document cannot take: {s}", .{reason});
    session.analyze(handle);

    try session.publish(handle);
}

pub fn did_close(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.Error!void {
    const params = envelope.params orelse return;

    const uri = lsp.text_document_string(message, params, "uri") orelse {
        log.line("dropping a close without a uri", .{});

        return;
    };

    const handle = session.documents.find_text(message, uri) orelse return;

    session.documents.get_mut(handle).state.diagnostics.clear();

    try session.publish(handle);

    session.documents.close(handle);

    assert(session.documents.find_text(message, uri) == null);
}

pub fn did_save(
    session: *Session,
    message: *const json.Document,
    envelope: *const Envelope,
) Sender.Error!void {
    const params = envelope.params orelse return;

    const uri = lsp.text_document_string(message, params, "uri") orelse {
        log.line("dropping a save without a uri", .{});

        return;
    };

    const handle = session.documents.find_text(message, uri) orelse {
        log.line("dropping a save for a document that is not open", .{});

        return;
    };

    session.analyze(handle);

    if (fixable(session, handle)) try session.fix_on_save(handle);

    try session.publish(handle);
}

fn fixable(session: *Session, handle: Handle) bool {
    if (!session.fixes_on_save(handle)) return false;
    if (!session.apply_edit) return false;

    const fixes = &session.analysis.fixes;
    const document = session.documents.get(handle);

    for (document.state.diagnostics.slice()) |diagnostic| {
        const fix = fixes.fix_of(&diagnostic) orelse continue;
        if (fix.applicability.reaches(.safe)) return true;
    }

    return false;
}

pub fn did_change_configuration(session: *Session) Sender.Error!void {
    assert(session.state == .initialized);

    try session.configuration_pull();
}
