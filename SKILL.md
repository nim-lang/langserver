---
name: nim-mcp-tools
description: 'Use for Nim symbol navigation and diagnostics. MANDATORY: Use specialized MCP tools (nimFindSymbols, nimFindReferences, nimListSymbols, nimCheckFile, nimCheckProject) first; fall back to grep only on error or user confirmation.'
---

# Nim MCP Tools

## Core Mandate
AI agents MUST prefer specialized MCP tools over general-purpose instruments (grep, shell commands, `read_file` with manual parsing) for all Nim symbol-related and Nim diagnostics tasks. This is critical for:
1. **Token Efficiency**: MCP tools return structured, relevant data, avoiding large file reads or noisy grep outputs.
2. **Precision**: These tools understand Nim semantics (scopes, imports, overloads) which string-based search cannot.

## Activation Rule
If the user asks to find, rename, remove, audit, or update a Nim symbol or its usages, this skill MUST be used first and the workflow must start with the Nim MCP symbol tools.

If the user asks to check a single Nim file for errors, warnings, hints, diagnostics, issues, problems, or compiler feedback, this skill MUST be used first and the workflow must start with `nimCheckFile`.

If the user asks to check a Nim project for errors, warnings, hints, diagnostics, issues, problems, or compiler feedback, this skill MUST be used first and the workflow must start with `nimCheckProject`.

This applies to requests phrased as:

- "find all usages/references of `Foo`"
- "remove all definitions of and references to `Foo`"
- "rename `Foo` everywhere"
- "where is `Foo` defined?"
- "list the symbols in this Nim file/module"
- "check this file/module for errors"
- "show diagnostics for `foo.nim`"
- "check this project/workspace/repository/package for errors"
- "find Nim diagnostics in the current codebase"
- "show warnings and hints for this repo"
- "scan the current module tree for Nim issues"

Treat user wording such as **project**, **workspace**, **repository**, **repo**, **package**, **codebase**, **checkout**, and **module tree** as referring to the current Nim project context when they are asking for project-wide diagnostics.

Treat user wording such as **file**, **module** (when a concrete Nim file is identified), **source file**, and explicit `*.nim` paths as referring to single-file diagnostics when they are asking for diagnostics for one file.

Do **not** pair `nimFindSymbols`, `nimCheckFile`, or `nimCheckProject` with `grep`, `ripgrep`, or shell search "just to double-check". If the task is about a Nim symbol or Nim diagnostics, MCP tools own the search unless they have already failed.

## User Terminology vs MCP `kind`
Users may ask for symbol categories using looser or non-strict terminology. AI agents MUST map that wording to the exact Nim MCP `kind` values before filtering results from `nimListSymbols(...)` or `nimFindSymbols(...)`.

The MCP server returns Nim-oriented kind names derived from nimsuggest symbol kinds with the leading `sk` removed, such as `Const`, `EnumField`, `Field`, `Iterator`, `Converter`, `Let`, `Macro`, `Method`, `Proc`, `Template`, `Type`, `Var`, and `Func`.

Use these terminology mappings when interpreting user requests:

- **function** / **functions**: usually match `Func` and `Proc`
- **pure function** / **pure functions**: match `Func`
- **callable** / **routine**: may include `Func`, `Proc`, `Method`, `Iterator`, `Converter`, `Macro`, and `Template`
- **class** / **classes**: match `Type`
- **variable** / **variables**: match `Var` and `Let`
- **property** / **properties**: match `Field`
- **enum member** / **enum members**: match `EnumField`
- **constant** / **constants**: match `Const`

Interpret user wording semantically, not literally. For example:

- "list all classes in this module" -> filter for `kind == Type`
- "list all variables" -> filter for `kind in {Var, Let}`
- "list all functions" -> filter for `kind in {Func, Proc}` unless the surrounding context clearly asks for all callables
- "list all pure functions" -> filter for `kind == Func`

## When to Use
- **Finding References**: To rename a symbol, update a signature, or find usages.
- **Symbol Discovery**: To find where a symbol is defined by name.
- **File Analysis**: To get an overview of all symbols in a file.
- **File Diagnostics**: To check one specific Nim file for errors, warnings, and hints.
- **Project Diagnostics**: To check the current Nim project/workspace/repository/package for errors, warnings, and hints.

## Workflows

