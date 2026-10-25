const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const scylla = @import("scylla");
const Document = @import("document.zig");
const Encoding = scylla.LineIndex.Encoding;
const Handle = scylla.Documents.Handle;
const StaticAllocator = scylla.StaticAllocator;

states: []Document.State,
texts: scylla.Documents,

const Documents = @This();

pub const Capacity = struct {
    state: Document.State.Capacity,
    texts: scylla.Documents.Capacity,
};

pub const Error = scylla.Documents.Error;

pub fn init(gpa: std.mem.Allocator, capacity: *const Capacity) std.mem.Allocator.Error!Documents {
    const document_count_max = capacity.texts.document_count_max;

    assert(document_count_max > 0);

    const states = try gpa.alloc(Document.State, document_count_max);
    errdefer gpa.free(states);

    var initialised: u32 = 0;
    errdefer for (states[0..initialised]) |*state| state.deinit(gpa);

    for (states) |*state| {
        state.* = try .init(gpa, capacity.state);
        initialised += 1;
    }

    const texts: scylla.Documents = try .init(gpa, &capacity.texts);

    assert(initialised == document_count_max);
    assert(texts.count() == 0);

    return .{ .states = states, .texts = texts };
}

pub fn deinit(documents: *Documents, gpa: std.mem.Allocator) void {
    assert(documents.texts.count() <= documents.states.len);

    for (documents.states) |*state| state.deinit(gpa);

    gpa.free(documents.states);
    documents.texts.deinit(gpa);
    documents.* = undefined;
}

pub fn close(documents: *Documents, handle: Handle) void {
    const index = documents.texts.index_of(handle);

    documents.states[index].reset();
    documents.texts.close(handle);

    assert(documents.states[index].diagnostics.empty());
    assert(documents.states[index].language == null);
}

pub fn count(documents: *const Documents) u32 {
    const held = documents.texts.count();

    assert(held <= documents.states.len);

    return held;
}

pub fn encoding_set(documents: *Documents, encoding: Encoding) void {
    documents.texts.encoding_set(encoding);

    assert(documents.texts.encoding_get() == encoding);
}

pub fn find_text(documents: *Documents, message: *const json.Document, uri: json.Node) ?Handle {
    const found = documents.texts.find_text(message, uri) orelse return null;

    assert(found.slot < documents.states.len);

    return found;
}

pub fn get(documents: *const Documents, handle: Handle) Document.View {
    const index = documents.texts.index_of(handle);

    assert(index < documents.states.len);

    return .{ .state = &documents.states[index], .text = documents.texts.get(handle) };
}

pub fn get_mut(documents: *Documents, handle: Handle) Document.Entry {
    const index = documents.texts.index_of(handle);

    assert(index < documents.states.len);

    return .{ .state = &documents.states[index], .text = documents.texts.get_mut(handle) };
}

pub fn handles(documents: *const Documents) scylla.Documents.Handles {
    assert(documents.states.len > 0);

    return documents.texts.handles();
}

pub fn open_text(
    documents: *Documents,
    message: *const json.Document,
    uri: json.Node,
) Error!Handle {
    const handle = try documents.texts.open_text(message, uri);

    assert(handle.slot < documents.states.len);

    return handle;
}

const capacity_test: Capacity = .{
    .state = .{ .diagnostic_bytes_max = 1 << 12, .diagnostic_count_max = 64 },
    .texts = .{
        .document_count_max = 2,
        .line_count_max = 8,
        .pool_bytes_max = 2 * 4_096,
        .text_bytes_max = 4_096,
        .text_bytes_min = 4_096,
        .uri_bytes_max = 256,
    },
};

const Uri = struct {
    parsed: json.DocumentType(.{ .node_count_max = 4, .text_bytes_max = 64 }),

    fn init(uri: *Uri, source: []const u8) !void {
        try uri.parsed.parse(source);
    }

    fn opened(uri: *const Uri, documents: *Documents) Error!Handle {
        return documents.open_text(&uri.parsed.document, uri.parsed.root());
    }

    fn found(uri: *const Uri, documents: *Documents) ?Handle {
        return documents.find_text(&uri.parsed.document, uri.parsed.root());
    }
};

test Documents {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();

    var documents: Documents = try .init(gpa, &capacity_test);
    defer documents.deinit(gpa);

    var first: Uri = undefined;

    try first.init("\"file:///a.rs\"");

    var again: Uri = undefined;

    try again.init("\"file:///a.rs\"");

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    const handle = try first.opened(&documents);

    try std.testing.expectEqual(handle, try again.opened(&documents));
    try std.testing.expectEqual(@as(u32, 1), documents.count());
    try std.testing.expectEqual(handle, first.found(&documents).?);
}

test "slots are reused after a close with their state reset" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();

    var documents: Documents = try .init(gpa, &capacity_test);
    defer documents.deinit(gpa);

    var first: Uri = undefined;

    try first.init("\"file:///a.rs\"");

    var second: Uri = undefined;

    try second.init("\"file:///b.rs\"");

    var third: Uri = undefined;

    try third.init("\"file:///c.rs\"");

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    const handle = try first.opened(&documents);

    _ = try second.opened(&documents);

    documents.get_mut(handle).state.language = .rust;
    documents.get_mut(handle).state.desynced = true;

    try std.testing.expectEqual(@as(u32, 2), documents.count());
    try std.testing.expectError(error.DocumentsExhausted, third.opened(&documents));
    try std.testing.expectEqual(scylla.Language.rust, documents.get(handle).state.language.?);
    try std.testing.expect(documents.get(handle).state.desynced);

    documents.close(handle);

    try std.testing.expectEqual(@as(u32, 1), documents.count());

    const reused = try third.opened(&documents);

    try std.testing.expectEqualStrings("file:///c.rs", documents.get(reused).text.uri());
    try std.testing.expectEqual(null, documents.get(reused).state.language);
    try std.testing.expect(!documents.get(reused).state.desynced);
    try std.testing.expectEqual(@as(u32, 2), documents.count());
}
