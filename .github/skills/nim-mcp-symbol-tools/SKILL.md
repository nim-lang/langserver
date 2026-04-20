---
name: nim-mcp-symbol-tools
description: 'Use for Nim symbol navigation (definitions, references, file symbols). MANDATORY: Prefer specialized MCP tools (nimFindSymbols, nimFindReferences, nimListSymbols) over grep, ripgrep, or shell commands to save tokens and ensure semantic precision.'
---

# Nim MCP Symbol Tools

## Core Mandate
AI agents MUST prefer specialized MCP tools over general-purpose instruments (grep, shell commands, `read_file` with manual parsing) for all Nim symbol-related tasks. This is critical for:
1. **Token Efficiency**: MCP tools return structured, relevant data, avoiding large file reads or noisy grep outputs.
2. **Precision**: These tools understand Nim semantics (scopes, imports, overloads) which string-based search cannot.

## When to Use
- **Finding References**: To rename a symbol, update a signature, or find usages.
- **Symbol Discovery**: To find where a symbol is defined by name.
- **File Analysis**: To get an overview of all symbols in a file.

## Workflows

### 1. Find All References of a Symbol Name
Do NOT grep for the name.
1. Call `nimFindSymbols(query: "SymbolName")` to get exact `path`, `line`, and `column`.
2. For each relevant result, call `nimFindReferences(path, line, column)`.
3. Aggregate the results.

### 2. List All Symbols in a File
Do NOT read the whole file to find definitions.
1. Call `nimListSymbols(path: "path/to/file.nim")`.
2. Use the returned list to navigate or analyze the file structure.

### 3. Find Definitions
1. Call `nimFindSymbols(query: "query")`.

## Critical Constraints
- **NO GREP**: Never use `grep`, `ripgrep`, or `grep_search` to find Nim symbols or references unless the MCP tools are explicitly failing.
- **NO MANUAL PARSING**: Do not read large Nim files just to extract symbol locations; use `nimListSymbols` instead.
- **TOKEN CONSERVATION**: Minimize turns and context by using the most precise tool available.
