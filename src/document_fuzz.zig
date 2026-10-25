const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const scylla = @import("scylla");
const fuzz = @import("testing/fuzz.zig");
const Buffer = scylla.Buffer;
const Document = @import("document.zig");
const Encoding = scylla.LineIndex.Encoding;
const LineModel = scylla.testing.LineModel;
const Limits = @import("limits.zig");
const PRNG = scylla.testing.PRNG;
const Position = scylla.LineIndex.Point;
const Rejection = scylla.TextDocument.Error;
const StaticAllocator = scylla.StaticAllocator;

const Mirror = struct {
    document: Document,
    encoding: Encoding,
    model: LineModel,
    parsed: json.Document,
    quoted: Buffer,
    storage: json.Storage,

    fn init(mirror: *Mirror, gpa: std.mem.Allocator) !void {
        mirror.document = try .init(gpa, &limits.document());
        errdefer mirror.document.deinit(gpa);

        mirror.storage = try .init(gpa, .{
            .node_count_max = parsed_node_count_max,
            .text_bytes_max = quoted_bytes_max,
        });

        errdefer mirror.storage.deinit(gpa);

        mirror.quoted = try .init(gpa, quoted_bytes_max);
        mirror.encoding = .utf16;
        mirror.model = .empty;

        assert(mirror.document.text.line_count() == 1);
        assert(mirror.model.line_count == 1);
    }

    fn deinit(mirror: *Mirror, gpa: std.mem.Allocator) void {
        assert(mirror.model.line_count >= 1);

        mirror.quoted.deinit(gpa);
        mirror.storage.deinit(gpa);
        mirror.document.deinit(gpa);
        mirror.* = undefined;
    }

    fn replay(mirror: *Mirror, prng: *PRNG) void {
        mirror.reset(prng.enum_uniform(Encoding));

        const record_count = prng.int_inclusive(u32, edit_count_max);
        var insertion_buffer: [insertion_bytes_max]u8 = undefined;

        for (0..record_count) |_| {
            const record = record_generate(prng, &insertion_buffer);

            mirror.apply(&record);
            mirror.agreement_check();
        }

        assert(record_count <= edit_count_max);
    }

    fn reset(mirror: *Mirror, encoding: Encoding) void {
        mirror.encoding = encoding;

        mirror.document.text.encoding_set(encoding);
        mirror.document.text.text_replace("") catch unreachable;
        mirror.model.clear();

        assert(mirror.document.text.line_count() == 1);
        assert(mirror.model.line_count == 1);
    }

    fn apply(mirror: *Mirror, record: *const Record) void {
        if (!std.unicode.utf8ValidateSlice(record.insertion)) return;

        mirror.quoted.clear();

        var sink = mirror.quoted.writer();
        var writer: json.Writer = .init(&sink.interface, quoted_options);

        writer.string(record.insertion) catch unreachable;
        writer.finish();
        mirror.parsed.parse(mirror.storage, mirror.quoted.const_slice()) catch unreachable;

        if (record.kind % 4 == 0) {
            mirror.replaced(record.insertion);
        } else {
            mirror.spliced(record);
        }
    }

    fn replaced(mirror: *Mirror, insertion: []const u8) void {
        const text = mirror.parsed.root();
        const accepted = accepted_of(mirror.document.text.text_set(&mirror.parsed, text));
        const predicted = accepted_of(mirror.model.replaced(insertion));

        assert(accepted == predicted);
    }

    fn spliced(mirror: *Mirror, record: *const Record) void {
        const start = mirror.position_of(record.start_line, record.start_character, record.kind);
        const end = mirror.position_of(record.end_line, record.end_character, record.kind);
        const first = mirror.offsets_agree(start) orelse return;
        const last = mirror.offsets_agree(end) orelse return;
        if (first > last) return;

        const text = mirror.parsed.root();
        const removed: scylla.Span = .between(first, last);
        const text_document = &mirror.document.text;
        const accepted = accepted_of(text_document.splice_text(removed, &mirror.parsed, text));
        const predicted = accepted_of(mirror.model.spliced(removed, record.insertion));

        assert(accepted == predicted);
    }

    fn offsets_agree(mirror: *const Mirror, position: Position) ?u32 {
        const expected = mirror.model.offset_in(position, mirror.encoding);
        const offset = mirror.document.text.offset_in(position, mirror.encoding);

        assert(expected == offset);

        if (offset) |held| assert(held <= mirror.model.length);

        return offset;
    }

    fn position_of(mirror: *const Mirror, line: u8, character: u8, kind: u8) Position {
        if (kind & raw_position_mark != 0) return .{ .character = character, .line = line };

        const bounded = line % mirror.model.line_count;
        const units = mirror.model.units_of(bounded, mirror.encoding);

        assert(bounded < mirror.model.line_count);

        return .{ .character = character % (units + 1), .line = bounded };
    }

    fn agreement_check(mirror: *const Mirror) void {
        const document = &mirror.document.text;
        const model = &mirror.model;

        assert(std.mem.eql(u8, document.text_bytes(), model.bytes()));
        assert(document.line_count() == model.line_count);

        for (0..model.line_count) |index| {
            const line: u32 = @intCast(index);

            assert(document.line_start_offset(line) == model.line_start(line));
            assert(document.line_end_offset(line) == model.line_end(line));
        }

        mirror.positions_check();
    }

    fn positions_check(mirror: *const Mirror) void {
        const model = &mirror.model;

        for (0..model.line_count) |index| {
            const line: u32 = @intCast(index);
            const start = model.line_start(line);
            const end = model.line_end(line);

            assert(start <= end);

            mirror.position_check(start);
            mirror.position_check(model.boundary_at(start + @divFloor(end - start, 2)));
            mirror.position_check(end);
        }
    }

    fn position_check(mirror: *const Mirror, offset: u32) void {
        const document = &mirror.document.text;

        assert(offset <= document.text_count());

        for (std.enums.values(Encoding)) |encoding| {
            const expected = mirror.model.position_in(offset, encoding);
            const position = document.point_in(offset, encoding);

            assert(position.line == expected.line);
            assert(position.character == expected.character);
            assert(document.offset_in(position, encoding).? == offset);
        }
    }
};

