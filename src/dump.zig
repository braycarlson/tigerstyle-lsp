const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const classify = @import("classify.zig");
const cli = @import("cli.zig");
const languages = @import("languages.zig");
const Document = @import("document.zig");
const Limits = @import("limits.zig");
const Options = cli.Options;
const Reporter = @import("reporter.zig");
const Token = scylla.Token;
const Tokens = scylla.Tokens;
const log = scylla.log;

classified: scylla.ArrayType(Token),
document: Document,
io: std.Io,
output: Reporter,
path: []const u8,
tokens: Tokens,

const Dump = @This();
pub const Error = std.mem.Allocator.Error || error{Usage};
const read_buffer_bytes: u32 = 1 << 12;

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    limits: *const Limits,
) Error!Dump {
    assert(options.mode == .tokens);
    assert(options.paths.count() == 1);

    const path = options.paths.get(0);
    if (path.len > limits.path_bytes_max) return error.Usage;
    if (languages.of_path(path) == null) return error.Usage;

    var classified: scylla.ArrayType(Token) = try .init(gpa, limits.front.token_count_max);
    errdefer classified.deinit(gpa);

    var document: Document = try .init(gpa, &limits.document());
    errdefer document.deinit(gpa);

    var output: Reporter = try .init(gpa, io, &limits.reporter(), &.{
        .colored = false,
        .format = options.format,
        .output_file = options.output_file,
        .quiet = options.quiet,
        .silent = options.silent,
    });

    errdefer output.deinit(gpa);

    const tokens: Tokens = try .init(gpa, limits.front.token_count_max);

    return .{
        .classified = classified,
        .document = document,
        .io = io,
        .output = output,
        .path = path,
        .tokens = tokens,
    };
}

pub fn deinit(dump: *Dump, gpa: std.mem.Allocator) void {
    assert(dump.path.len > 0);

    dump.classified.deinit(gpa);
    dump.document.deinit(gpa);
    dump.output.deinit(gpa);
    dump.tokens.deinit(gpa);
    dump.* = undefined;
}

pub fn run(dump: *Dump) u8 {
    assert(dump.path.len > 0);

    const language = languages.of_path(dump.path) orelse {
        log.line("the path carries no language tigerstyle-lsp lexes", .{});

        return cli.exit_usage;
    };

    if (!dump.read()) return cli.exit_failure;

    dump.tokens.clear();

    const source = dump.document.text.text_bytes();
    const source_type = languages.source_type(language, dump.path);

    assert(source_type.language == language);

    dump.tokens.lex(source_type, source) catch |err| switch (err) {
        error.Truncated => log.line("the token stream did not fit the reserved buffer", .{}),
    };

    dump.classified.clear();
    dump.classified.push_slice(dump.tokens.slice());
    classify.vocabulary(language, source, dump.classified.slice());

    dump.print();
    dump.output.flush();

    return cli.exit_success;
}

fn read(dump: *Dump) bool {
    var file = scylla.path.open(dump.io, dump.path) catch {
        log.line("the file could not be opened", .{});

        return false;
    };

    defer file.close(dump.io);

    var buffer: [read_buffer_bytes]u8 = undefined;
    var reader = file.reader(dump.io, &buffer);

    dump.document.text.text_read(&reader.interface) catch |err| switch (err) {
        error.LinesExhausted, error.TextExhausted, error.Utf8Invalid => |rejection| {
            const text = Document.rejection_text(rejection);

            log.line("the file was rejected: {s}", .{text});

            return false;
        },
        error.ReadFailed => {
            log.line("the file could not be read", .{});

            return false;
        },
    };

    assert(dump.document.text.line_count() > 0);

    return true;
}

fn print(dump: *Dump) void {
    const tokens = dump.classified.const_slice();

    for (tokens) |token| {
        switch (token.kind) {
            .keyword => |keyword| {
                dump.output.line("{d}:{d} keyword:{s}", .{
                    token.offset,
                    token.length,
                    keyword.name(),
                });
            },
            .punctuation => |punctuation| {
                dump.output.line("{d}:{d} punctuation:{s}", .{
                    token.offset,
                    token.length,
                    punctuation.name(),
                });
            },
            .block_end, .block_start, .comment, .identifier, .newline, .number, .string => {
                dump.output.line("{d}:{d} {s}", .{ token.offset, token.length, token.kind.name() });
            },
        }
    }

    assert(tokens.len == dump.tokens.count());
    assert(tokens.len == dump.classified.count());
}
