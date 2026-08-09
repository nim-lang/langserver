# CLAUDE.md — vscode_extension

This folder contains `vscode-nim-tortoise`, a VS Code extension for the Nim programming language. It is a fork of [vscode-nim](https://github.com/nim-lang/vscode-nim) refactored to use LSP only (no nimsuggest direct integration), and renamed to avoid conflicts with the original extension.

---

## Build system

The extension is written in **Nim** and compiled to JavaScript using the `js` backend. It is not a TypeScript extension.

| Task | Command |
|------|---------|
| Dev build (with source maps) | `nimble main` |
| Release build | `nimble release` |
| Package as VSIX | `nimble vsix` |
| Install VSIX locally | `nimble install_vsix` |

- Source entry point: `src/vscode_nim_tortoise.nim`
- Output: `out/vscode_nim_tortoise.js` (this is the file VSCode loads as `main`)
- Nim requirement: `>= 2.0.0 & <= 2.1`

To debug the extension in VSCode: press **F5** in the dev workspace — the `.vscode/launch.json` runs `nimble build` then launches an Extension Development Host.

---

## Package identity

| Field | Value |
|-------|-------|
| `name` | `vscode-nim-tortoise` |
| `displayName` | `Nim Tortoise` |
| `publisher` | `YOUR_PUBLISHER_ID` ← fill in before publishing |
| `repository` | `YOUR_REPO_URL` ← fill in before publishing |
| `main` | `./out/vscode_nim_tortoise.js` |

These are in `package.json` at the root of this folder.

---

## Namespace conventions — critical

All VS Code settings, commands, and context keys use the `nimTortoise` prefix. **Do not use the `nim` prefix** — that belongs to the original `vscode-nim` extension and would cause conflicts.

| Type | Prefix | Example |
|------|--------|---------|
| Settings | `nimTortoise.` | `nimTortoise.lsp.path` |
| Commands | `nimTortoise.` | `nimTortoise.run.file` |
| Context keys | `nimTortoise:` | `nimTortoise:generatedFileExists` |
| LSP client ID | `nimTortoise` | first arg to `newLanguageClient(...)` |

When reading VS Code configuration in Nim source code, always use:
```nim
vscode.workspace.getConfiguration("nimTortoise")
```

When registering commands:
```nim
vscode.commands.registerCommand("nimTortoise.myCommand", handler)
```

The `editorLangId == 'nim'` when-clause in `package.json` is **correct as-is** — it refers to the Nim language ID, not our extension, and must not be changed.

---

## Language server (LSP) integration

The LSP binary path is resolved in order:
1. `nimTortoise.lsp.path` setting (user-specified full path)
2. `~/.vscode-nim-tortoise/nimbledeps/bin/nimlangserver` (local install)
3. `nimlangserver` in PATH (global install)

The default binary name `nimlangserver` is intentional — it is the standard Nim language server. Users who want a different binary should set `nimTortoise.lsp.path`.

Transport modes: `stdio` (default) or `socket` — controlled by `nimTortoise.transportMode`.

LSP client is initialised in `src/language_server/language_server.nim`. The client ID shown in VSCode's Output panel is `"nimTortoise"` (label: `"Nim Tortoise Language Server"`).

---

## Key source files

```
src/
├── vscode_nim_tortoise.nim        # Extension entry point — activate/deactivate, command registration
├── language_server/
│   ├── language_server.nim        # LSP startup, socket/stdio transport, inlay hints middleware
│   └── language_configuration.nim # Nim language config (brackets, comments, etc.)
├── commands/
│   ├── compiler_commands.nim      # nim check, build
│   ├── debug_commands.nim         # CodeLLDB debug integration
│   ├── file_commands.nim          # Run file, debug file, open generated file
│   ├── nimble_commands.nim        # Nimble task code lenses and execution
│   ├── project_commands.nim       # nim.project / nim.projectMapping config handling
│   └── test_commands.nim          # Test runner integration (unittest2)
├── state/
│   ├── state_types.nim            # ExtensionState and all shared types
│   └── state.nim                  # State accessors and helpers
├── status_panel/
│   ├── nimStatus.nim              # Status bar item
│   └── nimlspstatuspanel.nim      # Tree view panel for LSP status and notifications
├── tools/
│   ├── nimBinTools.nim            # Binary discovery: getBinPath, getNimExecPath, getAugmentedEnv
│   └── nimUtils.nim               # Shared utilities; holds the global `ext: ExtensionState`
└── platform/
    ├── vscodeApi.nim              # VS Code API bindings
    ├── languageClientApi.nim      # vscode-languageclient bindings
    └── js/                        # Node.js API bindings (fs, path, cp, net, os, etc.)
```

---

## Extension state

`ExtensionState` (defined in `src/state/state_types.nim`) is the single shared state object. It is stored in the global `nimUtils.ext` variable and accessed from most modules via `import ../tools/nimUtils`.

Key fields:
- `config` — the `nimTortoise` workspace configuration object (set at activation; re-read on config change via `configUpdate` in `project_commands.nim`)
- `client` — the active `VscodeLanguageClient`
- `statusProvider` — the tree data provider for the Nim side panel
- `lspExtensionCapabilities` — set of capabilities the connected LSP server advertises

---

## Conflict advisory (vs. original vscode-nim)

These two extensions **cannot be installed simultaneously**. If both are active:

1. **Language ID contributions** (`"nim"`, `"nimble"`) will be merged by VS Code — the last loaded wins for grammar/config. This may cause subtle issues.
2. **Both will attempt to start `nimlangserver`**, resulting in two competing LSP processes for the same files.

Document clearly that this extension replaces, not supplements, the original `vscode-nim`.

---

## Adding a new setting

1. Add to `contributes.configuration.properties` in `package.json` with key `nimTortoise.yourSetting`
2. Read it in Nim source with: `vscode.workspace.getConfiguration("nimTortoise").getStr("yourSetting")`
3. If it should trigger config reload, handle it in `project_commands.nim:configUpdate`

## Adding a new command

1. Add to `contributes.commands` in `package.json` with id `nimTortoise.yourCommand`
2. Register in `src/vscode_nim_tortoise.nim:activate` with `vscode.commands.registerCommand("nimTortoise.yourCommand", handler)`
3. Add menu/keybinding entries to `package.json` if needed

---

## Bundling the language server binary

The extension can ship the `nimlangserver` binary directly so users don't need a separate
install step. VS Code supports **platform-specific extensions** (separate `.vsix` per
OS/arch), which is the recommended approach for native binaries.

### How binary resolution works (current)

`getLspPath` in `src/language_server/language_server.nim` resolves in this order:

1. `nimTortoise.lsp.path` setting (user-specified)
2. `~/.vscode-nim-tortoise/nimbledeps/bin/nimlangserver` (local install)
3. `nimlangserver` in PATH (global install)

### Adding a bundled-binary step

To probe a binary shipped inside the extension, insert step 1.5:

```nim
# In getLspPath, after the lsp.path setting check:
var langserverExec: cstring = "nimlangserver"
if process.platform == "win32":
  langserverExec = "nimlangserver.exe"
let bundledPath = state.ctx.asAbsolutePath(path.join("bin", langserverExec))
if isValidLspPath(bundledPath):
  return (bundledPath, lspPathBundled)
```

`state.ctx` is `VscodeExtensionContext`; `asAbsolutePath` is bound at `vscodeApi.nim:1172`.
Also add `lspPathBundled` to the `LSPInstallPathKind` enum in `state/state_types.nim`.

### File placement

Put the binary at `vscode_extension/bin/nimlangserver`. The `.vscodeignore` does not
exclude `bin/`, so it is automatically included in the `.vsix` package.

### Platform-specific packaging

```bash
# Build and package per platform (run from vscode_extension/):
vsce package --target darwin-arm64
vsce package --target darwin-x64
vsce package --target linux-x64
vsce package --target win32-x64
```

Full implementation details and CI example are in
`langserver/rewrite_analysis/PACKAGING.md`.

---

## Before publishing

- Replace `YOUR_PUBLISHER_ID` in `package.json` (`name`, `author`, `publisher` fields)
- Replace `YOUR_REPO_URL` in `package.json` (`homepage`, `repository.url`, `bugs.url`)
- Ensure `version` in both `package.json` and `vscode_nim_tortoise.nimble` are in sync
