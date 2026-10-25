const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const stream = @import("../stream.zig");
const Context = @import("context.zig");
const Frame = @import("frame.zig");
const Parameter = scylla.View.Parameter;
const View = scylla.View;

pub const member_modifier_max: u32 = 4;
pub const type_word = "type";

pub fn header_of(context: *const Context, view: View) ?u32 {
    const header = Frame.header_of(context, view);
    if (header >= context.tokens.len) return null;

    assert(header >= context.lexer_index_from_hint(view.span().offset, view.token_start()));
    assert(context.tokens[header].offset >= view.span().offset);

    return header;
}

pub fn names_a_type(context: *const Context, name: []const u8) bool {
    assert(name.len <= context.source.len);

    if (!context.conventions.title_case_names_types) return false;
    if (name.len == 0) return false;

    const upper = std.ascii.isUpper(name[0]);

    if (upper) assert(!std.ascii.isLower(name[0]));

    return upper;
}

pub fn preceded_by(context: *const Context, parameter: Parameter, word: []const u8) bool {
    assert(word.len > 0);

    const index = context.lexer_index_from(parameter.span.offset);
    const before = @min(index, @as(u32, @intCast(context.tokens.len)));
    const previous = stream.significant_previous(context.tokens, before) orelse return false;

    assert(previous < before);

    return std.mem.startsWith(u8, context.text(context.tokens[previous]), word);
}

pub fn starred(context: *const Context, parameter: Parameter) bool {
    assert(parameter.span.end() <= context.source.len);

    const text = context.span_text(parameter.span);

    assert(text.len == parameter.span.length);

    if (std.mem.startsWith(u8, text, "*")) return true;
    return preceded_by(context, parameter, "*");
}
