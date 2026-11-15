fn run(handler: fn (u32) void, name: []const u8) void {
    handler(@intCast(name.len));
}
