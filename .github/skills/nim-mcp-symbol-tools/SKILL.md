---
name: nim-mcp-symbol-tools
description: 'Use for Nim symbol navigation (definitions, references, file symbols). MANDATORY: Prefer specialized MCP tools (nimFindSymbols, nimFindReferences, nimListSymbols) over grep, ripgrep, or shell commands to save tokens and ensure semantic precision.'
---

# Nim MCP Symbol Tools

## Core Mandate
AI agents MUST prefer specialized MCP tools over general-purpose instruments (grep, shell commands, `read_file` with manual parsing) for all Nim symbol-related tasks. This is critical for:
1. **Token Efficiency**: MCP tools return structured, relevant data, avoiding large file reads or noisy grep outputs.
2. **Precision**: These tools understand Nim semantics (scopes, imports, overloads) which string-based search cannot.

## Activation Rule
If the user asks to find, rename, remove, audit, or update a Nim symbol or its usages, this skill MUST be used first and the workflow must start with the Nim MCP symbol tools.

This applies to requests phrased as:

- "find all usages/references of `Foo`"
- "remove all definitions of and references to `Foo`"
- "rename `Foo` everywhere"
- "where is `Foo` defined?"
- "list the symbols in this Nim file/module"

Do **not** pair `nimFindSymbols` with `grep`, `ripgrep`, or shell search "just to double-check". If the task is about a Nim symbol, MCP tools own the search unless they have already failed.

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

## Fallback Policy
General text search is allowed only after the relevant Nim MCP tool has explicitly failed, returned unusable results, or is unavailable in the environment.

When falling back:

1. State that the MCP tool failed or was unavailable.
2. Use the narrowest fallback necessary.
3. Do not present the fallback as equivalent in precision to `nimFindSymbols`, `nimFindReferences`, or `nimListSymbols`.

## Critical Constraints
- **NO GREP**: Never use `grep`, `ripgrep`, or `grep_search` to find Nim symbols or references unless the MCP tools are explicitly failing.
- **NO MANUAL PARSING**: Do not read large Nim files just to extract symbol locations; use `nimListSymbols` instead.
- **TOKEN CONSERVATION**: Minimize turns and context by using the most precise tool available.

## Anti-Patterns
- Calling `nimFindSymbols("Foo")` and then running `rg "Foo"` anyway.
- Using `rg` for "find all usages" when `nimFindReferences` is available.
- Reading multiple Nim files to manually enumerate definitions that `nimListSymbols` can return directly.
