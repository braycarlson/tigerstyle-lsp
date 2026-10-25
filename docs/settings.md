# Settings

Every key is accepted in `snake_case` and `kebab-case`.

## `assertions_per_function_min`

The assertions a function of more than ten lines is expected to carry.

Default: `2`

```toml
assertions_per_function_min = 2
```

## `cache_dir`

The directory the clean-file cache is written under.

```toml
cache_dir = ".tigerstyle_cache"
```

## `declaration_distance_max`

The statements a binding may sit above its first use.

Default: `5`

```toml
declaration_distance_max = 5
```

## `else_if_chain_max`

The branches an else-if chain may run before it is split into a tree.

Default: `3`

```toml
else_if_chain_max = 3
```

## `exclude`

The glob patterns the walk skips, replacing the defaults.

```toml
exclude = ["vendor/**"]
```

## `extend`

A configuration file this one inherits from, resolved outermost first.

```toml
extend = "../tigerstyle.toml"
```

## `extend_exclude`

The glob patterns the walk skips, beside the defaults.

```toml
extend_exclude = ["corpus/**"]
```

## `extend_fixable`

The rules whose fixes may be applied, beside the ones fixable names.

```toml
extend_fixable = ["TS031"]
```

## `extend_include`

The glob patterns the walk takes in, beside the ones include names.

```toml
extend_include = ["scripts/**"]
```

## `extend_per_file_ignores`

Per-file rule suppressions, beside the ones per_file_ignores names.

```toml
[extend-per-file-ignores]
"tests/*" = ["TS004"]
```

## `extend_safe_fixes`

The rules whose fixes are treated as safe, beside the defaults.

```toml
extend_safe_fixes = ["TS031"]
```

## `extend_select`

The rules turned on beside the default set.

```toml
extend_select = ["TS032", "TS037"]
```

## `extend_unsafe_fixes`

The rules whose fixes are treated as unsafe, beside the defaults.

```toml
extend_unsafe_fixes = ["TS017"]
```

## `fixable`

The rules whose fixes may be applied, replacing the default set.

```toml
fixable = ["TS031"]
```

## `force_exclude`

Apply the exclude patterns to paths named on the command line too.

Default: `false`

```toml
force_exclude = true
```

## `function_lines_max`

The lines a function may span.

Default: `70`

```toml
function_lines_max = 70
```

## `ignore`

The rules turned off, whatever else selects them.

```toml
ignore = ["TS042"]
```

## `include`

The glob patterns the walk takes in, replacing the defaults.

```toml
include = ["src/**"]
```

## `language`

Per-language overrides of the limits and the severities.

```toml
[language.python]
line_length_max = 88
```

## `line_length_max`

The columns a line may span.

Default: `100`

```toml
line_length_max = 100
```

## `nesting_depth_max`

The levels a block may nest inside its function.

Default: `4`

```toml
nesting_depth_max = 4
```

## `parameters_max`

The parameters a function may take.

Default: `7`

```toml
parameters_max = 7
```

## `per_file_ignores`

Per-file rule suppressions, replacing the default set.

```toml
[per-file-ignores]
"tests/*" = ["TS004"]
```

## `preview`

Turn on the rules still in preview.

Default: `false`

```toml
preview = true
```

## `required_version`

The versions of tigerstyle-lsp this configuration supports.

```toml
required_version = ">=0.1"
```

## `respect_gitignore`

Skip the paths the nearest .gitignore names.

Default: `true`

```toml
respect_gitignore = false
```

## `select`

The rules turned on, replacing the default set.

```toml
select = ["ALL"]
```

## `severity`

Per-rule severity overrides.

```toml
[severity]
TS002 = "error"
```

## `unfixable`

The rules whose fixes are never applied.

```toml
unfixable = ["TS017"]
```