const Record = struct {
    end_character: u8,
    end_line: u8,
    insertion: []const u8,
    kind: u8,
    start_character: u8,
    start_line: u8,
};

const edit_count_max = 64;
const event_count_default = 256;
const insertion_bytes_max = std.math.maxInt(u8);
const parsed_node_count_max = 4;
const quoted_bytes_max = insertion_bytes_max * 6 + 2;
const raw_position_mark = 0x80;

const quoted_options: json.Writer.Options = .{
    .indent = 2,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .checked,
};

const insertion_fragments = [_][]const u8{
    "a",
    "word ",
    "\n",
    "\r\n",
    "\r",
    "\t",
    "\u{e9}",
    "\u{20ac}",
    "\u{1F600}",
    "\u{2028}",
    "\"",
    "\\",
    "\x00",
    "\x1f",
    "/",
    "\u{feff}",
};

const limits: Limits = limits: {
    var held = Limits.default;

    held.document_count_max = 2;
    held.file_bytes_max = scylla.testing.model_bytes_max;
    held.file_line_count_max = scylla.testing.model_line_count_max;

    break :limits held;
};

comptime {
    assert(edit_count_max > 0);
    assert(insertion_bytes_max < limits.file_bytes_max);
    assert(raw_position_mark == 0x80);
}

pub fn main(gpa: std.mem.Allocator, _: std.Io, args: fuzz.FuzzArgs) !void {
    var prng = PRNG.init(args.seed);
    const events_max = args.events_max orelse event_count_default;

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    const static = static_allocator.allocator();
    const mirror = try gpa.create(Mirror);
    defer gpa.destroy(mirror);

    try mirror.init(static);
    defer mirror.deinit(static);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (0..events_max) |_| mirror.replay(&prng);
}

fn record_generate(prng: *PRNG, buffer: *[insertion_bytes_max]u8) Record {
    const length = prng.int_inclusive(u32, insertion_bytes_max);

    const insertion = if (length == 0)
        buffer[0..0]
    else
        fuzz.source_generate(prng, &insertion_fragments, buffer[0..length]);

    assert(insertion.len <= length);

    return .{
        .end_character = prng.int(u8),
        .end_line = prng.int(u8),
        .insertion = insertion,
        .kind = prng.int(u8),
        .start_character = prng.int(u8),
        .start_line = prng.int(u8),
    };
}

fn accepted_of(result: Rejection!void) bool {
    if (result) |_| return true else |_| return false;
}

test "document fuzz smoke" {
    try main(std.testing.allocator, std.testing.io, .{ .events_max = 32, .seed = 123 });
}
