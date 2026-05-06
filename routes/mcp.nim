import
  std/[os, sequtils, tables, json],
  pkg/[chronos, json_rpc/server, chronicles, json_serialization],
  ../[suggestapi, ls, utils],
  ../protocol/types

const McpProtocolVersion* = "2025-11-25"

# Tool definitions

proc nimFindReferences(): McpTool =
  McpTool(
    name: "nimFindReferences",
    title: some "Find symbol references in .nim files",
    description:
      some "Find references of the symbol under cursor in the current workspace.",
    inputSchema: McpToolSchema(
      `type`: "object",
      properties:
        %*{
          "path": {"type": "string"},
          "line": {"type": "integer"},
          "column": {"type": "integer"},
        },
      required: @["path", "line", "column"],
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties:
        %*{
          "refs": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "path": {"type": "string"},
                "line": {"type": "integer"},
                "column": {"type": "integer"},
              },
              "required": ["path", "line", "column"],
            },
          }
        },
      required: @["refs"],
    ),
  )

proc nimFindSymbols(): McpTool =
  McpTool(
    name: "nimFindSymbols",
    title: some "Find symbols in .nim files",
    description:
      some "Find symbols matching the given search query in the current workspace.",
    inputSchema: McpToolSchema(
      `type`: "object",
      properties: %*{"query": {"type": "string"}},
      required: @["query"],
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties:
        %*{
          "syms": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "path": {"type": "string"},
                "line": {"type": "integer"},
                "column": {"type": "integer"},
                "kind": {"type": "string"},
              },
              "required": ["path", "line", "column", "kind"],
            },
          }
        },
      required: @["syms"],
    ),
  )

proc nimListSymbols(): McpTool =
  McpTool(
    name: "nimListSymbols",
    title: some "List symbols in a .nim file",
    description: some "List all symbols in the given .nim file.",
    inputSchema: McpToolSchema(
      `type`: "object", properties: %*{"path": {"type": "string"}}, required: @["path"]
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties:
        %*{
          "syms": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "name": {"type": "string"},
                "line": {"type": "integer"},
                "column": {"type": "integer"},
                "kind": {"type": "string"},
              },
              "required": ["name", "line", "column", "kind"],
            },
          }
        },
      required: @["syms"],
    ),
  )

proc nimCheckProject(): McpTool =
  McpTool(
    name: "nimCheckProject",
    title: some "Check the current workspace",
    description:
      some "Get diagnostics (errors, warnings, and hints) for the current workspace.",
    inputSchema: McpToolSchema(`type`: "object", properties: %*{}, required: @[]),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties:
        %*{
          "diags": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "path": {"type": "string"},
                "line": {"type": "integer"},
                "column": {"type": "integer"},
                "severity": {"type": "string"},
                "message": {"type": "string"},
              },
              "required": ["path", "line", "column", "severity", "message"],
            },
          }
        },
      required: @["diags"],
    ),
  )

proc nimCheckFile(): McpTool =
  McpTool(
    name: "nimCheckFile",
    title: some "Check a .nim file",
    description:
      some "Get diagnostics (errors, warnings, and hints) for a given .nim file.",
    inputSchema: McpToolSchema(
      `type`: "object", properties: %*{"path": {"type": "string"}}, required: @["path"]
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties:
        %*{
          "diags": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "line": {"type": "integer"},
                "column": {"type": "integer"},
                "severity": {"type": "string"},
                "message": {"type": "string"},
              },
              "required": ["line", "column", "severity", "message"],
            },
          }
        },
      required: @["diags"],
    ),
  )

# Tool calls

proc callNimFindReferences(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.async.} =
  let
    arguments = params.arguments.get(JsonNode())
    path = arguments["path"].getStr().absolutePath
    uri = path.pathToUri()
    line = arguments["line"].getInt()
    column = arguments["column"].getInt()

  if uri notin ls.openFiles:
    await ls.didOpenFile(
      TextDocumentItem(uri: uri, languageId: "nim", version: 0, text: readFile(path))
    )

  let nimsuggest = await ls.tryGetNimsuggest(uri)

  if nimsuggest.isSome:
    let references = await nimsuggest.get.use(path, path, line, column)

    var usageReferencesJson = newJArray()
    for reference in references:
      if reference.section == ideUse:
        usageReferencesJson.add %*{
          "path": reference.filePath, "line": reference.line, "column": reference.column
        }

    let structuredContent = %*{"refs": usageReferencesJson}

    McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: $structuredContent)],
      structuredContent: some structuredContent,
      isError: some false,
    )
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: some true,
    )

proc callNimFindSymbols(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.async.} =
  if len(ls.projectFiles) == 0:
    return McpCallToolResult(
      content:
        @[
          McpContentBlock(
            `type`: TextContent, text: "Tool works only in Nimble projects"
          )
        ],
      isError: some true,
    )

  let
    arguments = params.arguments.get(JsonNode())
    query = arguments["query"].getStr()
    path = ls.projectFiles.keys.toSeq[0]
    uri = path.pathToUri()

  if uri notin ls.openFiles:
    await ls.didOpenFile(
      TextDocumentItem(uri: uri, languageId: "nim", version: 0, text: readFile(path))
    )

  # This should probably be reimplemented with ls.lastNimSuggest
  # but it is not assigned during initiallization and is therefore `nil`.
  # As as workaround, we "open" the first available projectFile
  # and use its nimsuggest instance.
  let nimsuggest = await ls.tryGetNimsuggest(uri)

  if nimsuggest.isSome:
    let symbols = await nimsuggest.get.globalSymbols(query)

    var symbolsJson = newJArray()
    for symbol in symbols:
      symbolsJson.add %*{
        "path": symbol.filePath,
        "line": symbol.line,
        "column": symbol.column,
        "kind": symbol.symkind[2 ..^ 1], # trim leading "sk", e.g. "skConst" -> "Const"
      }

    let structuredContent = %*{"syms": symbolsJson}

    McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: $structuredContent)],
      structuredContent: some structuredContent,
      isError: some false,
    )
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: some true,
    )

