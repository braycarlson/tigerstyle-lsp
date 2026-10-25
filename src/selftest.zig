const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

buffer: []u8,
case: Case,

const Selftest = @This();

pub const Case = enum {
    allocate,
    deallocate,
    panic,
    reallocate,
};

const buffer_bytes: u32 = 64;
const panic_message = "selftest panic after freeze";

pub fn init(gpa: std.mem.Allocator, case: Case) std.mem.Allocator.Error!Selftest {
    const buffer = try gpa.alloc(u8, buffer_bytes);

    @memset(buffer, 0);

    assert(buffer.len == buffer_bytes);
    assert(buffer[0] == 0);

    return .{ .buffer = buffer, .case = case };
}

pub fn run(selftest: *Selftest, gpa: std.mem.Allocator) void {
    assert(selftest.buffer.len == buffer_bytes);
    assert(selftest.buffer[buffer_bytes - 1] == 0);

    if (builtin.target.os.tag == .linux) {
        const linux = std.os.linux;

        _ = linux.prctl(@backingInt(linux.PR.SET_DUMPABLE), 0, 0, 0, 0);
    }

    switch (selftest.case) {
        .allocate => {
            const reserved = gpa.alloc(u8, buffer_bytes) catch return;

            std.mem.doNotOptimizeAway(reserved.ptr);
        },
        .deallocate => gpa.free(selftest.buffer),
        .panic => @panic(panic_message),
        .reallocate => {
            const resized = gpa.rawResize(selftest.buffer, .of(u8), buffer_bytes, @returnAddress());

            std.mem.doNotOptimizeAway(resized);
        },
    }
}
