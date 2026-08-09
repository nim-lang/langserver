# Nim Tortoise

> *Slow and steady wins the race.*

A Nim language server and VS Code extension that prioritise **correctness** over speed — a fork and rewrite of [`nimlangserver`](https://github.com/nim-lang/langserver) and [`vscode-nim`](https://github.com/nim-lang/vscode-nim).

---

## The Problem

On large Nim projects — especially monorepos with multiple packages — the standard tooling frequently:

- Takes over a minute to start before any highlighting appears
- Shows stale completions and hover results long after you've edited the file
- Crashes after 10–15 minutes of use and fails to recover cleanly
- Ignores the `maxNimsuggestProcesses` limit, spawning one process per open file
- Breaks language features silently after a file rename

This repository exists because these problems have architectural roots that can't be fixed incrementally.

---

## What's in This Repository

| Directory | What it is |
|-----------|------------|
| [`langserver/`](langserver/) | The Nim language server — a ground-up rewrite of `nimlangserver` |
| [`vscode_extension/`](vscode_extension/) | The VS Code extension — an LSP-only fork of `vscode-nim` |

The two components are designed to work together but are independent. The language server speaks standard LSP and will work with any LSP-capable editor.

---

## Key Improvements

### Startup performance

Forwarding `nimble.paths` directly to nimsuggest eliminates the need for nimsuggest's internal compiler to call nimble for every unresolved import. Cold-compile time dropped from **~53 seconds to ~11 seconds** in our testing. Subsequent requests are fast (< 1s) because the compiled module graph is cached on disk between sessions.

The VS Code extension no longer runs `nimble dump` unconditionally on activation — a fix that removes the exponential-time SAT solver from VS Code's startup critical path when launched from the Dock.

### Correctness through serialisation

All LSP work flows through a two-level queue:

1. A single **FIFO `langserverQueue`** serialises all file and nimsuggest work. A `didChange` stash write is always applied before the hover query that follows it — no exceptions.
2. Each `nimsuggest` process has its own **per-slot `queryMailbox`**. Commands for the same process are serialised; commands for different processes run concurrently.

This eliminates the race conditions (stale responses, crashes, incorrect highlights) caused by concurrent handlers sharing the same TCP connection to nimsuggest.

### Stable process ownership

The old architecture tracked file-to-project ownership in two separate tables that had to be kept in sync by convention at every mutation site. The rewrite replaces this with a single `NlsFileInfo → slot` reference: each open file points directly to its `NimsuggestSlot`, and each slot owns a set of URIs. There are no redirect aliases, no manual sync, no guards to check.

### Robust crash recovery

- Exponential backoff between restart attempts (1s → 2s → 4s → … capped at 30s)
- User notification after repeated failures, with the dead slot removed from the pool
- Correct re-registration of all open files after a restart, not just the one that triggered it
- No more infinite crash loops at full CPU

### Live diagnostics

`checkFile` now calls `changed()` before `chkFile`, so nimsuggest always checks the live editor buffer. Diagnostic squiggles update as you type, not only on save.

---

## Getting Started

### Requirements

- Nim with `nimsuggest` (`--v4` support, i.e. Nim 1.6+)
- `nimble >= 0.16.1`
- VS Code `>= 1.99.0` (for the extension)

### Build the language server

```sh
cd langserver
nimble main       # produces the nimlangserver binary
```

### Build and install the VS Code extension

```sh
cd vscode_extension
nimble vsix            # packages out/nimvscode-<version>.vsix
nimble install_vsix    # installs it into VS Code
```

The extension is written in Nim and compiled to JavaScript. It is not a TypeScript extension.

### Point the extension at the binary

Add to `.vscode/settings.json` in your project:

```json
{
  "nimTortoise.lsp.path": "/path/to/your/nimlangserver"
}
```

If omitted, the extension searches `~/.vscode-nim-tortoise/nimbledeps/bin/nimlangserver` then `nimlangserver` in `PATH`.

---

## Project Setup (Essential)

Most tooling problems trace back to the same three configuration mistakes. Get these right and everything else follows.

**1. Set `entryPoints` in every `.nimble` file.**
The language server needs to know which file to give `nimsuggest` as its compilation root. Without it, every opened file becomes its own root, spawning a new process and giving incomplete results.

```nim
# mypackage.nimble
srcDir      = "src"
entryPoints = @["src/mypackage.nim"]
```

**2. Use `thisDir()` in `config.nims`, not `$projectDir`.**
`$projectDir` resolves to the directory of the *file being compiled*, which is different for every file inside `src/`. `thisDir()` always resolves to the directory containing `config.nims`.

```nim
# config.nims
switch("path", thisDir() & "/../other_package/src")   # correct
switch("path", "$projectDir/../other_package/src")    # wrong — breaks for deep files
```

**3. Declare all transitive path dependencies at the top level.**
A library's `config.nims` is *not* read when that library is imported by another package. Every `switch("path", ...)` entry needed by the entire transitive import closure must appear in the top-level package's `config.nims`.

**4. Run `nimble setup`** in each project root to generate `nimble.paths`. This pre-computes dependency paths and dramatically reduces startup time.

Full setup documentation, including monorepo configuration and a checklist, is in [langserver/README.md](langserver/README.md).

---

## All Settings Use `nimTortoise.`

This extension uses the `nimTortoise.` prefix for all settings and commands to avoid conflicts with the original `vscode-nim` extension. The two **cannot be installed simultaneously** — this extension replaces the original.

Key settings at a glance:

| Setting | Default | What it does |
|---------|---------|--------------|
| `nimTortoise.lsp.path` | `""` | Path to the language server binary |
| `nimTortoise.maxNimsuggestProcesses` | `0` | Max nimsuggest processes (0 = unlimited) |
| `nimTortoise.nimsuggestIdleTimeout` | `120000` | Idle timeout in ms before stopping a process |
| `nimTortoise.projectMapping` | `[]` | Per-file project mapping via regex |
| `nimTortoise.inlayHints.typeHints.enable` | `true` | Show inferred type annotations |
| `nimTortoise.formatOnSave` | `false` | Format with `nph` on save |
| `nimTortoise.nimExpandMacro` | `false` | Expand macro calls on hover |

Full settings reference is in [vscode_extension/README.md](vscode_extension/README.md).

---

## Documentation

- [langserver/README.md](langserver/README.md) — how nimsuggest and the language server work together, best practices for project setup, architecture details
- [vscode_extension/README.md](vscode_extension/README.md) — full settings reference, commands, debugging setup, test runner, development guide

---

## Acknowledgements

This project builds on the work of:

- The [nimlangserver](https://github.com/nim-lang/langserver) team
- [@saem](https://github.com/saem) for [vscode-nim](https://github.com/saem/vscode-nim)
- [@kosz78](https://marketplace.visualstudio.com/items?itemName=kosz78.nim) for the original TypeScript Nim extension