### 1. Find All References or Usages of a Symbol Name
Do NOT grep for the name.
1. Call `nimFindSymbols(query: "SymbolName")` to get exact `path`, `line`, and `column`.
2. For each relevant result, call `nimFindReferences(path, line, column)`.
3. Aggregate the results.

Use this workflow for "usages", "references", "call sites", and cleanup requests such as removing all definitions of and references to a symbol.

### 2. List All Symbols in a File
Do NOT read the whole file to find definitions.
1. Call `nimListSymbols(path: "path/to/file.nim")`.
2. If the user asked for a symbol category, filter by the MCP `kind` values that correspond to the user's terminology.
3. Use the returned list to navigate or analyze the file structure.

### 3. Find Definitions
1. Call `nimFindSymbols(query: "query")`.

### 4. Check a Single Nim File for Diagnostics
Do NOT approximate file diagnostics by reading the file manually or by running a project-wide diagnostic request when the user asked about one file.
1. Call `nimCheckFile(path: "path/to/file.nim")`.
2. Treat the result as the answer unless the user explicitly asked for broader validation such as project-wide diagnostics, tests, or builds.
3. Use the returned diagnostics to report errors, warnings, and hints for that file.
4. If the user asked for only a subset (for example, only errors or only warnings), filter the returned diagnostics by severity before presenting them.

Use this workflow for requests phrased as checking a specific file, source file, module, or explicit `*.nim` path for Nim issues.

### 5. Check the Current Nim Project for Diagnostics
Do NOT approximate project diagnostics by grepping build logs or manually scanning files.
1. Call `nimCheckProject()`.
2. Interpret diagnostics with `path: "???"`, `line: 0`, and `column: -1` as top-level diagnostics that do not correspond to a particular file and instead relate to the project as a whole.
3. Use the returned diagnostics to report errors, warnings, and hints for the current Nim project context.
4. If the user asked for only a subset (for example, only errors or only warnings), filter the returned diagnostics by severity before presenting them.

Use this workflow for requests phrased as checking the current project, workspace, repository, repo, package, codebase, checkout, or module tree for Nim issues.

## Fallback Policy
Specialized Nim MCP tools are the primary instrument. General-purpose tools (grep, ripgrep, shell commands) are secondary and their use is governed by the following rules:

1. **On Error**: If an MCP tool fails due to a technical error (e.g., tool crash, timeout, connection issue), you MUST fall back to `grep_search` or other general-purpose tools to fulfill the request.
   - State clearly that the MCP tool failed.
   - Use the narrowest fallback necessary.
2. **On Empty Results**: If an MCP tool returns no results (empty list), do NOT automatically fall back to grep. Instead, you MUST prompt the user, asking if they would like you to attempt a plain text search using general-purpose tools.
3. **Availability**: If MCP tools are unavailable in the environment, use general-purpose tools but inform the user.

When falling back:
- Do not present the fallback results as equivalent in precision to MCP tool results.

## Critical Constraints
- **NO GREP BY DEFAULT**: Never use `grep`, `ripgrep`, or `grep_search` to find Nim symbols or references unless the MCP tools have explicitly errored out.
- **PROMPT ON EMPTY**: If MCP tools return nothing, you MUST ask the user before falling back to grep.
- **NO MANUAL PARSING**: Do not read large Nim files just to extract symbol locations; use `nimListSymbols` instead.
- **NO DIY FILE CHECKS**: Do not substitute manual inspection, ad-hoc compiler invocations, or `nimCheckProject` when `nimCheckFile` can return structured diagnostics for the specific file the user asked about.
- **NO DIY PROJECT CHECKS**: Do not substitute shelling out to ad-hoc Nim commands, parsing compiler output, or manually inspecting many files when `nimCheckProject` can return structured project diagnostics.
- **TOKEN CONSERVATION**: Minimize turns and context by using the most precise tool available.

## Anti-Patterns
- Calling `nimFindSymbols("Foo")` and then running `rg "Foo"` anyway.
- Using `rg` for "find all usages" when `nimFindReferences` is available.
- Reading multiple Nim files to manually enumerate definitions that `nimListSymbols` can return directly.
- Running `nimCheckProject()` when the user asked to check one specific Nim file and `nimCheckFile` is available.
- Manually reading or building a single Nim file first when `nimCheckFile` can return structured diagnostics for it.
- Running a manual project build or grep-based log scan first when the user asked for project/workspace/repository/package diagnostics and `nimCheckProject` is available.
