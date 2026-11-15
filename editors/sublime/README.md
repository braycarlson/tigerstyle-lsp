# TigerStyle LSP for Sublime Text

A thin client for the tigerstyle-lsp language server, packaged as Sublime's LSP package
expects.

## Overview

The `LSP-tigerstyle` directory is a Sublime package. The LSP package discovers it, reads
the command and the selector from `LSP-tigerstyle.sublime-settings`, and speaks to
`tigerstyle-lsp server` over stdio. The server does the work; this package names the
documents it should see and carries the defaults.

## Requirements

There are two: the [LSP](https://packagecontrol.io/packages/LSP) package, and
`tigerstyle-lsp` on the PATH.

## Installation

Copy `LSP-tigerstyle` into Sublime's `Packages` directory, then restart Sublime.

| Platform | Directory |
|---|---|
| Linux | `~/.config/sublime-text/Packages/` |
| macOS | `~/Library/Application Support/Sublime Text/Packages/` |
| Windows | `%APPDATA%\Sublime Text\Packages\` |

The package appears as a server named `tigerstyle` under `LSP: Troubleshoot Server`.

## Languages

The selector names one scope per language the server registers a lexer for.

| Language | Scope | Extensions |
|---|---|---|
| Go | `source.go` | `go` |
| JavaScript | `source.js`, `source.jsx` | `cjs`, `js`, `jsx`, `mjs` |
| Odin | `source.odin` | `odin` |
| Python | `source.python` | `py`, `pyi` |
| Rust | `source.rust` | `rs` |
| TypeScript | `source.ts`, `source.tsx` | `cts`, `mts`, `ts`, `tsx` |
| Zig | `source.zig` | `zig` |

The server routes on the file extension rather than the language identifier, so a scope
that reaches it with an unregistered extension is ignored.

## Settings

Each key under `settings` is answered when the server asks for the `tigerstyle` section,
which it does on `workspace/didChangeConfiguration`. Open them with
`Preferences: LSP-tigerstyle Settings`.

| Setting | Description | Default |
|---|---|---|
| `tigerstyle.configurationPreference` | The way the editor settings layer against the configuration file hierarchy. The value is one of `filesystemFirst`, `editorFirst`, or `editorOnly`. | `filesystemFirst` |
| `tigerstyle.disabledRules` | An alias for `ignore`. | `[]` |
| `tigerstyle.enabledRules` | An alias for `extendSelect`. | `[]` |
| `tigerstyle.extendSelect` | The rules these selectors name run beside the default set. | `[]` |
| `tigerstyle.fixOnSave` | The safe fixes are applied when a file is saved. | `false` |
| `tigerstyle.ignore` | The rules these selectors name are turned off. | `[]` |
| `tigerstyle.preview` | The rules still in preview are turned on. | `false` |

The thresholds the server accepts are `assertionsPerFunctionMin`,
`declarationDistanceMax`, `elseIfChainMax`, `functionLinesMax`, `lineLengthMax`,
`nestingDepthMax`, and `parametersMax`. Each is a positive integer under the same
`tigerstyle.` prefix, and each is left out of the defaults so the checked-in
`tigerstyle.toml` governs.

## The select Key

There is one key deliberately absent from the defaults. The server treats `select` as a
replacement for the default rule set, and it reads the key's presence rather than its
contents, so sending `"tigerstyle.select": []` turns off each rule and reports nothing.
Add the key only with the rules it should name.

## Running Beside Another Server

Sublime attaches each client whose selector matches, so tigerstyle-lsp runs alongside
rust-analyzer, gopls, ruff, and the rest, and the diagnostics merge in the panel. The
severity floor is `show_diagnostics_severity_level` in `LSP.sublime-settings`.

## One Client Instead of the Package

A single entry under `clients` in `LSP.sublime-settings` reaches the same server without
installing the package. The package is the better home for a machine that wants the
settings schema and the `Preferences` entry.

```json
{
    "clients": {
        "tigerstyle-lsp": {
            "enabled": true,
            "command": ["tigerstyle-lsp", "server"],
            "selector": "source.go | source.js | source.jsx | source.odin | source.python | source.rust | source.ts | source.tsx | source.zig",
            "settings": {
                "tigerstyle.configurationPreference": "filesystemFirst",
                "tigerstyle.fixOnSave": false,
                "tigerstyle.preview": false
            }
        }
    }
}
```
