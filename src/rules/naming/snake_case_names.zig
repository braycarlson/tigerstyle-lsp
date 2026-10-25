const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const naming = @import("../naming.zig");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Declaration = Declarations.Declaration;
const Declarations = @import("../declarations.zig");
const Rendered = naming.Rendered;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const words_module = @import("../../words.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use `snake_case` for function, variable, and file names. The underscore " ++
                "is the closest thing we have as programmers to a space, and helps to separate " ++
                "words and encourage descriptive names. We don't use Zig's `CamelCase.zig` " ++
                "style for \"struct\" files to keep the convention simple and consistent.\"",
        },
    },
    .code = "TS032",
    .default_on = false,
    .description = "A function, variable, or file name is snake_case, so casing carries no " ++
        "meaning of its own.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "snake-case-names",
    .severity = .warning,
    .summary = "Name functions, variables, and files in `snake_case`",
    .url = "",
};

const go_test_prefixes = [_][]const u8{ "Benchmark", "Example", "Fuzz", "Test" };
const message = "the name carries uppercase letters; write it in snake_case";

pub fn run(context: *const Context, sink: *Sink) void {
    file_name_check(context, sink);

    var names = naming.names_of(context);

    for (0..names.count_max()) |_| {
        const declaration = names.next() orelse break;

        assert(declaration.token < context.tokens.len);

        if (declaration.kind == .type) continue;
        if (naming.stub_dictates(context, &declaration)) continue;

        name_check(context, sink, &declaration);
    }
}

fn name_check(context: *const Context, sink: *Sink, declaration: *const Declaration) void {
    assert(declaration.kind != .type);
    assert(declaration.token < context.tokens.len);

    const token = context.tokens[declaration.token];
    const name = context.text(token);
    const trimmed = naming.trimmed_underscores(name);
    if (trimmed.len == 0) return;
    if (naming.is_screaming(trimmed)) return;
    if (dictated(context, name)) return;

    if (context.conventions.title_case_names_types) {
        if (std.ascii.isUpper(trimmed[0])) return;
    }

    const exported = context.grammar.capital_marks_export;

    if (exported) {
        if (names_a_go_test(trimmed)) return;
    }

    const capitals: u32 = if (exported) capitals_of(trimmed) else 0;
    if (!holds_an_upper_case_letter(trimmed[capitals..])) return;
    if (naming.aliases_a_foreign_name(context, declaration, name)) return;

    const rendered = snake_case_of(name, capitals) orelse {
        sink.report(token.span(), message);

        return;
    };

    if (naming.rename_fixed(context, sink, token, "Rename to snake_case", rendered.slice())) {
        sink.report_fixed(token.span(), message);
    } else {
        sink.report(token.span(), message);
    }
}

fn dictated(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    if (scan.word_listed(context.conventions.dictated_names, name)) return true;

    for (context.conventions.dictated_name_prefixes) |prefix| {
        assert(prefix.len > 0);

        if (name.len <= prefix.len) continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (std.ascii.isUpper(name[prefix.len])) return true;
    }

    return false;
}

fn capitals_of(trimmed: []const u8) u32 {
    assert(trimmed.len > 0);

    if (!std.ascii.isUpper(trimmed[0])) return 0;

    var words = words_module.word_parts(trimmed);
    const first = words.next().?;
    const capitals = naming.acronym_length(first) orelse 1;

    assert(capitals >= 1);
    assert(capitals <= first.len);

    return capitals;
}

fn names_a_go_test(trimmed: []const u8) bool {
    assert(trimmed.len > 0);

    for (go_test_prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return true;
    }

    return false;
}

fn holds_an_upper_case_letter(text: []const u8) bool {
    for (text) |byte| {
        if (std.ascii.isUpper(byte)) return true;
    }

    return false;
}

fn file_name_check(context: *const Context, sink: *Sink) void {
    const file = scylla.path.file_name(context.path);

    assert(file.len <= context.path.len);

    if (!file_name_offends(file)) return;

    sink.report_formatted(
        Span.empty,
        "the file name {s} carries uppercase letters or hyphens; name the file in snake_case",
        .{scan.utf8_or(file, "the file")},
    );
}

