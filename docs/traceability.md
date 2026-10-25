# Traceability

This page lists each rule in TigerStyle and in NASA's Power of Ten, and the check that encodes it. A
row names the sentence, the rule codes that enforce it, and the reason where no rule can. The
sources are `tigerstyle.md` (TigerBeetle's TigerStyle, the version this repository pins) and
`nasa_p10.md` (Holzmann, "The Power of Ten"). A rule's contract under `docs/rules/` carries the
exact sentence it cites and the carve-outs it makes.

A sentence is *mechanical* when a checker can decide it from the source text without
knowing the author's intent. A sentence that needs intent (which abstraction is
"excellent", which two assertions "pair", which loop is "hot") is recorded as not
mechanical, with the reason, so the gap is a decision rather than an omission.

## NASA P10

| Rule | Text | Encoded by | Not mechanical |
|---|---|---|---|
| 1 | No `goto`. | TS021 (Go). The other languages have no `goto`. | |
| 1 | No `setjmp`/`longjmp`. | TS052 no-panic-recovery: Go `recover()`, Rust `catch_unwind`, Python `except AssertionError`, and JavaScript and TypeScript `process.on("uncaughtException")` and `window.onerror`. The non-local unwinding and its recovery is the analogue in these languages. | |
| 1 | No direct or indirect recursion. | TS001 no-recursion, over the file's call graph with cycle detection. | A cross-file cycle is out of a single file's horizon. |
| 2 | All loops have a fixed upper bound provable statically. | TS006 bounded-loops. | |
| 2 | A non-terminating loop must be provably non-terminating. | TS006: a loop spelled `while (true)`, `loop`, or `for {}` reports unless an assertion names it as the event loop. | |
| 3 | No dynamic memory allocation after initialization. | TS016 no-dynamic-alloc, with the phase read from the file's call graph. TS056 bounded-queues for a queue that grows without limit. | |
| 4 | No function longer than a printed page, about 60 lines. | TS002 function-too-long. The default is TigerStyle's 70, and `function_lines_max` sets 60. | |
| 5 | Assertion density averages two per function. | TS004 assert-density. | A `fmt` inside a Rust trait `impl` is left out of the count: its signature is `core::fmt`'s and its body renders state the type already checked. |
| 5 | Assertions are side-effect free. | TS036 assert-side-effects. | |
| 5 | Assertions are Boolean tests. | It is not enforced as a rule: a truthiness assertion in Python or JavaScript needs the type of the expression. | The check needs type inference. |
| 5 | On failure an explicit recovery action is taken. | TigerStyle overrides it: "The only correct way to handle corrupt code is to crash." TS052 forbids the recovery. | This is a decision. |
| 5 | An assertion a tool can prove never fails or never holds violates the rule. | TS049 trivial-assert. TS004 does not count such an assertion. | |
| 5 | Assertions check pre- and post-conditions, parameters, return values, loop invariants. | TS022 assert-parameters, TS026 assert-return-value. | A loop invariant has no fixed syntax to anchor on. |
| 6 | Data objects declared at the smallest possible scope. | TS005 no-mutable-globals, TS013 no-global-statement, TS011 no-star-import, TS043 declaration-distance with its scope check. | |
| 7 | The return value of a non-void function is checked by each caller, or cast to `(void)` explicitly. | TS017 check-return-value, TS028 no-silent-error-swallow, TS009 no-bare-except, TS010 no-pass-in-except. An explanatory comment does not exempt a discard: the rule's closing sentence puts the checker in the flagging seat and the author in the justifying one, and a `tigerstyle-ignore:` directive is how this tool spells the justification. | |
| 7 | The validity of parameters is checked inside each function. | TS022 assert-parameters. | |
| 8 | The preprocessor is limited to includes and simple macros; no token pasting, variadics, recursive macros; macros expand to complete syntactic units. | TS018 no-complex-macros (Rust). The other languages have no textual macro. | |
| 8 | Conditional compilation is rare and each use is flagged and justified. | TS035 conditional-compilation. | |
| 9 | Pointers are restricted; no more than one level of dereferencing. | TS019 restrict-pointers, TS051 pointer-depth. | |
| 9 | Pointer dereferences are not hidden in macros or typedefs. | TS019 reports a pointer typedef; TS018 reports a macro that hides control flow. | |
| 9 | Function pointers are not permitted. | It is not enforced: TigerStyle's callbacks (`read_sector_callback`, "Callbacks go last") are function pointers. TS019 exempts a function type, and with it the erased context the callback receives, and its contract says so. | This is a decision: TigerStyle over P10. |
| 10 | All code compiles with every warning enabled at the most pedantic setting, with zero warnings. | TS020 no-warning-suppression reports each suppression. | The compiler flags live outside the source file. |
| 10 | Static analyzers pass with zero warnings. | TS020 for the suppressions; TS007 no-dynamic-exec for code no analyzer can see. | The analyzer's own configuration lives outside the source file. |

