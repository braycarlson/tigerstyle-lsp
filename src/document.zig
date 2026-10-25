const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Diagnostics = scylla.Diagnostics;
const Language = scylla.Language;
const TextDocument = scylla.TextDocument;
const log = scylla.log;

state: State,
text: TextDocument,

const Document = @This();

pub const Capacity = struct {
    diagnostic_bytes_max: u32,
    diagnostic_count_max: u32,
    line_count_max: u32,
    text_bytes_max: u32,
    uri_bytes_max: u32,

    pub fn state(capacity: *const Capacity) State.Capacity {
        assert(capacity.diagnostic_count_max > 0);
        assert(capacity.diagnostic_bytes_max > 0);

        return .{
            .diagnostic_bytes_max = capacity.diagnostic_bytes_max,
            .diagnostic_count_max = capacity.diagnostic_count_max,
        };
    }
};

pub const LoadError = TextDocument.Error || error{FileUnreadable};

pub const Entry = struct {
    state: *State,
    text: *TextDocument,

    pub fn view(held: Entry) View {
        return .{ .state = held.state, .text = held.text };
    }
};

pub const State = struct {
    desynced: bool,
    diagnostics: Diagnostics,
    language: ?Language,

    pub const Capacity = struct {
        diagnostic_bytes_max: u32,
        diagnostic_count_max: u32,
    };

    pub fn init(gpa: std.mem.Allocator, capacity: State.Capacity) std.mem.Allocator.Error!State {
        assert(capacity.diagnostic_count_max > 0);
        assert(capacity.diagnostic_bytes_max > 0);

        const diagnostics: Diagnostics = try .init(gpa, .{
            .related_count_max = capacity.diagnostic_count_max,
            .row_count_max = capacity.diagnostic_count_max,
            .text_bytes_max = capacity.diagnostic_bytes_max,
        });

        assert(diagnostics.empty());

        return .{ .desynced = false, .diagnostics = diagnostics, .language = null };
    }

    pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
        assert(state.diagnostics.count() <= state.diagnostics.capacity());

        state.diagnostics.deinit(gpa);
        state.* = undefined;
    }

    pub fn reset(state: *State) void {
        state.desynced = false;

        state.diagnostics.clear();
        state.language = null;

        assert(state.diagnostics.empty());
        assert(state.language == null);
    }
};

pub const View = struct {
    state: *const State,
    text: *const TextDocument,
};

const read_buffer_bytes: u32 = 1 << 12;
const reject_lines = "the file has more lines than tigerstyle-lsp indexes";
const reject_size = "the file is larger than tigerstyle-lsp analyzes";
const reject_utf8 = "the file is not valid UTF-8";

pub fn init(gpa: std.mem.Allocator, capacity: *const Capacity) std.mem.Allocator.Error!Document {
    assert(capacity.text_bytes_max > 0);
    assert(capacity.uri_bytes_max > 0);

    var state: State = try .init(gpa, capacity.state());
    errdefer state.deinit(gpa);

    const text: TextDocument = try .init(gpa, .{
        .line_count_max = capacity.line_count_max,
        .text_bytes_max = capacity.text_bytes_max,
        .uri_bytes_max = capacity.uri_bytes_max,
    });

    assert(text.line_count() == 1);

    return .{ .state = state, .text = text };
}

pub fn deinit(document: *Document, gpa: std.mem.Allocator) void {
    assert(document.text.line_count() > 0);

    document.state.deinit(gpa);
    document.text.deinit(gpa);
    document.* = undefined;
}

pub fn entry(document: *Document) Entry {
    assert(document.text.line_count() > 0);

    return .{ .state = &document.state, .text = &document.text };
}

pub fn reset(document: *Document) void {
    document.state.reset();
    document.text.reset();

    assert(document.text.uri().len == 0);
    assert(document.text.line_count() == 1);
}

