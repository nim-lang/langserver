# Contributor Guide

This guide is for contributors working on `nimlangserver` itself. It focuses on the internal architecture, how the package is organized, how MCP tools are wired, and where to look when something goes wrong.

Older architecture notes have been merged into this guide so contributors have a single obvious entry point.

```admonish tip title="Explore the codebase with DeepWiki"
[DeepWiki](https://deepwiki.com/nim-lang/langserver) provides an AI-generated, searchable overview of the `nimlangserver` codebase. It's a great starting point for new contributors who want to understand the structure before diving into the source.

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/nim-lang/langserver)
```

The generated [API index](apidocs/theindex.html) is also a useful reference when navigating the codebase.

## Contents

<!-- toc -->

## Architecture at a glance

```text
Client
├─ LSP client (editor)
│  └─ JSON-RPC over stdio or a socket, with Content-Length framing
└─ MCP client
   └─ JSON-RPC over stdio (one JSON object per line) or a socket

nimlangserver.nim
└─ builds LanguageServer state, starts transport, registers routes
   ├─ registerLspRoutes()  -> routes/lsp.nim
   └─ registerMcpRoutes()  -> routes/mcp.nim

lstransports2.nim
└─ thin layer over json-rpc's stdio and socket servers
   ├─ wrapRpc()          -> route handler <-> RpcProc
   └─ initActions()      -> ls.notify / ls.call / ls.onExit

ls.nim
└─ shared server state and orchestration
   ├─ workspace/config parsing
   ├─ file shadow copies + UTF-16/UTF-8 mapping
   ├─ project-file discovery
   ├─ nimsuggest lifecycle and reuse
   ├─ diagnostics/status/progress helpers
   └─ maintenance loop (tickLs -> tick)

Backends
├─ suggestapi.nim   -> long-lived nimsuggest processes and command queue
├─ nimcheck.nim     -> `nim check` diagnostics path
├─ nimexpand.nim    -> macro / ARC expansion helpers
└─ testrunner.nim   -> unittest2 discovery and execution
```

## Request/data flow

### LSP flow

1. `nimlangserver.nim` parses CLI flags, creates `LanguageServer`, registers LSP routes, and starts the stdio or socket transport.
2. `routes/lsp.nim.initialize` stores client capabilities and eagerly starts `nimsuggest` for nimble entry points.
3. `lstransports2.nim` (`json-rpc`) reads and decodes the JSON-RPC messages and its router looks up the registered route and invokes the handler.
4. Route handlers use `ls.nim` helpers such as `didOpenFile`, `getProjectFile`, and `tryGetNimsuggest`.
5. `suggestapi.nim` sends the actual command to `nimsuggest`, parses the tab-separated result, and returns structured objects.
6. The route maps those objects into LSP types from `protocol/types.nim`, and `lstransports2.nim` serializes the response back to the client.

### MCP flow

The MCP flow is the same shared pipeline with a thinner route layer:

1. `nimlangserver.nim` registers `initialize`, `tools/list`, `tools/call`, and `notifications/initialized` from `routes/mcp.nim`.
2. `routes/mcp.nim.initialize` stores MCP capabilities and eagerly starts `nimsuggest` for the current working directory's nimble entry points.
3. `tools/call` dispatches by tool name, usually opens the target file if needed, obtains a `nimsuggest` instance via `tryGetNimsuggest`, and converts the result into `McpCallToolResult`.
4. `structuredContent` is the authoritative machine-readable result; `content` mirrors it as JSON text for clients that only read text blocks.

### Important design notes

- `LanguageServer` is a shared state object for both modes. The `serverMode` field switches the shape of the initialize params/capabilities stored inside it.
- The server serves one client at a time. `processSocketClient` hangs up on a connection that arrives while `ls.connection` is set, since `ls` holds a single session; stdio has one connection by construction.
- `lstransports2.nim` is shared by both modes and by both transports; the transports differ only in where the connection comes from — stdio serves the pipes the spawning client left on our descriptors, the socket server serves every accepted client. The framing is `Content-Length` everywhere except MCP over stdio, which is newline delimited JSON, as MCP clients expect.
- Messages are dispatched concurrently, with one ordering guarantee: the part of a handler that runs before its first `await` completes before the next message is read off the connection. `lstransports2.route` returns immediately instead of awaiting the handler, and chronos runs async bodies eagerly, so that prefix is the only place where ordering against later messages is guaranteed. Anything a following message could observe — the `openFiles` entry, the stash file contents — has to be applied there.
- MCP currently treats the current working directory as the workspace root (`getRootPath(McpInitializeParams)` returns `getCurrentDir()`), so start the server from the workspace you want to inspect.
- `tickLs` in `nimlangserver.nim` keeps running after initialization and calls `ls.tick()` to prune completed requests and stop idle `nimsuggest` processes.

## Historical architecture notes

