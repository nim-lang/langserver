# Nim Tortoise Language Server Extension

## "Slow and steady wins the race"

A VS Code extension for the Nim programming language that prioritises correctness over speed.

This is the VS Code extension for the [Nim Tortoise Language Server](../langserver/README.md). It is a fork of [`vscode-nim`](https://github.com/nim-lang/vscode-nim) refactored to be **LSP-only** — direct nimsuggest integration has been removed, leaving a thin wrapper around the language server. This makes the extension simpler and more reliable, as all language intelligence lives in one well-tested place.

> **Note**: This extension **replaces** the original `vscode-nim` — the two cannot be installed simultaneously. If both are active, they will each try to start a language server for the same files.

---

## What's New in This Fork

- **LSP-only**: all language features (hover, completion, go-to-definition, inlay hints, diagnostics, macro expansion, ARC expansion, formatting) are provided by the language server. The extension manages the server lifecycle and communicates via the Language Server Protocol.
- **`nimTortoise.` prefix**: all settings and commands use the `nimTortoise.` namespace to avoid conflicts with the original extension.
- **Inlay hints**: type hints, parameter hints, and exception hints powered by nimsuggest.
- **Macro and ARC expansion**: expand macro calls and ARC-transformed procs directly on hover.
- **`nph` formatting**: format-on-save using `nph` when installed.
- **Improved nimble integration**: automatic `nimble setup` detection, correct project-root invocation.

---

## Installation

First, install [Visual Studio Code](https://code.visualstudio.com/) `1.99.0` or higher.

Install the extension via `Install from VSIX` in the command palette (`cmd-shift-p`) and choose the `.vsix` file built from this repository.

The following tools are required:

* **Nim compiler** — http://nim-lang.org
* **nimlangserver** (the Nim Tortoise language server binary) — built from the `langserver/` directory in this repository

_Note_: It is recommended to enable `Auto Save` in VS Code (`File → Auto Save`) when using this extension.

---

## Options

The following VS Code settings are available for the extension. Set them in user preferences (`cmd+,`) or workspace settings (`.vscode/settings.json`). All settings use the `nimTortoise.` prefix.

### Language server

* `nimTortoise.lsp.path` — explicit path to the Nim language server binary. If empty, the extension searches `~/.vscode-nim-tortoise/nimbledeps/bin/nimlangserver`, then `nimlangserver` in `PATH`.
* `nimTortoise.lsp.trace.server` — trace LSP communication between VS Code and the language server (`off` / `messages` / `verbose`). Useful for debugging.
* `nimTortoise.transportMode` — transport between extension and language server (`stdio` (default) or `socket`).
* `nimTortoise.lspPort` — when `transportMode` is `socket`, the port to connect to. `0` means the extension starts the socket server itself. Useful for attaching an external debugger to the language server.
* `nimTortoise.notificationVerbosity` — how much of the language server's output to surface as VS Code notifications (`none` / `error` / `warning` / `info`).
* `nimTortoise.notificationTimeout` — seconds before a language server notification auto-dismisses. `0` to disable auto-dismiss.

### Project configuration

* `nimTortoise.project` — array of Nim project entry-point files. If empty, each open file is treated as its own project.
* `nimTortoise.projectMapping` — array of `{ "fileRegex": "...", "projectFile": "..." }` objects for routing files to projects by regex. For example:
  ```json
  { "fileRegex": "(.*).inim", "projectFile": "$1.nim" }
  ```
* `nimTortoise.maxNimsuggestProcesses` — maximum number of nimsuggest processes to keep alive. `0` means unlimited. For monorepos, setting this to `1`–`3` keeps memory usage bounded.
* `nimTortoise.nimsuggestIdleTimeout` — milliseconds before an idle nimsuggest process is stopped (default: `120000` = 2 minutes).
* `nimTortoise.nimbleAutoSetup` — automatically run `nimble setup` when a `.nimble` file is detected in the workspace root (default: `true`). This generates `nimble.paths` and dramatically reduces language server startup time.

### Inlay hints

* `nimTortoise.inlayHints.typeHints.enable` — show inferred type annotations (default: `true`).
* `nimTortoise.inlayHints.parameterHints.enable` — show parameter names at call sites (default: `true`).
* `nimTortoise.inlayHints.exceptionHints.enable` — show exception annotations (default: `true`).
* `nimTortoise.inlayHints.exceptionHints.hintStringLeft` — string displayed to the left of exception hints (default: `🔔`).
* `nimTortoise.inlayHints.exceptionHints.hintStringRight` — string displayed to the right of exception hints (default: empty).

### Hover expansions

* `nimTortoise.nimExpandMacro` — expand macro call sites on hover (default: `false`).
* `nimTortoise.nimExpandArc` — expand ARC-transformed proc definitions on hover (default: `false`).

### Build and run

* `nimTortoise.buildOnSave` — run the build task from `tasks.json` on save (default: `false`). Requires a build task declared in `.vscode/tasks.json`.
* `nimTortoise.buildCommand` — Nim backend for compile/run commands (`c`, `cpp`, `doc`, etc.) (default: `c`).
* `nimTortoise.runOutputDirectory` — output directory for the "Run selected file" command, relative to workspace root.

### Formatting

* `nimTortoise.formatOnSave` — format the file on save using `nph` (default: `false`). Requires `nph` to be on `PATH`.

### Test runner

* `nimTortoise.test.entryPoint` — entry point for the test runner. If empty, test discovery is disabled. Alternatively, set `testEntryPoint` in your `.nimble` file (requires `nimble >= 0.20.0`).

### Debugging

* `nimTortoise.debug.type` — debugger type to use with "Debug selected file" (default: `lldb`). The value corresponds to the `type` field in `launch.json`.

### Other

* `nimTortoise.licenseString` — license text inserted at the top of new `.nim` files.
* `nimTortoise.test-project` — optional separate test project file.
* `nimTortoise.logNimsuggest` — enable verbose nimsuggest logging to the profile directory (default: `false`).

### Deprecated settings

The following settings are deprecated and have no effect in LSP mode. They were part of the original extension's direct nimsuggest integration and may be removed in a future version:

* `nimTortoise.lintOnSave` — use the LSP backend for diagnostics instead.
* `nimTortoise.enableNimsuggest` — use the LSP backend instead.
* `nimTortoise.provider` — always `lsp` in this fork.
* `nimTortoise.useNimsuggestCheck` — use the LSP backend instead.

---

### Example `.vscode/settings.json`

```json
{
    "nimTortoise.project": ["src/myproject.nim"],
    "nimTortoise.maxNimsuggestProcesses": 2,
    "nimTortoise.inlayHints.typeHints.enable": true,
    "nimTortoise.formatOnSave": true,
    "nimTortoise.notificationVerbosity": "warning"
}
```

---

## Commands

The following commands are provided by the extension (accessible via the command palette `cmd-shift-p`, under the `Nim Tortoise` category):

| Command | ID | Shortcut | Description |
|---|---|---|---|
| Run selected Nim file | `nimTortoise.run.file` | F6 | Compile and run the active file |
| Debug selected Nim file | `nimTortoise.debug.file` | Shift+F5 | Build and launch debugger for the active file |
| Check Nim project | `nimTortoise.check` | Ctrl+Alt+B | Run `nim check` on the project |
| Run Selection/Line in Terminal | `nimTortoise.execSelectionInTerminal` | Shift+Enter | Execute the selected code in a Nim REPL terminal |
| Clear internal caches | `nimTortoise.clearCaches` | — | Clear the extension's internal state caches |
| List candidate nim projects | `nimTortoise.listCandidateProjects` | — | List project entry points the extension has detected |
| Restart nimsuggest | `nimTortoise.restartNimsuggest` | — | Manually restart the nimsuggest process |
| Open Generated File | `nimTortoise.openGeneratedFile` | — | Open the C/C++ file generated by the Nim compiler |
| Refresh Tests | `nimTortoise.refreshTests` | — | Re-run test discovery and refresh the Test Explorer |

`Run selected Nim file` and `Debug selected Nim file` are also available from the editor title run button and right-click context menu when a `.nim` file is open.

---

## Debugging

VS Code includes a powerful debugging system, and the Nim tooling can take advantage of it. However, some setup is required.

### Setting up

First, install a debugging extension. [CodeLLDB](https://open-vsx.org/extension/vadimcn/vscode-lldb) is recommended. Install any native packages the extension may require (such as clang and LLDB).

Next, create a `tasks.json` file in your project's `.vscode` directory:

```jsonc
// .vscode/tasks.json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "nim: build current file (for debugging)",
            "command": "nim",
            "args": [
                "compile",
                "-g",
                "--debugger:native",
                "-o:${workspaceRoot}/bin/${fileBasenameNoExtension}",
                "${relativeFile}"
            ],
            "options": {
                "cwd": "${workspaceRoot}"
            },
            "type": "shell"
        }
    ]
}
```

Then create a `launch.json` in the same directory:

```jsonc
// .vscode/launch.json
{
    "version": "0.2.0",
    "configurations": [
        {
            "type": "lldb",
            "request": "launch",
            "name": "nim: debug current file",
            "preLaunchTask": "nim: build current file (for debugging)",
            "program": "${workspaceFolder}/bin/${fileBasenameNoExtension}",
            "args": [],
            "cwd": "${workspaceFolder}"
        }
    ]
}
```

The `nimTortoise.debug.type` setting controls which debugger type the "Debug selected file" command uses (default: `lldb`).

---

## Test Runner

The extension supports running tests via VS Code's Test Explorer. The project must use `unittest2 >= 0.2.4`.

Set the test entry point in settings:

```json
{
    "nimTortoise.test.entryPoint": "tests/all.nim"
}
```

Alternatively, set `testEntryPoint` in your `.nimble` file (requires `nimble >= 0.20.0`).

Tests appear in the VS Code Test Explorer panel. Use the **Refresh Tests** command (`nimTortoise.refreshTests`) to re-run discovery after adding new test files.

---

## Developing the Extension

The extension is written in **Nim** and compiled to JavaScript using the `js` backend.

| Task | Command |
|------|---------|
| Dev build (with source maps) | `nimble main` |
| Release build | `nimble release` |
| Package as VSIX | `nimble vsix` |
| Install VSIX locally | `nimble install_vsix` |

To debug the extension in VS Code, press **F5** in the dev workspace. The `.vscode/launch.json` runs `nimble build` and then launches an Extension Development Host window running the patched extension. Open a Nim project there to test.

### Side-loading the Extension

* Run `nimble vsix` to build the extension package to `out/nimvscode-<version>.vsix`
* Run `nimble install_vsix` if you have VS Code on `PATH`, or select **Install from VSIX** from the command palette and choose the `.vsix` file.

Then choose the built `nimtortoise` binary as the langsuage server path in the settings.

---

## Acknowledgments

This extension started out as a fork of the [@saem](https://github.com/saem) extension [vscode-nim](https://github.com/saem/vscode-nim), which was itself a port of an extension written in [TypeScript](https://marketplace.visualstudio.com/items?itemName=kosz78.nim) by @kosz78 for the Nim language.

Thank you Saem for your work and letting us build on top of it.