fn file_name_offends(file: []const u8) bool {
    const stem_end = std.mem.findScalar(u8, file, '.') orelse file.len;
    const stem = file[0..stem_end];

    assert(stem.len <= file.len);
    assert(std.mem.findScalar(u8, stem, '.') == null);

    if (stem.len == 0) return false;
    if (naming.is_screaming(stem)) return false;

    for (stem) |byte| {
        if (std.ascii.isUpper(byte)) return true;
        if (byte == '-') return true;
    }

    return false;
}

fn snake_case_of(name: []const u8, capitals: u32) ?Rendered {
    if (name.len > naming.name_bytes_max) return null;

    const trimmed = naming.trimmed_underscores(name);
    const leading: u32 = @intCast(std.mem.findNone(u8, name, "_") orelse name.len);
    const trailing: u32 = @intCast(name.len - trimmed.len - leading);

    var rendered: Rendered = .empty;

    for (0..leading) |_| rendered.append('_');

    var words = words_module.word_parts(trimmed);

    for (0..trimmed.len) |_| {
        const word = words.next() orelse break;

        word_write(&rendered, word, capitals, leading);
    }

    for (0..trailing) |_| rendered.append('_');

    assert(rendered.length >= leading + trailing);
    assert(rendered.length <= naming.rendered_bytes_max);

    return rendered;
}

fn word_write(rendered: *Rendered, word: []const u8, capitals: u32, leading: u32) void {
    assert(word.len > 0);
    assert(rendered.length >= leading);

    if (rendered.length > leading) rendered.append('_');

    for (word) |byte| {
        const opens = rendered.length < leading + capitals;

        rendered.append(if (opens) std.ascii.toUpper(byte) else std.ascii.toLower(byte));
    }

    assert(rendered.length > leading);
}

fn expect_count(language: scylla.Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a name a python stub declares is the runtime's spelling" {
    try testing.expect_stub_names(@This(), testing.stub_source, &.{"tagOrId"});

    var module = try testing.analyze(@This(), .python, testing.stub_source);
    defer module.deinit();

    if (module.count() != 5) module.print();

    try std.testing.expectEqual(@as(u32, 5), module.count());
}

test "a self named composite literal is not an alias" {
    const source = "package main\n\ntype heightSpec struct {\n\tindex int\n}\n\n" ++
        "func parse(index int) heightSpec {\n\theightSpec := heightSpec{index: index}\n" ++
        "\treturn heightSpec\n}\n";

    try expect_count(.go, source, 1);
}