- `nimlangserver` is still best thought of as a fairly thin proxy between a client and one or more long-lived `nimsuggest` processes. In normal operation there is one `nimsuggest` instance per project/configuration pair, and requests are routed to the matching instance.
- Project discovery is implemened through `ls.nim:getProjectFileAutoGuess`, `ls.nim:getNimbleDumpInfo`, and the `nimble dump`-based entry-point discovery path.
- If no better project root is found, the opened file may become its own project file. That fallback is still an important behavior to remember when debugging odd workspace-root or include-file issues.
- File editing is not delegated directly to `nimsuggest`. `nimlangserver` mirrors open file contents into temporary shadow files and passes those paths to backend operations. When debugging stale or surprising results, inspect `ls.nim:didOpenFile`, stash-path helpers, and the code paths that decide whether a file is treated as dirty.

## Package structure

- `nimlangserver.nim`: program entry point, CLI flag parsing, route registration, transport startup, process-monitor setup, and the maintenance loop.
- `ls.nim`: core server state (`LanguageServer`), configuration parsing, project discovery, open-file shadow state, diagnostics plumbing, `nimsuggest` lifecycle, and shared helpers used by both LSP and MCP.
- `lstransports2.nim`: the socket transport. Framing, routing and request/response correlation come from `json-rpc`; this module only holds `wrapRpc`, request cancellation bookkeeping, and the outbound request/notification helpers.
- `routes/lsp.nim`: LSP method handlers and Nim-specific extension methods. This is the best reference for which `nimsuggest` command powers which feature.
- `routes/mcp.nim`: MCP initialize/list/call handlers plus the current MCP tool implementations. Most MCP work happens here.
- `suggestapi.nim`: `nimsuggest` process startup, capability detection, request queueing, timeout handling, stderr capture, and parsing of `nimsuggest` responses into `Suggest` values.
- `nimcheck.nim`: `nim check --listFullPaths` integration used when configuration chooses compiler-based diagnostics instead of `nimsuggest` diagnostics.
- `nimexpand.nim`: fallback support for macro expansion and ARC expansion via `nim c --expandMacro` / `--expandArc`.
- `testrunner.nim`: test discovery and execution for the custom LSP test routes.
- `asyncprocmonitor.nim`: watches a client PID and shuts the server down when that process disappears.
- `utils.nim`: URI/path helpers, UTF conversion helpers, future helpers, process shutdown utilities, temp storage helpers, and JSON-RPC param conversion helpers.
- `protocol/types.nim`: data model types for JSON-RPC, LSP, and MCP payloads.
- `protocol/enums.nim`: protocol enums used by the type layer.
- `templates/nimscriptapi.nim`: compatibility shim injected for `.nims` / `.nimble` handling.
- `tests/tmcp.nim`: MCP route coverage. Start here when changing MCP behavior.
- `tests/tnimlangserver.nim`, `tests/textensions.nim`, `tests/tmisc.nim`, `tests/tsuggestapi.nim`, `tests/ttestrunner.nim`: coverage for LSP/server helpers, extensions, misc behavior, raw `nimsuggest` integration, and test execution.
- `tests/projects/`: fixture workspaces used by the tests.

## How to add a new MCP tool

Most of the work is in `routes/mcp.nim`:

1. Add a tool-definition proc that returns `McpTool`.
2. Add a `call...` proc that:
   - reads and validates `params.arguments`
   - opens the file with `ls.didOpenFile(...)` if the tool works on a path and the file is not already open
   - gets a `nimsuggest` instance with `await ls.tryGetNimsuggest(uri)`
   - calls the relevant backend method
   - maps the result into `structuredContent`
   - mirrors that JSON into `content`
3. Register the new tool in `listTools`.
4. Dispatch it in `callTool`.
5. Add coverage in `tests/tmcp.nim`.

### How to choose the backend command

The fastest way to choose the correct `nimsuggest` command is to look for an analogous LSP handler in `routes/lsp.nim`, then follow the call into `suggestapi.nim`.

Common mappings already used in the codebase:

- Symbol references at a cursor location: `nimFindReferences`, LSP `textDocument/references` -> `use(...)`
- Workspace symbol search: `nimFindSymbols`, LSP `workspace/symbol` -> `globalSymbols(query)`
- Symbols in one file: `nimListSymbols`, LSP `textDocument/documentSymbol` -> `outline(path)`
- Whole-project diagnostics: `nimCheckProject`, LSP project checking -> `chk(path)`
- One-file diagnostics: `nimCheckFile`, LSP file checking -> `chkFile(path)` and sometimes a warm-up `con(...)`
- Go to definition: LSP `textDocument/definition` -> `def(...)`
- Go to declaration: LSP `textDocument/declaration` -> `declaration(...)`
- Completion: LSP `textDocument/completion` -> `sug(...)`

If you are unsure, `routes/lsp.nim` is usually the best oracle because it already encodes the intended user-facing behavior.

### Skeleton