pub fn text_load(document: *Document, io: std.Io, path: []const u8) LoadError!void {
    assert(path.len > 0);
    assert(std.mem.eql(u8, document.text.uri(), path));

    var opened = scylla.path.open(io, path) catch {
        log.line("skipping a path that could not be opened", .{});

        return error.FileUnreadable;
    };

    defer opened.close(io);

    var buffer: [read_buffer_bytes]u8 = undefined;
    var reader = opened.reader(io, &buffer);

    return document.text_read(&reader.interface, "skipping a path that could not be read");
}

pub fn text_load_stdin(document: *Document, io: std.Io) LoadError!void {
    assert(document.text.uri().len > 0);

    var buffer: [read_buffer_bytes]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(io, &buffer);

    return document.text_read(&input.interface, "standard input could not be read");
}

fn text_read(document: *Document, reader: *std.Io.Reader, unreadable: []const u8) LoadError!void {
    assert(unreadable.len > 0);
    assert(document.text.uri().len > 0);

    document.text.text_read(reader) catch |err| switch (err) {
        error.LinesExhausted, error.TextExhausted, error.Utf8Invalid => |rejection| {
            return rejection;
        },
        error.ReadFailed => {
            log.line("{s}", .{unreadable});

            return error.FileUnreadable;
        },
    };
}

pub fn view(document: *const Document) View {
    assert(document.text.line_count() > 0);

    return .{ .state = &document.state, .text = &document.text };
}

pub fn rejection_text(rejection: TextDocument.Error) []const u8 {
    const text: []const u8 = switch (rejection) {
        error.LinesExhausted => reject_lines,
        error.TextExhausted => reject_size,
        error.Utf8Invalid => reject_utf8,
    };

    assert(text.len > 0);
    assert(std.mem.startsWith(u8, text, "the file "));

    return text;
}

const capacity_test: Capacity = .{
    .diagnostic_bytes_max = 1 << 12,
    .diagnostic_count_max = 64,
    .line_count_max = 8,
    .text_bytes_max = 4_096,
    .uri_bytes_max = 256,
};

test Document {
    const gpa = std.testing.allocator;

    var document: Document = try .init(gpa, &capacity_test);
    defer document.deinit(gpa);

    try document.text.uri_set("file:///a.rs");
    try document.text.text_replace("fn main() {}\n");
    document.state.language = .rust;

    const held = document.view();

    try std.testing.expectEqualStrings("fn main() {}\n", held.text.text_bytes());
    try std.testing.expectEqual(Language.rust, held.state.language.?);

    document.reset();

    const lines: [capacity_test.line_count_max + 1]u8 = @splat('\n');

    try std.testing.expectEqual(null, document.state.language);
    try std.testing.expectEqual(@as(usize, 0), document.text.uri().len);
    try std.testing.expectError(error.LinesExhausted, document.text.text_replace(&lines));
}

test rejection_text {
    try std.testing.expectEqualStrings(reject_lines, rejection_text(error.LinesExhausted));
    try std.testing.expectEqualStrings(reject_size, rejection_text(error.TextExhausted));
    try std.testing.expectEqualStrings(reject_utf8, rejection_text(error.Utf8Invalid));
}

test text_load {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_bytes: [scylla.limits.path_bytes_max]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_bytes);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.rs", .data = "fn a() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.rs", .data = "\xff\n" });

    var document: Document = try .init(gpa, &capacity_test);
    defer document.deinit(gpa);

    var path_bytes: [scylla.limits.path_bytes_max]u8 = undefined;
    const root = root_bytes[0..root_length];

    try document.text.uri_set(try std.mem.print(&path_bytes, "{s}/a.rs", .{root}));
    try document.text_load(io, document.text.uri());
    try std.testing.expectEqualStrings("fn a() {}\n", document.text.text_bytes());

    document.reset();

    try document.text.uri_set(try std.mem.print(&path_bytes, "{s}/b.rs", .{root}));
    try std.testing.expectError(error.Utf8Invalid, document.text_load(io, document.text.uri()));

    document.reset();

    try document.text.uri_set(try std.mem.print(&path_bytes, "{s}/c.rs", .{root}));
    try std.testing.expectError(error.FileUnreadable, document.text_load(io, document.text.uri()));
}
