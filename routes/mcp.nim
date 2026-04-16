import
  std/[os, sequtils, tables, json],
  pkg/[chronos, json_rpc/server, chronicles, json_serialization],
  ../[suggestapi, ls, utils],
  ../protocol/types

import macros except error

proc logToFile(msg: string) =
  var logFile = open("mcp.log", fmAppend)
  logFile.writeLine(msg)
  close(logFile)

# Routes
proc initialize*(
    p: tuple[ls: LanguageServer, onExit: OnExitCallback], params: McpInitializeParams
): Future[McpInitializeResult] {.async.} =
  logToFile("============================")
  logToFile("--== Started initialize ==--")

  proc onClientProcessExitAsync(): Future[void] {.async.} =
    debug "onClientProcessExitAsync"
    await p.ls.stopNimsuggestProcesses
    await p.onExit()

  proc onClientProcessExit() {.closure, gcsafe.} =
    try:
      debug "onClientProcessExit"
      waitFor onClientProcessExitAsync()
    except Exception:
      error "Error in onClientProcessExit ", msg = getCurrentExceptionMsg()

  debug "Initialize received..."
  logToFile "Initialize received..."
  p.ls.mcpInitializeParams = params
  p.ls.mcpClientCapabilities = params.capabilities
  result = McpInitializeResult(
    protocolVersion: "2025-11-25",
    capabilities: McpServerCapabilities(tools: some(McpToolsOptions())),
    serverInfo: McpInitializeParams_serverInfo(name: "nimlangserver", version: "1.12.0"),
  )
  logToFile "result = " & $(%*result)

  debug "Initialize completed. Trying to start nimsuggest instances"
  logToFile "Initialize completed. Trying to start nimsuggest instances"
  let ls = p.ls
  ls.mcpServerCapabilities = result.capabilities
  let rootPath = getCurrentDir().pathToUri.uriToPath
  logToFile "rootPath = " & $rootPath
  if rootPath != "":
    let nimbleFiles = walkFiles(rootPath / "*.nimble").toSeq
    logToFile "nimbleFiles = " & $nimbleFiles
    if nimbleFiles.len > 0:
      let nimbleFile = nimbleFiles[0]
      let nimbleDumpInfo = await ls.getNimbleDumpInfo(nimbleFile)
      logToFile "nimbleDumpInfo = " & $nimbleDumpInfo
      ls.entryPoints = nimbleDumpInfo.getNimbleEntryPoints(rootPath)
      logToFile "ls.entryPoints = " & $ls.entryPoints
      for entryPoint in ls.entryPoints:
        debug "Starting nimsuggest for entry point ", entry = entryPoint
        logToFile "Starting nimsuggest for entry point " & entryPoint
        if entryPoint notin ls.projectFiles:
          ls.createOrRestartNimsuggest(entryPoint)

proc listTools*(
    ls: LanguageServer, params: McpListToolsParams
): Future[McpListToolsResult] {.async.} =
  logToFile "--== List tools started ==--"
  logToFile "params = " & $(%*params)

  result = McpListToolsResult(
    tools:
      @[
        McpTool(
          name: "nimFindReferences",
          title: some "Find symbol references in .nim files",
          description:
            some "Find references of the symbol under cursor in the current workspace.",
          inputSchema: McpToolSchema(
            `type`: "object",
            properties: some %*{
              "path": {"type": "string"},
              "line": {"type": "integer"},
              "column": {"type": "integer"},
            },
            required: some @["path", "line", "column"],
          ),
          outputSchema: some McpToolSchema(
            `type`: "object",
            properties: some %*{
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
            required: some @["refs"],
          ),
        ),
        McpTool(
          name: "nimFindSymbols",
          title: some "Find symbols in .nim files",
          description: some "Find symbols matching the given search query in the current workspace.",
          inputSchema: McpToolSchema(
            `type`: "object",
            properties: some %*{"query": {"type": "string"}},
            required: some @["query"],
          ),
          outputSchema: some McpToolSchema(
            `type`: "object",
            properties: some %*{
              "syms": {
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
            required: some @["syms"],
          ),
        ),
      ]
  )

  logToFile "result = " & $(%*result)

  logToFile "List tools completed"

proc callTool*(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.async.} =
  logToFile "--== Call tool started ==--"

  let arguments = params.arguments.get(JsonNode())

  logToFile "params.name = " & params.name
  logToFile "arguments = " & $arguments

  result =
    case params.name
    of "nimFindReferences":
      let
        path = arguments["path"].getStr()
        uri = path.pathToUri()
        line = arguments["line"].getInt()
        column = arguments["column"].getInt()

      if uri notin ls.openFiles:
        await ls.didOpenFile(
          TextDocumentItem(
            uri: uri, languageId: "nim", version: 0, text: readFile(path)
          )
        )

      let nimsuggest = await ls.tryGetNimsuggest(uri)

      if nimsuggest.isSome:
        logToFile "nimsuggestPath = " & nimsuggest.get.nimsuggestPath
        logToFile "project.file = " & nimsuggest.get.project.file

        let references = await nimsuggest.get.use(path, path, line, column)

        var usageReferencesJson = newJArray()
        for reference in references:
          if reference.section == ideUse:
            usageReferencesJson.add %*{
              "path": reference.filePath,
              "line": reference.line,
              "column": reference.column,
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
    of "nimFindSymbols":
      let
        query = arguments["query"].getStr()
        path =
          if len(ls.projectFiles) > 0:
            ls.projectFiles.keys.toSeq[0]
          else:
            ""
        uri = path.pathToUri()

      if uri notin ls.openFiles:
        await ls.didOpenFile(
          TextDocumentItem(
            uri: uri, languageId: "nim", version: 0, text: readFile(path)
          )
        )
      # FIXME This should be implemented with ls.lastNimSuggest
      # but it is not assigned during initiallization and is therefore `nil`.
      # As as workaround, we "open" the first available projectFile
      # and use its nimsuggest instance.
      let nimsuggest = await ls.tryGetNimsuggest(uri)

      if nimsuggest.isSome:
        let symbols = await nimsuggest.get.globalSymbols(query)

        var symbolsJson = newJArray()
        for symbol in symbols:
          symbolsJson.add %*{
            "path": symbol.filePath, "line": symbol.line, "column": symbol.column
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
    else:
      McpCallToolResult(
        content: @[McpContentBlock(`type`: TextContent, text: "Unknown tool")],
        isError: some true,
      )

  logToFile "result = " & $(%*result)

# Notifications
proc initialized*(ls: LanguageServer, _: JsonNode) {.async.} =
  debug "Client initialized."
  logToFile "--== Client initialized ==--"
