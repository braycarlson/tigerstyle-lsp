const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("testing/fuzz.zig");
const log = std.log.scoped(.fuzz);

const Fuzzers = .{
    .analysis = @import("analysis_fuzz.zig"),
    .canary = {},
    .document = @import("document_fuzz.zig"),
    .lex = @import("lex_fuzz.zig"),
    .lint = @import("lint_fuzz.zig"),
    .server = @import("lsp/server_fuzz.zig"),
    .smoke = {},
};

const Fuzzer = std.meta.FieldEnum(@TypeOf(Fuzzers));

const Arguments = struct {
    events_max: ?u32,
    fuzzer: Fuzzer,
    seed: ?u64,
};

const arguments_count_max = 8;
const smoke_seed = 123;
const usage = "usage: fuzz [--events-max=<count>] <fuzzer> [seed]";

comptime {
    assert(arguments_count_max >= 3);
    assert(@TypeOf(Fuzzers.canary) == void);
    assert(@TypeOf(Fuzzers.smoke) == void);
}

pub fn main(init: std.process.Init) !void {
    const arguments = try arguments_of(init.gpa, init.minimal.args);

    switch (arguments.fuzzer) {
        .smoke => {
            assert(arguments.seed == null);

            try main_smoke(init.gpa, init.io);
        },
        else => try main_single(init.gpa, init.io, arguments),
    }
}

fn main_smoke(gpa: std.mem.Allocator, io: std.Io) !void {
    inline for (comptime std.enums.values(Fuzzer)) |fuzzer| {
        const events_max: ?u32 = switch (fuzzer) {
            .analysis => 256,
            .canary, .smoke => continue,
            .document => 64,
            .lex => 256,
            .lint => 64,
            .server => 16,
        };

        comptime assert(events_max.? > 0);
        comptime assert(@hasDecl(@field(Fuzzers, @tagName(fuzzer)), "main"));

        try @field(Fuzzers, @tagName(fuzzer)).main(gpa, io, .{
            .events_max = events_max,
            .seed = smoke_seed,
        });
    }

    log.info("smoke done", .{});
}

fn main_single(gpa: std.mem.Allocator, io: std.Io, arguments: Arguments) !void {
    assert(arguments.fuzzer != .smoke);

    const seed = arguments.seed orelse seed_random(io);

    log.info("fuzz seed = {d}", .{seed});

    switch (arguments.fuzzer) {
        .smoke => unreachable,
        .canary => {
            if (seed % 100 == 0) return error.Canary;
        },
        inline else => |fuzzer| {
            comptime assert(@hasDecl(@field(Fuzzers, @tagName(fuzzer)), "main"));

            try @field(Fuzzers, @tagName(fuzzer)).main(gpa, io, .{
                .events_max = arguments.events_max,
                .seed = seed,
            });
        },
    }
}

fn seed_random(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;

    io.random(&bytes);

    const seed = std.mem.readInt(u64, &bytes, .little);

    assert(bytes.len == @sizeOf(u64));

    return seed;
}

fn arguments_of(gpa: std.mem.Allocator, args: std.process.Args) error{Usage}!Arguments {
    var fuzzer: ?Fuzzer = null;
    var seed: ?u64 = null;
    var events_max: ?u32 = null;
    var seen: u32 = 0;
    var held = args.iterateAllocator(gpa) catch return usage_error();
    defer held.deinit();

    _ = held.skip();

    while (held.next()) |argument| {
        seen += 1;

        assert(seen <= arguments_count_max);

        if (std.mem.startsWith(u8, argument, "--events-max=")) {
            const count = argument["--events-max=".len..];

            events_max = std.fmt.parseUnsigned(u32, count, 10) catch return usage_error();

            continue;
        }

        if (fuzzer == null) {
            fuzzer = std.meta.stringToEnum(Fuzzer, argument) orelse return usage_error();
        } else {
            seed = fuzz.parse_seed(argument) catch return usage_error();
        }
    }

    if (seed != null) assert(fuzzer != null);

    return .{
        .events_max = events_max,
        .fuzzer = fuzzer orelse return usage_error(),
        .seed = seed,
    };
}

fn usage_error() error{Usage} {
    std.debug.print("{s}\n", .{usage});

    return error.Usage;
}