## TigerStyle

### Safety

| Text | Encoded by | Not mechanical |
|---|---|---|
| Use only very simple, explicit control flow. | TS008 nesting-depth, TS023 no-compound-condition, TS039 else-if-chain, TS021 no-goto. | |
| Do not use recursion. | TS001 no-recursion. | |
| Use only a minimum of excellent abstractions. | | Which abstraction is excellent is a design judgement. |
| Put a limit on everything: all loops and all queues have a fixed upper bound. | TS006 bounded-loops, TS056 bounded-queues. | |
| Where a loop cannot terminate, this must be asserted. | TS006: the assertion must name the loop or `true`. | |
| Use explicitly-sized types like `u32`; avoid `usize`. | TS027 explicit-sized-types. | A value used only to index a slice keeps the width the language's indexing gives it, whether held in a local, a field, a constant, or a return. |
| Assertions detect programmer errors; the only correct way to handle corrupt code is to crash. | TS052 no-panic-recovery. | |
| Assert all function arguments and return values, pre/postconditions and invariants. | TS022 assert-parameters, TS026 assert-return-value, TS004 assert-density. | An invariant has no syntax of its own. A boolean, a function value, and a same-file fieldless enum have no invalid value to assert against. |
| The assertion density must average a minimum of two per function. | TS004 assert-density. | |
| Pair assertions: assert a property on two code paths. | | Which two sites pair is the author's model of the data flow. |
| A blatantly true assertion may document a critical, surprising condition. | TS049 trivial-assert is opt-in for this reason: a literal `true` is the shape the exception names, and the author turns the rule on knowing it. | This is a decision. |
| Split compound assertions: `assert(a); assert(b);` over `assert(a and b)`. | TS024 split-compound-assert. | |
| Use single-line `if` to assert an implication: `if (a) assert(b)`. | TS047 assert-implication. | |
| Assert the relationships of compile-time constants. | | Which constants relate is the design; a checker cannot name the missing assertion. |
| Assert the positive space and the negative space. | TS038 positive-invariants for the form; the pair itself is the author's. | Which negative case is expected is the design. |
| Tests must test exhaustively, with invalid data too. | | A test's inputs are not a property of the code under test. |
| All memory is statically allocated at startup; none is allocated, freed, or reallocated after initialization. | TS016 no-dynamic-alloc. | |
| Declare variables at the smallest possible scope; minimize the variables in scope. | TS043 declaration-distance with the scope check, TS005 no-mutable-globals, TS013 no-global-statement, TS011 no-star-import. | |
| A hard limit of 70 lines per function. | TS002 function-too-long. | |
| Good function shape: few parameters, a simple return type, meaty logic between. | TS003 too-many-parameters, TS041 simple-return-type. | |
| Centralize control flow and state manipulation; push `if`s up and `for`s down; keep leaf functions pure. | TS014 no-nested-functions and TS015 no-lambda keep the pieces named; the split itself is design. | Which function is the parent is the design. |
| Appreciate all compiler warnings at the strictest setting. | TS020 no-warning-suppression, TS050 unused-suppression. | The flags live outside the file. |
| Do not do things directly in reaction to external events; run at your own pace. | | An event loop's shape is an architecture, not a syntax. |
| Split compound conditions into nested `if/else`; split `else if` chains into `else { if }` trees. | TS023 no-compound-condition, TS039 else-if-chain. | |
| Consider whether a single `if` needs a matching `else`. | TS038 positive-invariants reads the branch pair. | "Consider" is not a rule. |
| State invariants positively; `index < length` over `index >= length`. | TS038 positive-invariants. | |
| All errors must be handled. | TS028 no-silent-error-swallow, TS017 check-return-value, TS009 no-bare-except, TS010 no-pass-in-except. | |
| Always motivate, always say why. | TS031 comment-form for the form of a comment. | Whether a comment says why is a reading of prose. |
| Explicitly pass options to library functions at the call site instead of relying on the defaults. | TS053 explicit-options. | |

### Performance

| Text | Encoded by | Not mechanical |
|---|---|---|
| Think about performance from the outset; sketch the four resources. | | A sketch is a design document, not source. |
| Batch; distinguish control plane and data plane; keep the CPU predictable. | | An architecture. |
| Extract hot loops into stand-alone functions with primitive arguments, without `self`. | | Which loop is hot is a measurement, not a syntax. |

