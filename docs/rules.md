# Rules

There are 50 rules, 25 of them on by default. A rule marked opt-in has to be named in `select` before it reports anything: it encodes a preference this linter cannot measure well enough to press on you, or it fires on an idiom the language has no other way to spell. A rule marked preview is still settling: `--preview` turns the preview rules on, and until then a selector that matches nothing but preview rules warns rather than silently selecting nothing.

A rule fires only in the languages listed for it: a language whose grammar cannot express what a rule looks for declares the rule unsupported rather than reporting nothing and leaving you to wonder, and that declaration gates reporting, whatever the configuration enables.

| Code | Name | Default | Severity | What it means | Languages |
|---|---|---|---|---|---|
| TS001 | `no-recursion` | on | error | A function must not call itself, directly or through a cycle | All |
| TS002 | `function-too-long` | on | warning | A function must fit within `function_lines_max` | All |
| TS003 | `too-many-parameters` | on | warning | A signature must not exceed `parameters_max` parameters | All |
| TS004 | `assert-density` | opt-in | info | A function needs at least `assertions_per_function_min` assertions | All |
| TS005 | `no-mutable-globals` | on | error | Module-level state must not be mutable | All |
| TS006 | `bounded-loops` | on | warning | A loop must have a provable upper bound | All |
| TS007 | `no-dynamic-exec` | on | error | Code must not be built and executed at runtime | JavaScript, Python, TypeScript |
| TS008 | `nesting-depth` | on | warning | Control flow must not nest deeper than `nesting_depth_max` | All |
| TS009 | `no-bare-except` | on | warning | A handler must name the exceptions it catches | Python |
| TS010 | `no-pass-in-except` | on | error | A handler must not silently swallow the error | Python |
| TS011 | `no-star-import` | on | warning | An import must name what it brings in | Go, JavaScript, Python, Rust, TypeScript |
| TS012 | `line-too-long` | on | warning | A line must fit within `line_length_max` | All |
| TS013 | `no-global-statement` | on | warning | `global` widens scope; pass values instead | JavaScript, Python, TypeScript |
| TS014 | `no-nested-functions` | opt-in | warning | Functions belong at module scope where they can be tested | JavaScript, Odin, Python, Rust, TypeScript |
| TS015 | `no-lambda` | on | warning | An anonymous function cannot be named or tested; use a named one | Go, JavaScript, Odin, Python, Rust, TypeScript |
| TS016 | `no-dynamic-alloc` | opt-in | warning | Do not allocate on the heap after initialization | All |
| TS017 | `check-return-value` | opt-in | warning | Use a return value or discard it explicitly | All |
| TS018 | `no-complex-macros` | opt-in | warning | A macro must not hide control flow from static analysis | Rust |
| TS019 | `restrict-pointers` | opt-in | error | A raw pointer bypasses the type system | Go, Odin, Python, Rust, Zig |
| TS020 | `no-warning-suppression` | on | warning | Fix the underlying issue rather than silencing the warning | All |
| TS021 | `no-goto` | on | error | Unstructured jumps cannot be analysed; use structured control flow | Go |
| TS022 | `assert-parameters` | opt-in | warning | Assert a function's arguments before operating on them | All |
| TS023 | `no-compound-condition` | on | warning | Split a compound condition into simple conditions using nested branches | All |
| TS024 | `split-compound-assert` | on | warning | Prefer `assert(a); assert(b);` over `assert(a and b);` | All |
| TS025 | `big-endian-names` | on | info | Qualifiers go last: `latency_ms_max`, never `max_latency_ms` | All |
| TS026 | `assert-return-value` | opt-in | info | Assert a function's return value before returning it | All |
| TS027 | `explicit-sized-types` | opt-in | warning | Avoid architecture-dependent `usize`/`isize` where a sized type serves | Go, Odin, Rust, Zig |
| TS028 | `no-silent-error-swallow` | on | error | An error must be handled, not silently discarded | Go, JavaScript, Odin, Rust, TypeScript, Zig |
| TS029 | `four-space-indent` | on | info | Indent by four spaces, not two and not tabs | All |
| TS030 | `if-braces` | on | warning | A multi-line `if` needs braces | JavaScript, Odin, TypeScript, Zig |
| TS031 | `comment-form` | opt-in | info | Write comments as sentences | All |
| TS032 | `snake-case-names` | opt-in | warning | Name functions, variables, and files in `snake_case` | All |
| TS033 | `options-struct` | opt-in | warning | Take an options struct rather than two same-typed parameters | Go, Odin, Python, Rust, TypeScript, Zig |
| TS034 | `callback-last` | opt-in | warning | Put callbacks last in the parameter list | All |
| TS035 | `conditional-compilation` | opt-in | warning | Limit conditional compilation | Go, Odin, Rust, Zig |
| TS036 | `assert-side-effects` | on | error | An assertion must not change the program | All |
| TS037 | `no-abbreviations` | opt-in | info | Do not abbreviate names | All |
| TS038 | `positive-invariants` | on | info | State an invariant positively | All |
| TS039 | `else-if-chain` | on | warning | Split an `else if` chain into a tree | All |
| TS040 | `division-intent` | opt-in | info | Say which way a division rounds | Rust, Zig |
| TS041 | `simple-return-type` | on | warning | Keep the return type simple | Go, Odin, Python, Rust, TypeScript, Zig |
| TS042 | `acronym-case` | opt-in | info | Capitalize an acronym as an acronym | All |
| TS043 | `declaration-distance` | opt-in | info | Declare a variable where it is used | All |
| TS044 | `member-order` | opt-in | info | Order a type's members: fields, then types, then methods | JavaScript, Python, Rust, TypeScript, Zig |
| TS045 | `no-alias` | opt-in | info | Do not alias a variable | All |
| TS046 | `allocation-grouping` | opt-in | info | Set a resource's allocation apart from the code around it | Go, Odin, Zig |
| TS047 | `assert-implication` | opt-in | info | Write an implication as a single-line `if` | All |
| TS048 | `main-first` | opt-in | info | Put `main` first | All |
| TS049 | `trivial-assert` | opt-in | warning | Do not write an assertion that cannot fail | All |
| TS050 | `unused-suppression` | preview | warning | Remove a suppression directive that suppresses nothing | All |
| TS051 | `pointer-depth` | opt-in | warning | A pointer must not point at a pointer | Go, Odin, Rust, Zig |
| TS052 | `no-panic-recovery` | on | error | A panic must not be recovered from; corrupt state has to crash | Go, JavaScript, Python, Rust, TypeScript |
| TS053 | `explicit-options` | opt-in | info | Pass options explicitly rather than relying on the callee's defaults | All |
| TS054 | `run-to-completion` | opt-in | info | A function must not suspend after asserting; run to completion | JavaScript, Python, Rust, TypeScript, Zig |
| TS055 | `trailing-comma` | opt-in | info | A wrapped list ends with a trailing comma | JavaScript, Odin, Python, Rust, TypeScript, Zig |
| TS056 | `bounded-queues` | opt-in | warning | A queue must have a fixed upper bound | Odin, Python, Rust, Zig |
| TS057 | `callback-name-prefix` | opt-in | info | Name a callback after its caller: `read_sector_callback` for `read_sector` | All |
