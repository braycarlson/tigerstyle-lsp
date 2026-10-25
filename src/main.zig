const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const cli = @import("cli.zig");
const Arguments = scylla.Arguments;
const Clean = @import("clean.zig");
const Dump = @import("dump.zig");
const Formatting = @import("formatting.zig");
const Limits = @import("limits.zig");
const Lint = @import("lint.zig");
const Options = cli.Options;
const Printer = @import("printer.zig");
const Selftest = @import("selftest.zig");
const Server = @import("lsp/server.zig");
const StaticAllocator = scylla.StaticAllocator;
const log = scylla.log;

pub const log_prefix = "tigerstyle-lsp: ";
const Error = Dump.Error || Formatting.Error || Lint.Error || Printer.Error;

const Runtime = union(enum) {
    clean: Clean,
    dump: Dump,
    formatting: Formatting,
    lint: Lint,
    printer: Printer,
    selftest: Selftest,
    server: Server,

    fn init(
        runtime: *Runtime,
        gpa: std.mem.Allocator,
        io: std.Io,
        options: *const Options,
        limits: *const Limits,
        environment: *const std.process.Environ.Map,
    ) Error!void {
        if (Printer.prints(options)) {
            runtime.* = .{ .printer = undefined };

            return runtime.printer.init(gpa, io, options, limits);
        }

        switch (options.mode) {
            .clean => {
                runtime.* = .{ .clean = undefined };

                try runtime.clean.init(gpa, io, options, limits);
            },
            .format => {
                runtime.* = .{ .formatting = undefined };

                try runtime.formatting.init(gpa, io, options, limits, environment);
            },
            .lint => {
                runtime.* = .{ .lint = undefined };

                try runtime.lint.init(gpa, io, options, limits, environment);
            },
            .selftest => |case| runtime.* = .{ .selftest = try .init(gpa, case) },
            .server => {
                runtime.* = .{ .server = undefined };

                try runtime.server.init(gpa, io, options, limits);
            },
            .tokens => runtime.* = .{ .dump = try .init(gpa, io, options, limits) },
            .artifacts, .config, .rule => unreachable,
        }
    }

    fn run(runtime: *Runtime, gpa: std.mem.Allocator) u8 {
        const code = switch (runtime.*) {
            .clean => |*clean| clean.run(),
            .dump => |*dump| dump.run(),
            .formatting => |*formatting| formatting.run(),
            .lint => |*lint| lint.run(),
            .printer => |*printer| printer.run(),
            .selftest => |*selftest| code: {
                selftest.run(gpa);

                break :code cli.exit_success;
            },
            .server => |*server| server.run(),
        };

        assert(code <= cli.exit_usage);

        return code;
    }
};

pub fn main(init: std.process.Init) void {
    const io = init.io;

    var static_allocator: StaticAllocator = .init(std.heap.page_allocator);
    const gpa = static_allocator.allocator();

    StaticAllocator.warm();

    var arguments: Arguments = Arguments.init(gpa, cli.arguments_capacity) catch {
        reserve_failed();
    };

    arguments.load(io, init.minimal.args) catch |err| switch (err) {
        error.ArgfileExhausted,
        error.CommandLineExhausted,
        error.NotText,
        error.TargetExhausted,
        error.TextExhausted,
        error.WordsExhausted,
        => arguments_failed(&arguments),
    };

    var options: Options = Options.init(gpa) catch reserve_failed();

    if (cli.parse(&options, &arguments)) |exit| exit_early(io, exit);
    if (init.environ_map.contains("TIGERSTYLE_NO_CACHE")) options.no_cache = true;

    const limits: *const Limits = if (options.mode == .lint) &Limits.lint else &Limits.default;

    limits.validate();

    var runtime: Runtime = undefined;

    runtime.init(gpa, io, &options, limits, init.environ_map) catch |err| switch (err) {
        error.OptionUnknown => std.process.exit(cli.exit_usage),
        error.OutOfMemory => reserve_failed(),
        error.Usage => exit_early(io, .usage),
        error.VersionUnsupported => std.process.exit(cli.exit_usage),
    };

    if (options.verbose) limits.log_report();

    static_allocator.transition_from_init_to_static();

    if (options.verbose) static_allocator.report_log();

    const code = runtime.run(gpa);

    static_allocator.exit(code);
}

fn exit_early(io: std.Io, exit: cli.Exit) noreturn {
    switch (exit) {
        .completions => |script| stdout_line(io, script),
        .help => stdout_line(io, cli.usage),
        .unexpected => |name| {
            var buffer: [unexpected_bytes_max]u8 = undefined;

            const text = std.mem.print(&buffer, "unexpected argument {s}", .{name}) catch
                "unexpected argument";

            Arguments.usage_exit(&.{ .message = text, .text = cli.usage });
        },
        .usage => stderr_line(io, cli.usage),
        .usage_message => |text| Arguments.usage_exit(&.{ .message = text, .text = cli.usage }),
        .version => stdout_line(io, "tigerstyle-lsp " ++ cli.version),
    }

    std.process.exit(exit.code());
}

fn arguments_failed(arguments: *const Arguments) noreturn {
    const message = arguments.message();

    if (message.len == 0) {
        Arguments.usage_exit(&.{
            .message = "the arguments outgrew the reservation",
            .text = cli.usage,
        });
    }

    Arguments.usage_exit(&.{ .message = message, .text = cli.usage });
}

fn reserve_failed() noreturn {
    log.line("the reservation outgrew the memory the system grants", .{});
    std.process.exit(cli.exit_failure);
}

fn stdout_line(io: std.Io, text: []const u8) void {
    assert(text.len > 0);

    std.Io.File.stdout().writeStreamingAll(io, text) catch return;
    std.Io.File.stdout().writeStreamingAll(io, "\n") catch return;
}

fn stderr_line(io: std.Io, text: []const u8) void {
    assert(text.len > 0);

    std.Io.File.stderr().writeStreamingAll(io, text) catch return;
    std.Io.File.stderr().writeStreamingAll(io, "\n") catch return;
}

const unexpected_bytes_max: u32 = 256;
