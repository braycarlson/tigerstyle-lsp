const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Diagnostics = scylla.Diagnostics;
const Language = scylla.Language;
const TextDocument = scylla.TextDocument;

file: TextDocument,
state: State,

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

pub const LoadError = TextDocument.LoadError;

pub const Entry = struct {
    file: *TextDocument,
    state: *State,

    pub fn view(held: Entry) View {
        return .{ .file = held.file, .state = held.state };
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
    file: *const TextDocument,
    state: *const State,
};

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

    return .{ .file = text, .state = state };
}

pub fn deinit(document: *Document, gpa: std.mem.Allocator) void {
    assert(document.file.line_count() > 0);

    document.state.deinit(gpa);
    document.file.deinit(gpa);
    document.* = undefined;
}

pub fn entry(document: *Document) Entry {
    assert(document.file.line_count() > 0);

    return .{ .file = &document.file, .state = &document.state };
}

pub fn reset(document: *Document) void {
    document.state.reset();
    document.file.reset();

    assert(document.file.uri().len == 0);
    assert(document.file.line_count() == 1);
}

pub fn view(document: *const Document) View {
    assert(document.file.line_count() > 0);

    return .{ .file = &document.file, .state = &document.state };
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

    try document.file.uri_set("file:///a.rs");
    try document.file.text_replace("fn main() {}\n");
    document.state.language = .rust;

    const held = document.view();

    try std.testing.expectEqualStrings("fn main() {}\n", held.file.text_bytes());
    try std.testing.expectEqual(Language.rust, held.state.language.?);

    document.reset();

    const lines: [capacity_test.line_count_max + 1]u8 = @splat('\n');

    try std.testing.expectEqual(null, document.state.language);
    try std.testing.expectEqual(@as(usize, 0), document.file.uri().len);
    try std.testing.expectError(error.LinesExhausted, document.file.text_replace(&lines));
}

test rejection_text {
    try std.testing.expectEqualStrings(reject_lines, rejection_text(error.LinesExhausted));
    try std.testing.expectEqualStrings(reject_size, rejection_text(error.TextExhausted));
    try std.testing.expectEqualStrings(reject_utf8, rejection_text(error.Utf8Invalid));
}

test "a document loads from a path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = false });
    defer temporary.cleanup();

    var root_bytes: [scylla.limits.path_bytes_max]u8 = undefined;
    const root_length = try temporary.dir.realPath(io, &root_bytes);

    try temporary.dir.writeFile(io, .{ .sub_path = "a.rs", .data = "fn a() {}\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "b.rs", .data = "\xff\n" });

    var document: Document = try .init(gpa, &capacity_test);
    defer document.deinit(gpa);

    var path_bytes: [scylla.limits.path_bytes_max]u8 = undefined;
    const root = root_bytes[0..root_length];

    try document.file.uri_set(try std.mem.print(&path_bytes, "{s}/a.rs", .{root}));
    try document.file.load_path(io, document.file.uri());
    try std.testing.expectEqualStrings("fn a() {}\n", document.file.text_bytes());

    document.reset();

    try document.file.uri_set(try std.mem.print(&path_bytes, "{s}/b.rs", .{root}));
    const uri_b = document.file.uri();

    try std.testing.expectError(error.Utf8Invalid, document.file.load_path(io, uri_b));

    document.reset();

    try document.file.uri_set(try std.mem.print(&path_bytes, "{s}/c.rs", .{root}));
    const uri_c = document.file.uri();

    try std.testing.expectError(error.FileUnreadable, document.file.load_path(io, uri_c));
}
