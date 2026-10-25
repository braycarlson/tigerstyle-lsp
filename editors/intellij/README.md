# TigerStyle LSP for PyCharm

A thin client for the tigerstyle-lsp language server, built against the IntelliJ platform's
LSP API.

## Overview

The plugin starts `tigerstyle-lsp server` over stdio when a file it recognises is opened,
answers the server's request for the `tigerstyle` configuration section, and surfaces the
diagnostics, the hovers, and the quick fixes the server returns. The server does the work;
this plugin finds the executable and carries the settings.

## Requirements

There are three: a JetBrains IDE that ships the LSP API, `tigerstyle-lsp` on the PATH or
named under `Settings | Tools | TigerStyle`, and JDK 21 to build.

The LSP API is absent from the Community editions, so the plugin installs into PyCharm
Professional, IntelliJ IDEA Ultimate, GoLand, RustRover, and WebStorm, and it does not
install into PyCharm Community or IntelliJ IDEA Community. The build targets PyCharm
Professional 2026.2 and the plugin declares `since-build` 262.

## Building

```
./gradlew buildPlugin
```

The zip lands in `build/distributions/`. Install it with
`Settings | Plugins | ⚙ | Install Plugin from Disk...`, then restart the IDE.

| Task | What it does |
|---|---|
| `buildPlugin` | The installable zip. |
| `runIde` | A sandboxed IDE with the plugin loaded. |
| `verifyPlugin` | The JetBrains plugin verifier over the IDEs named in `gradle.properties`. |
| `updatePluginsXml` | The custom-repository descriptor served beside the zip. |

Point the build at a local IDE installation with `-PtigerstyleIdeHome=/path/to/ide` rather
than the version in `gradle.properties`.

## Languages

The plugin starts the server for a file whose extension the server registers a lexer for.

| Language | Extensions |
|---|---|
| Go | `go` |
| JavaScript | `cjs`, `js`, `jsx`, `mjs` |
| Odin | `odin` |
| Python | `py`, `pyi` |
| Rust | `rs` |
| TypeScript | `cts`, `mts`, `ts`, `tsx` |
| Zig | `zig` |

## Settings

The settings live under `Settings | Tools | TigerStyle` and are application-wide, since the
per-project facts belong in the checked-in `tigerstyle.toml`.

| Setting | Description | Default |
|---|---|---|
| Server binary | The executable to run. An empty field looks `tigerstyle-lsp` up on the PATH. | Empty |
| Configuration preference | The way these settings layer against the configuration file hierarchy. | `filesystemFirst` |
| Turn on the rules still in preview | The rules still in preview are turned on. | Off |
| Apply the safe fixes on save | The safe fixes are applied when a file is saved. | Off |
| Extend select | The rules these selectors name run beside the default set, separated by commas. | Empty |
| Ignore | The rules these selectors name are turned off, separated by commas. | Empty |
| Select | The rules these selectors name replace the default set, separated by commas. | Empty |

An empty `Select` field is left out of the payload rather than sent as an empty list. The
server reads the key's presence rather than its contents, so sending an empty `select`
turns off each rule and reports nothing.

The thresholds the server accepts have no field here. Each one is a project-wide fact
rather than a per-developer preference, so `assertionsPerFunctionMin`,
`declarationDistanceMax`, `elseIfChainMax`, `functionLinesMax`, `lineLengthMax`,
`nestingDepthMax`, and `parametersMax` are set in `tigerstyle.toml`.

## How It Works

The IntelliJ LSP client never sends `workspace/didChangeConfiguration` on its own, and the
server pulls its configuration only when that notification arrives, so the plugin sends it
twice over: once when a client reaches the running state, and again when the settings are
applied. A changed binary path restarts the server instead, since the path is read when the
command line is built.

The `Tools | Restart TigerStyle Server` action stops the server and starts it again, which
is the recourse when the binary is replaced underneath a running IDE.