```nim
proc nimMyTool(): McpTool =
  McpTool(
    name: "nimMyTool",
    title: some "Describe the tool briefly",
    description: some "Describe what it returns.",
    inputSchema: McpToolSchema(
      `type`: "object",
      properties: %*{"path": {"type": "string"}},
      required: @["path"],
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties: %*{"items": {"type": "array"}},
      required: @["items"],
    ),
  )

proc callNimMyTool(
    ls: LanguageServer, params: McpCallToolParams
  ): Future[McpCallToolResult] {.async.} =
  let
    arguments = params.arguments.get(JsonNode())
    path = arguments["path"].getStr().absolutePath
    uri = path.pathToUri()

  if uri notin ls.openFiles:
    await ls.didOpenFile(
      TextDocumentItem(uri: uri, languageId: "nim", version: 0, text: readFile(path))
    )

  let nimsuggest = await ls.tryGetNimsuggest(uri)
  if nimsuggest.isNone:
    return McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: some true,
    )

  let items = await nimsuggest.get.someCommand(...)
  let structuredContent = %*{"items": items.mapIt(...)}
  return McpCallToolResult(
    content: @[McpContentBlock(`type`: TextContent, text: $structuredContent)],
    structuredContent: some structuredContent,
    isError: some false,
  )
```

### Testing checklist

- Add a happy-path case to `tests/tmcp.nim`.
- If the tool has edge cases, add a fixture under `tests/projects/`.
- Assert both `structuredContent` and the mirrored text payload; `checkToolResult` already does that.

### A reusable Copilot prompt

If you want to automate the mechanical part with Copilot, use this prompt template. Replace the content between `---` markers with your tool description:

> Add a new MCP tool to `routes/mcp.nim` and `tests/tmcp.nim`.
>
> ---
> Describe the tool here: what it does, what it returns, what nimsuggest backend command it should use (check `routes/lsp.nim` and `suggestapi.nim` for the closest analogue), what its input and output schemas look like.
> ---
>
> Follow the existing `nimFindReferences` / `nimCheckFile` pattern.
> Reuse the closest matching handler in `routes/lsp.nim` to choose the correct backend method from `suggestapi.nim`.
> Return machine-readable data in `structuredContent` and mirror it as JSON text in `content`.
>
> After implementing the tool:
>
> 1. **Identify real-life AI agent use cases.** Think about what coding tasks this tool enables or improves when used by an AI agent (e.g., "find the origin of a symbol", "resolve a type mismatch during debugging"). Add these to the "When to Use" section and the Activation Rule in `SKILL.md`.
> 2. **Add workflow instructions to `SKILL.md`.** Describe step-by-step how an AI agent should use this tool, both standalone and in combination with other tools (e.g., `nimCheckFile` + `nimFindTypeDefinition`). Cover the new workflows in the Workflows section.
> 3. **List the tool in `README.md`.** Add the tool name to the "The current MCP tool set is:" list in the MCP server section.

## Debugging guide

### Where logs go

- Server logs use `chronicles` macros such as `debug`, `info`, `warn`, and `error`.
- Unhandled exceptions are written by `writeStackTrace`, which prints to `stderr`.
- `nimsuggest` stderr is captured in `suggestapi.nim:logNsError` and re-emitted as `NimSuggest Error (stderr)` before the project is marked failed.

In practice:

- **From an editor:** look at your editor's language-server log / trace output. The README already shows enabling verbose server tracing in `coc.nvim`.
- **By hand:** run the server in a terminal and watch `stderr` directly.

Example:

```bash
nimble build
./nimlangserver --mcp --stdio 2>mcp.stderr.log
```

### Useful places to put breakpoints or temporary logs

- For route registration or selected mode, start in `nimlangserver.nim`.
- For raw JSON-RPC parsing or framing issues, start in `lstransports2.nim` and in `json-rpc`'s `clients/socketclient.nim`.
- For project-file detection or workspace-root issues, start in `ls.nim:getProjectFile` and `ls.nim:getProjectFileAutoGuess`.
- For open-file shadowing or stash paths, start in `ls.nim:didOpenFile` and `ls.nim:uriToStash`.
- For `nimsuggest` startup, restart loops, or timeouts, start in `ls.nim:createOrRestartNimsuggest`, `suggestapi.nim:createNimsuggest`, and `suggestapi.nim:processQueue`.
- For MCP tool dispatch, start in `routes/mcp.nim:callTool`.
- For LSP feature behavior, start in the matching handler in `routes/lsp.nim`.
- For the diagnostics path, start in `ls.nim:checkFile`, `ls.nim:checkProject`, and `nimcheck.nim`.

### Ad-hoc file logging

For local debugging, a tiny helper can be convenient when you want logs that are completely separate from the JSON-RPC stream:

```nim
import std/[os, syncio]

proc logToFile(msg: string) =
  let f = open(getCurrentDir() / "mcp.log", fmAppend)
  defer:
    f.close()
  f.writeLine(msg)
  f.flushFile()
```

This is useful while iterating on MCP handlers because it does not interfere with the protocol stream. It should stay a local debugging aid rather than a committed dependency.

## Running tests

The main test command is:

```bash
nimble test
```

When you change MCP behavior, `tests/tmcp.nim` is the most relevant file to read first, even if you still run the full suite.

## Test runner

`nimlangserver` exposes LSP routes that let editors list and run `unittest2` tests directly from the UI. For this to work, the project must use `unittest2 >= 0.2.4`, and a test entry point must be provided — either via the VSCode extension setting `nim.test.entryPoint`, or via `testEntryPoint` in future versions of `nimble`.

The implementation lives in `testrunner.nim`.