proc callNimListSymbols(
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

  if nimsuggest.isSome:
    let symbols = await nimsuggest.get.outline(path)

    var symbolsJson = newJArray()
    for symbol in symbols:
      symbolsJson.add %*{
        "name": symbol.name,
        "path": symbol.filePath,
        "line": symbol.line,
        "column": symbol.column,
        "kind": symbol.symkind[2 ..^ 1], # trim leading "sk"
      }

    let structuredContent = %*{"syms": symbolsJson}

    McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: $structuredContent)],
      structuredContent: some structuredContent,
      isError: some false,
    )
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: some true,
    )

proc callNimCheckProject(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.async.} =
  if len(ls.projectFiles) == 0:
    return McpCallToolResult(
      content:
        @[
          McpContentBlock(
            `type`: TextContent, text: "Tool works only in Nimble projects"
          )
        ],
      isError: some true,
    )

  let
    path = ls.projectFiles.keys.toSeq[0]
    uri = path.pathToUri()

  if uri notin ls.openFiles:
    await ls.didOpenFile(
      TextDocumentItem(uri: uri, languageId: "nim", version: 0, text: readFile(path))
    )

  let nimsuggest = await ls.tryGetNimsuggest(uri)

  if nimsuggest.isSome:
    let diagnostics = await nimsuggest.get.chk(path, path)

    var diagJson: seq[JsonNode]

    for diagnostic in diagnostics:
      # Diagnostics with path ??? are not related to the project
      if diagnostic.filePath != "???":
        diagJson.add %*{
          "path": diagnostic.filePath,
          "line": diagnostic.line,
          "column": diagnostic.column,
          "severity": diagnostic.forth,
          "message": diagnostic.doc,
        }

    # nimsuggest would return duplicate diagnostics
    # so we deduplicate them before returning
    let structuredContent = %*{"diags": deduplicate(diagJson)}

    McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: $structuredContent)],
      structuredContent: some structuredContent,
      isError: some false,
    )
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: some true,
    )

proc callNimCheckFile(
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

  if nimsuggest.isSome:
    # Calling `con` command before `chkFile`;
    # otherwise, no diagnostics would be listed
    # for files in directories outside of srcDir
    discard await nimsuggest.get.con(path, path, 0, 0)

    let diagnostics = await nimsuggest.get.chkFile(path)

    var diagJson: seq[JsonNode]

    for diagnostic in diagnostics:
      diagJson.add %*{
        "line": diagnostic.line,
        "column": diagnostic.column,
        "severity": diagnostic.forth,
        "message": diagnostic.doc,
      }

    # nimsuggest would return duplicate diagnostics
    # so we deduplicate them before returning
    let structuredContent = %*{"diags": deduplicate(diagJson)}

    McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: $structuredContent)],
      structuredContent: some structuredContent,
      isError: some false,
    )
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: some true,
    )

# Routes
proc initialize*(
    p: tuple[ls: LanguageServer, onExit: OnExitCallback], params: McpInitializeParams
): Future[McpInitializeResult] {.async.} =
  debug "Initialize received..."
  p.ls.mcpInitializeParams = params
  p.ls.mcpClientCapabilities = params.capabilities
  result = McpInitializeResult(
    protocolVersion: McpProtocolVersion,
    capabilities: McpServerCapabilities(tools: some(McpToolsOptions())),
    serverInfo:
      McpInitializeParams_serverInfo(name: "nimlangserver", version: LSPVersion),
  )
  debug "Initialize completed. Trying to start nimsuggest instances"
  let ls = p.ls
  ls.mcpServerCapabilities = result.capabilities
  let rootPath = getCurrentDir().pathToUri.uriToPath
  await ls.initNimsuggestInstances(rootPath)

proc listTools*(
    ls: LanguageServer, params: McpListToolsParams
): Future[McpListToolsResult] {.async.} =
  debug "Call tool received..."
  McpListToolsResult(
    tools:
      @[
        nimFindReferences(),
        nimFindSymbols(),
        nimListSymbols(),
        nimCheckProject(),
        nimCheckFile(),
      ]
  )

proc callTool*(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.async.} =
  debug "Call tool received...", name = params.name
  case params.name
  of "nimFindReferences":
    await callNimFindReferences(ls, params)
  of "nimFindSymbols":
    await callNimFindSymbols(ls, params)
  of "nimListSymbols":
    await callNimListSymbols(ls, params)
  of "nimCheckProject":
    await callNimCheckProject(ls, params)
  of "nimCheckFile":
    await callNimCheckFile(ls, params)
  else:
    McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: "Unknown tool")],
      isError: some true,
    )

# Notifications
proc initialized*(ls: LanguageServer, _: JsonNode) {.async.} =
  debug "Client initialized."