test "a tuple pattern constructor declares nothing" {
    const source = "fn run(first: Option<u32>, second: Option<u32>) {\n" ++
        "    let (Some(held), Some(other)) = (first, second) else {\n        return;\n    };\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a go declaration group still declares its names" {
    try expect_count(.go, "package main\n\nvar (\n\tmaxRetries = 3\n\tminDelay = 1\n)\n", 2);
}

test "a raw pointer prefix declares nothing" {
    const source = "fn read(slice: &[u8]) -> &Held {\n" ++
        "    unsafe { &*(slice as *const [u8] as *const Held) }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a mutable raw pointer prefix declares nothing" {
    const source = "fn write(slice: *mut Held) {\n    let held = slice as *mut Held;\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a constant declaration is still a declaration" {
    try expect_count(.rust, "const MaxRetries: u32 = 3;\n", 1);
}

test "a camel case name renames to snake case" {
    try testing.expect_fixed(
        @This(),
        .rust,
        "fn readSector() {\n}\n",
        .unsafe,
        "fn read_sector() {\n}\n",
    );
}

test "a rename keeps the leading underscore" {
    try testing.expect_fixed(
        @This(),
        .python,
        "def f():\n    _fooBar = 1\n",
        .unsafe,
        "def f():\n    _foo_bar = 1\n",
    );
}

test "a run of capitals splits before the next word" {
    const rendered = snake_case_of("HTTPSClient", 0) orelse return error.TestExpectedRename;

    try std.testing.expectEqualStrings("https_client", rendered.slice());
}

test "a name past the bound carries no rename" {
    const name: [naming.name_bytes_max + 1]u8 = @splat('A');

    try std.testing.expectEqual(null, snake_case_of(&name, 0));
}

test "a destructuring pattern declares no name" {
    try testing.expect_quiet(@This(), .rust, "fn f() {\n    let Input { input } = load();\n}\n");
}

test "a zig title case binding is a type" {
    const source = "const Self" ++ " = @This();\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a go export peels its first character" {
    try expect_count(.go, "package main\n\nfunc ReadSector() {\n}\n", 1);
    try testing.expect_quiet(@This(), .go, "package main\n\nfunc Read_sector() {\n}\n");
}

fn expect_rendered(name: []const u8, expected: []const u8) !void {
    assert(name.len > 0);
    assert(expected.len > 0);

    const rendered = snake_case_of(name, capitals_of(name)) orelse return error.TestExpectedRename;

    try std.testing.expectEqualStrings(expected, rendered.slice());
}

test "a go export keeps its capital in the rename" {
    const source = "package main\n\nfunc ReadSector() {\n}\n";

    try expect_rendered("ReadSector", "Read_sector");
    try testing.expect_fixed(@This(), .go, source, .unsafe, source);
    try testing.expect_quiet(@This(), .go, "package main\n\nfunc Read_sector() {\n}\n");
}

test "a go export keeps its leading acronym in capitals" {
    const source = "package main\n\ntype State struct {\n\tTLSUnique []byte\n}\n";
    const renamed = "package main\n\ntype State struct {\n\tTLS_unique []byte\n}\n";

    try expect_rendered("TLSUnique", "TLS_unique");
    try testing.expect_fixed(@This(), .go, source, .unsafe, source);
    try testing.expect_quiet(@This(), .go, renamed);
    try testing.expect_quiet(@import("acronym_case.zig"), .go, renamed);
}

test "a go export keeps a versioned acronym whole" {
    const renamed = "package main\n\nfunc IPv4_address() {\n}\n";

    try expect_rendered("IPv4Address", "IPv4_address");
    try testing.expect_quiet(@This(), .go, renamed);
    try testing.expect_quiet(@import("acronym_case.zig"), .go, renamed);
    try testing.expect_quiet(@This(), .go, "package main\n\nfunc IPv4() {\n}\n");
}

test "a rename reaches every use or is not offered" {
    const local = "fn f() {\n    let readSector = 1;\n    use(readSector);\n}\n";
    const renamed = "fn f() {\n    let read_sector = 1;\n    use(read_sector);\n}\n";
    const go_local = "package main\n\nfunc work() {\n\treadSector := 1\n\tuse(readSector)\n}\n";

    const taken = "fn f() {\n    let readSector = 1;\n    let read_sector = 2;\n" ++
        "    use(readSector, read_sector);\n}\n";

    try testing.expect_fixed(@This(), .rust, local, .unsafe, renamed);

    try testing.expect_fixed(
        @This(),
        .go,
        go_local,
        .unsafe,
        "package main\n\nfunc work() {\n\tread_sector := 1\n\tuse(read_sector)\n}\n",
    );

    try testing.expect_fixed(@This(), .rust, taken, .unsafe, taken);
}

fn expect_renamed_everywhere(
    language: scylla.Language,
    source: []const u8,
    name: []const u8,
    rendered: []const u8,
) !void {
    assert(name.len > 0);
    assert(rendered.len > 0);

    const gpa = std.testing.allocator;
    const expected = try std.mem.replaceOwned(u8, gpa, source, name, rendered);
    defer gpa.free(expected);

    try std.testing.expect(std.mem.count(u8, source, name) > 1);
    try std.testing.expectEqual(0, std.mem.count(u8, expected, name));
    try testing.expect_fixed(@This(), language, source, .unsafe, expected);
}

test "a rename reaches a use above the declaration" {
    const above = "pub fn eql(a: u32, b: u32) bool {\n    return eqlNoLock(a, b);\n}\n\n" ++
        "fn eqlNoLock(a: u32, b: u32) bool {\n    return a == b;\n}\n";

    const interleaved = "fn first() u32 {\n    return readSector();\n}\n\n" ++
        "fn readSector() u32 {\n    return 1;\n}\n\n" ++
        "pub fn last() u32 {\n    return readSector() + first();\n}\n";

    try expect_renamed_everywhere(.zig, above, "eqlNoLock", "eql_no_lock");
    try expect_renamed_everywhere(.zig, interleaved, "readSector", "read_sector");
}

test "a rename reaches the test that names the declaration" {
    const source = "fn detectShell() u32 {\n    return 1;\n}\n\n" ++
        "test detectShell {\n    _ = detectShell();\n}\n";

    try expect_renamed_everywhere(.zig, source, "detectShell", "detect_shell");
}

test "a test name two declarations share carries no rename" {
    const source = "fn readSector() u32 {\n    return 1;\n}\n\n" ++
        "const Disk = struct {\n    fn readSector() u32 {\n        return 2;\n    }\n\n" ++
        "    test readSector {\n        _ = readSector();\n    }\n};\n";

    try expect_count(.zig, source, 2);
    try testing.expect_fixed(@This(), .zig, source, .unsafe, source);
}

test "a member of a tagged union carries no rename" {
    const source = "pub const Key = union(enum) {\n    one: u32,\n\n" ++
        "    fn eqlNoLock(a: Key, b: Key) bool {\n        return a.one == b.one;\n    }\n};\n\n" ++
        "pub fn compare(a: Key, b: Key) bool {\n    return a.eqlNoLock(b);\n}\n";

    try expect_count(.zig, source, 1);
    try testing.expect_fixed(@This(), .zig, source, .unsafe, source);
}

test "a digit run closes a word in the rename" {
    const versioned = "fn parseIPv4Address() {\n}\n";
    const encoded = "fn base64Encode() {\n}\n";

    try testing.expect_fixed(@This(), .rust, versioned, .unsafe, "fn parse_ipv4_address() {\n}\n");
    try testing.expect_fixed(@This(), .rust, encoded, .unsafe, "fn base64_encode() {\n}\n");
}

test "a camel case function is reported" {
    try expect_count(.rust, "fn readSector() {\n}\n", 1);
}

test "a screaming constant is quiet" {
    try testing.expect_quiet(@This(), .rust, "const SECTOR_BYTES_MAX: u32 = 4096;\n");
}

test "a snake case function is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn read_sector() {\n}\n");
}

test "a javascript member is a name" {
    const source = "class A {\n    methodName() {}\n    get valueName() { return 1; }\n" ++
        "    static staticName = 1;\n    fieldName = 2;\n}\n" ++
        "const held = { keyName: 1, methodShort() {} };\n";

    try expect_count(.javascript, source, 6);
}

test "a hook a test framework calls by its spelling is dictated" {
    const python = "class Visitor:\n    def setUp(self):\n        self.ready = True\n\n" ++
        "    def setUpTestData(cls):\n        cls.ready = True\n\n" ++
        "    def visit_ImportFrom(self, node):\n        self.node = node\n\n" ++
        "    def assertChildNodes(self, node):\n        self.node = node\n";

    const javascript = "QUnit.module(\"admin\", {\n    beforeEach() {\n" ++
        "        setup();\n    },\n    afterBuild() {\n        setup();\n    },\n});\n";

    try expect_count(.python, python, 1);
    try expect_count(.javascript, javascript, 1);
}

test "a python attribute is a name" {
    const source = "class Held:\n    def __init__(self, value):\n        self.attrName = value\n";

    try expect_count(.python, source, 1);
}

test "a field is a variable name" {
    try expect_count(.go, "package main\n\ntype Held struct {\n\tMaxSize int\n}\n", 1);
}

test "a file name is snake case unless it screams" {
    try std.testing.expect(file_name_offends("VsrState.zig"));
    try std.testing.expect(file_name_offends("camelCase.py"));
    try std.testing.expect(file_name_offends("my-module.js"));
    try std.testing.expect(!file_name_offends("vsr_state.zig"));
    try std.testing.expect(!file_name_offends("__init__.py"));
    try std.testing.expect(!file_name_offends("TS032.fire.rs"));
    try std.testing.expect(!file_name_offends(""));
}
