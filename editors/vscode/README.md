# TigerStyle LSP for VS Code

A thin client for the tigerstyle-lsp language server. The server does the work; this
extension finds the executable, names the documents it should see, and watches the
configuration files.

## Requirements

The `tigerstyle-lsp` executable on the PATH, or a `tigerstyle.path` setting that
points at it.

## Settings

Each setting is under the `tigerstyle.` prefix and is documented in `package.json`.