### Developer Experience: Naming

| Text | Encoded by | Not mechanical |
|---|---|---|
| Get the nouns and verbs just right. | TS015 no-lambda gives each function a name to get right. | The quality of a name is a judgement. |
| Use `snake_case` for function, variable, and file names. | TS032 snake-case-names, for identifiers and for the file name. | |
| Do not abbreviate variable names, except a primitive integer used as a sort or matrix argument. | TS037 no-abbreviations. | A method name inside a Rust trait `impl` is the trait's, not the author's, and is not read. |
| Use long-form arguments in scripts: `--force`, not `-f`. | | A script's invocation is not in the source the linter reads. |
| Use proper capitalization for acronyms: `VSRState`, not `VsrState`. | TS042 acronym-case. | |
| Put units and qualifiers last, by descending significance: `latency_ms_max`. | TS025 big-endian-names. | |
| Infuse names with meaning: `gpa`, `arena` over `allocator`. | | A judgement. |
| Choose related names of the same length so they line up. | | The set of related names is the author's. |
| Prefix a helper or callback with the name of the function that calls it: `read_sector_callback`. | TS057 callback-name-prefix, for the callback half. | A helper that is not a callback carries no marker to anchor on. |
| Callbacks go last in the parameter list. | TS034 callback-last. | |
| Put important things near the top; `main` goes first. | TS048 main-first. | |
| Order a struct: fields, then types, then methods. | TS044 member-order. | |
| If a nested type is complex, make it top-level. | | "Complex" has no number. |
| When in doubt, sort alphabetically. | | "When in doubt" is not a rule. |
| Do not overload a name with context-dependent meanings. | | A meaning is a reading of the domain. |
| Prefer a noun to an adjective or participle. | | A part of speech is not decidable from an identifier. |
| Use an options struct when arguments can be mixed up; a function taking two `u64` must. | TS033 options-struct. | |
| If an argument can be `null`, name it so the literal `null` reads clearly at the call site. | | Which name makes `null` clear is a judgement. |
| Thread singletons like an allocator positionally, most general first. | | Which dependency is more general is the design. |
| Write descriptive commit messages. | | A commit message is not source. |
| Say why and say how in comments; comments are sentences with a capital and a full stop, or a colon; end-of-line comments may be phrases. | TS031 comment-form. | Whether a comment says why is prose. |

### Developer Experience: Cache Invalidation

| Text | Encoded by | Not mechanical |
|---|---|---|
| Do not duplicate variables or take aliases to them. | TS045 no-alias. | |
| Pass an argument over 16 bytes as `*const` if it is not meant to be copied. | | The size of a type is not in the source of the function that takes it; a Zig struct's size needs the compiler's layout. |
| Construct larger structs in place through an out pointer. | | The same holds: "larger" is a size the linter does not have. |
| Shrink the scope; do not introduce variables before they are needed. | TS043 declaration-distance. | |
| Use simpler return types: `void` over `bool` over `u64` over `?u64` over `!u64`. | TS041 simple-return-type. | |
| Ensure functions run to completion without suspending. | TS054 run-to-completion. | |
| Be on guard for buffer bleeds. | | A partially written buffer is a runtime state. |
| Use newlines to group resource allocation and deallocation. | TS046 allocation-grouping. | |

### Developer Experience: Off-By-One Errors

| Text | Encoded by | Not mechanical |
|---|---|---|
| Treat `index`, `count`, and `size` as distinct types with clear casts between them. | TS025 big-endian-names asks for the qualifier; the cast between them is arithmetic the linter cannot type. | The check needs type inference. |
| Show intent with respect to division: `@divExact`, `@divFloor`, `div_ceil`. | TS040 division-intent. | |

### Style By The Numbers

| Text | Encoded by | Not mechanical |
|---|---|---|
| Run `zig fmt`. | `tigerstyle-lsp format`. | |
| Use 4 spaces of indentation. | TS029 four-space-indent. | |
| Hard limit all line lengths to 100 columns, without exception. | TS012 line-too-long. | |
| To wrap, add a trailing comma and let the formatter do the rest. | TS055 trailing-comma. | |
| Add braces to an `if` unless it fits on a single line. | TS030 if-braces. | |

### Dependencies and Tooling

| Text | Encoded by | Not mechanical |
|---|---|---|
| Zero dependencies apart from the toolchain. | | The manifest (`Cargo.toml`, `build.zig.zon`, `package.json`) is not a source file the linter reads. |
| A small standardized toolbox; write scripts in the project's language. | | A repository's tooling is not source. |
