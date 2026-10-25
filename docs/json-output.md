# JSON Output

There are two machine formats for findings. The `--format json` flag writes one array for the
whole run, and `--format json-lines` writes one diagnostic per line with nothing around them.
Both carry the same diagnostic object, so a reader written for one reads the other once the
array is stripped.

## The array

The `--format json` flag writes a single array with one object per diagnostic, indented by two
spaces. A run that finds nothing writes `[]`.

```json
[
  {
    "code": "TS032",
    "column": 4,
    "end_column": 14,
    "end_line": 1,
    "file": "sample.rs",
    "fixable": true,
    "line": 1,
    "message": "the name carries uppercase letters; write it in snake_case",
    "related": [],
    "rule": "snake-case-names",
    "severity": "warning",
    "url": "https://github.com/braycarlson/tigerstyle-lsp/blob/main/docs/rules/TS032.md"
  }
]
```

A path the run could not read is reported on standard error rather than in the array, so an
empty array means the run found nothing in the files it read. The array carries no edits
either: `--diff` prints what `--fix` would write.

## The diagnostic

Each object carries twelve keys, in this order.

| Key | Description |
|---|---|
| `code` | The rule code, such as `TS005`. |
| `column` | The 1-based column the span opens on, counted in characters rather than bytes. |
| `end_column` | The 1-based column one past the last character of the span, so the span is half-open. |
| `end_line` | The 1-based line the span closes on. |
| `file` | The path the finding sits in, as the run named it. |
| `fixable` | A boolean that is `true` when the finding carries a fix of any applicability: a safe one, an unsafe one that needs `--unsafe-fixes`, or a display-only one that is never applied. |
| `line` | The 1-based line the span opens on. |
| `message` | The finding in one sentence, with no closing period. It opens lowercase unless it opens with an identifier taken from the source. |
| `related` | An array of other locations the finding points at. No rule attaches one today, so the array is empty, but a reader should carry an arm for the entries described below. |
| `rule` | The rule's name, such as `no-mutable-globals`. |
| `severity` | The level, one of `error`, `warning`, or `info`. The writer also spells `hint`, which no rule produces today, so a reader should carry an arm for it. |
| `url` | The address of the rule's contract under `docs/rules/`. |

Each entry of `related` carries four keys.

| Key | Description |
|---|---|
| `column` | The 1-based column the location opens on, counted in characters. |
| `file` | The path the location sits in. |
| `line` | The 1-based line the location opens on. |
| `message` | The note the location carries. |

A column counts characters, so `ééé = lambda v: v` reports its lambda at column 7 rather than
at byte 10. The language server negotiates its position encoding with the editor and falls
back to the protocol's UTF-16, so its positions can differ from the columns here.

## JSON Lines

The `--format json-lines` flag writes one diagnostic object per line, in the same shape as
above, with no array around them. A run that finds nothing writes nothing, and a path the run
could not read is reported on standard error, as it is for `--format json`.

```
{"code":"TS032","column":4,"end_column":14,"end_line":1,"file":"sample.rs","fixable":true,"line":1,"message":"the name carries uppercase letters; write it in snake_case","related":[],"rule":"snake-case-names","severity":"warning","url":"https://github.com/braycarlson/tigerstyle-lsp/blob/main/docs/rules/TS032.md"}
```

## Statistics

The `--statistics` flag with `--format json` writes one object per rule that reported rather than
one per diagnostic, and orders the objects by count from highest to lowest and then by code. A run
that finds nothing writes `[]`.

| Key | Description |
|---|---|
| `code` | The rule code. |
| `count` | The diagnostics the rule reported across the run, after the suppression directives and the baseline are applied. |
| `fixable` | A boolean that is `true` when each of those diagnostics is counted in `fixable_count`. |
| `fixable_count` | The diagnostics whose fix `--fix` would apply as the run was invoked: a safe fix, or an unsafe one when `--unsafe-fixes` is given. |
| `name` | The rule's name, the value the diagnostic object calls `rule`. |
| `url` | The address of the rule's contract under `docs/rules/`. |

```json
[
  {
    "code": "TS032",
    "count": 2,
    "fixable": false,
    "fixable_count": 0,
    "name": "snake-case-names",
    "url": "https://github.com/braycarlson/tigerstyle-lsp/blob/main/docs/rules/TS032.md"
  }
]
```

The two `fixable` keys differ: the diagnostic's is `true` for any fix the finding carries, and
the rule's only when `--fix` would apply each of its fixes. Any other format prints the
plain-text table under `--statistics`, with none of the wrapper the format puts around its
findings.

## Other machine formats

The remaining formats are shapes other tools already read, and each is documented by the
tool that consumes it rather than here: `junit`, `github`, `gitlab`, `sarif`, `pylint`,
`rdjson`, and `azure`. `--output-file <path>` writes any format to a file with the colour
stripped.
