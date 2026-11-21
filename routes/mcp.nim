{.push raises: [], gcsafe.}

import
  std/[os, sequtils, tables, json],
  chronos,
  chronos/asyncproc,
  json_rpc/[errors, server],
  chronicles,
  json_serialization,
  ../[suggestapi, trackapi, ls, utils],
  ../protocol/[enums, types]

const McpProtocolVersion* = "2025-11-25"

# Tool definitions

const
  StringSchema = JsonString("""{"type": "string"}""")
  IntegerSchema = JsonString("""{"type": "integer"}""")
  UriSchema = JsonString("""{"type": "string", "format": "uri"}""")

proc nimFindReferences(): McpTool =
  McpTool(
    name: "nimFindReferences",
    title: "Find symbol references in .nim files",
    description: "Find references of the symbol under cursor in the current workspace.",
    inputSchema: McpToolSchema(
      `type`: "object",
      properties: some {
        "path": StringSchema, "line": IntegerSchema, "column": IntegerSchema
      }.toOrderedTable,
      required: some @["path", "line", "column"],
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties: some {
        "refs": JsonString(
          """{"type": "array", "items": {"type": "object", "properties": {"path": {"type": "string"}, "line": {"type": "integer"}, "column": {"type": "integer"}}, "required": ["path", "line", "column"]}}"""
        )
      }.toOrderedTable,
      required: some @["refs"],
    ),
  )

proc nimFindSymbols(): McpTool =
  McpTool(
    name: "nimFindSymbols",
    title: "Find symbols in .nim files",
    description:
      "Find symbols matching the given search query in the project of the given .nim file URI.",
    inputSchema: McpToolSchema(
      `type`: "object",
      properties: some {"uri": UriSchema, "query": StringSchema}.toOrderedTable,
      required: some @["uri", "query"],
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties: some {
        "syms": JsonString(
          """{"type": "array", "items": {"type": "object", "properties": {"path": {"type": "string"}, "line": {"type": "integer"}, "column": {"type": "integer"}, "kind": {"type": "string"}}, "required": ["path", "line", "column", "kind"]}}"""
        )
      }.toOrderedTable,
      required: some @["syms"],
    ),
  )

proc nimListSymbols(): McpTool =
  McpTool(
    name: "nimListSymbols",
    title: "List symbols in a .nim file",
    description: "List all symbols in the given .nim file.",
    inputSchema: McpToolSchema(
      `type`: "object",
      properties: some {"path": StringSchema}.toOrderedTable,
      required: some @["path"],
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties: some {
        "syms": JsonString(
          """{"type": "array", "items": {"type": "object", "properties": {"name": {"type": "string"}, "line": {"type": "integer"}, "column": {"type": "integer"}, "kind": {"type": "string"}}, "required": ["name", "line", "column", "kind"]}}"""
        )
      }.toOrderedTable,
      required: some @["syms"],
    ),
  )

proc nimCheckProject(): McpTool =
  McpTool(
    name: "nimCheckProject",
    title: "Check a project",
    description:
      "Get diagnostics (errors, warnings, and hints) for the project of the given .nim file URI.",
    inputSchema: McpToolSchema(
      `type`: "object",
      properties: some {"uri": UriSchema}.toOrderedTable,
      required: some @["uri"],
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties: some {
        "diags": JsonString(
          """{"type": "array", "items": {"type": "object", "properties": {"path": {"type": "string"}, "line": {"type": "integer"}, "column": {"type": "integer"}, "severity": {"type": "string"}, "message": {"type": "string"}}, "required": ["path", "line", "column", "severity", "message"]}}"""
        )
      }.toOrderedTable,
      required: some @["diags"],
    ),
  )

proc nimCheckFile(): McpTool =
  McpTool(
    name: "nimCheckFile",
    title: "Check a .nim file",
    description: "Get diagnostics (errors, warnings, and hints) for a given .nim file.",
    inputSchema: McpToolSchema(
      `type`: "object",
      properties: some {"path": StringSchema}.toOrderedTable,
      required: some @["path"],
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties: some {
        "diags": JsonString(
          """{"type": "array", "items": {"type": "object", "properties": {"line": {"type": "integer"}, "column": {"type": "integer"}, "severity": {"type": "string"}, "message": {"type": "string"}}, "required": ["line", "column", "severity", "message"]}}"""
        )
      }.toOrderedTable,
      required: some @["diags"],
    ),
  )

proc nimFindTypeDefinition(): McpTool =
  McpTool(
    name: "nimFindTypeDefinition",
    title: "Find type definition in .nim files",
    description:
      "Find the type definition of the symbol under cursor in the current workspace.",
    inputSchema: McpToolSchema(
      `type`: "object",
      properties: some {
        "path": StringSchema, "line": IntegerSchema, "column": IntegerSchema
      }.toOrderedTable,
      required: some @["path", "line", "column"],
    ),
    outputSchema: some McpToolSchema(
      `type`: "object",
      properties: some {
        "defs": JsonString(
          """{"type": "array", "items": {"type": "object", "properties": {"path": {"type": "string"}, "line": {"type": "integer"}, "column": {"type": "integer"}, "name": {"type": "string"}, "type": {"type": "string"}, "kind": {"type": "string"}}, "required": ["path", "line", "column", "name", "type", "kind"]}}"""
        )
      }.toOrderedTable,
      required: some @["defs"],
    ),
  )

# Tool calls

proc toolErrorResult(text: string): McpCallToolResult =
  McpCallToolResult(
    content: @[McpContentBlock(`type`: TextContent, text: text)], isError: true
  )

type
  PositionArguments = object
    path: string
    line: int
    column: int

  PathArguments = object
    path: string

  UriArguments = object
    uri: string

  FindSymbolsArguments = object
    uri: string
    query: string

LspJson.useDefaultReaderFor(PositionArguments)
LspJson.useDefaultReaderFor(PathArguments)
LspJson.useDefaultReaderFor(UriArguments)
LspJson.useDefaultReaderFor(FindSymbolsArguments)

type
  ReferenceOutput = object
    path: string
    line: int
    column: int

  ReferencesOutput = object
    refs: seq[ReferenceOutput]

  SymbolOutput = object
    path: string
    line: int
    column: int
    kind: string

  SymbolsOutput = object
    syms: seq[SymbolOutput]

  ListedSymbolOutput = object
    name: string
    path: string
    line: int
    column: int
    kind: string

  ListedSymbolsOutput = object
    syms: seq[ListedSymbolOutput]

  ProjectDiagnosticOutput = object
    path: string
    line: int
    column: int
    severity: string
    message: string

  ProjectDiagnosticsOutput = object
    diags: seq[ProjectDiagnosticOutput]

  FileDiagnosticOutput = object
    line: int
    column: int
    severity: string
    message: string

  FileDiagnosticsOutput = object
    diags: seq[FileDiagnosticOutput]

  TypeDefinitionOutput = object
    path: string
    line: int
    column: int
    name: string
    `type`: string
    kind: string

  TypeDefinitionsOutput = object
    defs: seq[TypeDefinitionOutput]

LspJson.useDefaultWriterFor(ReferenceOutput)
LspJson.useDefaultWriterFor(ReferencesOutput)
LspJson.useDefaultWriterFor(SymbolOutput)
LspJson.useDefaultWriterFor(SymbolsOutput)
LspJson.useDefaultWriterFor(ListedSymbolOutput)
LspJson.useDefaultWriterFor(ListedSymbolsOutput)
LspJson.useDefaultWriterFor(ProjectDiagnosticOutput)
LspJson.useDefaultWriterFor(ProjectDiagnosticsOutput)
LspJson.useDefaultWriterFor(FileDiagnosticOutput)
LspJson.useDefaultWriterFor(FileDiagnosticsOutput)
LspJson.useDefaultWriterFor(TypeDefinitionOutput)
LspJson.useDefaultWriterFor(TypeDefinitionsOutput)

proc toolResult[T](output: T): McpCallToolResult =
  let json = LspJson.encode(output)
  McpCallToolResult(
    content: @[McpContentBlock(`type`: TextContent, text: json)],
    structuredContent: some JsonString(json),
    isError: false,
  )

proc decodeArguments(params: McpCallToolParams, T: typedesc): Result[T, string] =
  try:
    ok LspJson.decode(params.arguments.get(JsonString("{}")).string, T)
  except SerializationError as ex:
    err "Invalid arguments: " & ex.msg

proc fileUriArgument(uri: string): Option[Path] =
  try:
    some DocumentUri(uri).uriToPath
  except UriParseError:
    none Path

proc callNimFindReferences(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.
    async: (
      raises: [
        CancelledError, ValueError, OSError, IOError, RegexError, AsyncProcessError,
        NimsuggestError,
      ]
    )
.} =
  let arguments = params.decodeArguments(PositionArguments).valueOr:
    return toolErrorResult(error)
  let
    path = arguments.path.absolutePath.normalizedPath.Path
    line = arguments.line
    column = arguments.column

  let config = await ls.workspaceConfigurationWait()

  if config.useNimTrack.get(false):
    let projectFile = await ls.getProjectFile(path)
    let timeout = config.timeout.get(REQUEST_TIMEOUT)
    let workingDir = await ls.getWorkingDir(projectFile)
    let nimPath = await ls.getNimPath(config, projectFile)
    if nimPath.isNone:
      return McpCallToolResult(
        content: @[McpContentBlock(`type`: TextContent, text: "Nim not found")],
        isError: true,
      )
    let refs = await track(
      projectFile,
      path,
      line,
      column,
      tmUsages,
      nimPath = nimPath.get,
      workingDir = workingDir,
      timeout = timeout,
    )

    var output: ReferencesOutput
    for reference in refs:
      output.refs.add ReferenceOutput(
        path: reference.filePath.string, line: reference.line, column: reference.column
      )
    return toolResult(output)

  let nimsuggest = await ls.getNimsuggest(path)

  if nimsuggest.isSome:
    let references = await nimsuggest.get.use(path, path, line, column)

    var output: ReferencesOutput
    for reference in references:
      if reference.section == ideUse:
        output.refs.add ReferenceOutput(
          path: reference.filePath.string,
          line: reference.line,
          column: reference.column,
        )
    toolResult(output)
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: true,
    )

proc callNimFindSymbols(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.
    async: (
      raises: [CancelledError, KeyError, OSError, IOError, RegexError, NimsuggestError]
    )
.} =
  let arguments = params.decodeArguments(FindSymbolsArguments).valueOr:
    return toolErrorResult(error)
  let path = arguments.uri.fileUriArgument()
  if path.isNone:
    return toolErrorResult("Argument uri must be a file URI")
  if path.get.splitFile.ext != ".nim":
    return toolErrorResult("Argument uri must be a .nim file")
  if not fileExists(path.get.string):
    return toolErrorResult("Argument uri must be an existing .nim file")

  let query = arguments.query
  let nimsuggest = await ls.getNimsuggest(path.get)

  if nimsuggest.isSome:
    let symbols = await nimsuggest.get.globalSymbols(query)
    var output: SymbolsOutput
    for symbol in symbols:
      output.syms.add SymbolOutput(
        path: symbol.filePath.string,
        line: symbol.line,
        column: symbol.column,
        kind: symbol.symkind[2 ..^ 1], # trim leading "sk", e.g. "skConst" -> "Const"
      )
    toolResult(output)
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: true,
    )

proc callNimListSymbols(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.
    async: (
      raises:
        [CancelledError, ValueError, OSError, IOError, RegexError, NimsuggestError]
    )
.} =
  let arguments = params.decodeArguments(PathArguments).valueOr:
    return toolErrorResult(error)
  let path = arguments.path.absolutePath.normalizedPath.Path

  let nimsuggest = await ls.getNimsuggest(path)

  if nimsuggest.isSome:
    let symbols = await nimsuggest.get.outlineFile(path)

    var output: ListedSymbolsOutput
    for symbol in symbols:
      output.syms.add ListedSymbolOutput(
        name: symbol.name,
        path: symbol.filePath.string,
        line: symbol.line,
        column: symbol.column,
        kind: symbol.symkind[2 ..^ 1], # trim leading "sk"
      )
    toolResult(output)
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: true,
    )

proc callNimCheckProject(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.
    async: (
      raises:
        [CancelledError, ValueError, OSError, IOError, RegexError, NimsuggestError]
    )
.} =
  let arguments = params.decodeArguments(UriArguments).valueOr:
    return toolErrorResult(error)
  let path = arguments.uri.fileUriArgument()
  if path.isNone:
    return toolErrorResult("Argument uri must be a file URI")
  if path.get.splitFile.ext != ".nim":
    return toolErrorResult("Argument uri must be a .nim file")
  if not fileExists(path.get.string):
    return toolErrorResult("Argument uri must be an existing .nim file")

  let projectFile = await ls.getProjectFile(path.get)
  let nimsuggest = await ls.getNimsuggest(path.get)

  if nimsuggest.isSome:
    let diagnostics = await nimsuggest.get.chk(projectFile, projectFile)
    var diags: seq[ProjectDiagnosticOutput]
    for diagnostic in diagnostics:
      # Diagnostics with path ??? are not related to the project
      if diagnostic.filePath.string != "???":
        diags.add ProjectDiagnosticOutput(
          path: diagnostic.filePath.string,
          line: diagnostic.line,
          column: diagnostic.column,
          severity: diagnostic.forth,
          message: diagnostic.doc,
        )

    # nimsuggest would return duplicate diagnostics
    # so we deduplicate them before returning
    toolResult(ProjectDiagnosticsOutput(diags: deduplicate(diags)))
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: true,
    )

proc callNimCheckFile(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.
    async: (
      raises:
        [CancelledError, ValueError, OSError, IOError, RegexError, NimsuggestError]
    )
.} =
  let arguments = params.decodeArguments(PathArguments).valueOr:
    return toolErrorResult(error)
  let path = arguments.path.absolutePath.normalizedPath.Path

  let nimsuggest = await ls.getNimsuggest(path)

  if nimsuggest.isSome:
    # Calling `con` command before `chkFile`;
    # otherwise, no diagnostics would be listed
    # for files in directories outside of srcDir
    discard await nimsuggest.get.con(path, path, 0, 0)

    let diagnostics = await nimsuggest.get.chkFile(path)

    var diags: seq[FileDiagnosticOutput]
    for diagnostic in diagnostics:
      diags.add FileDiagnosticOutput(
        line: diagnostic.line,
        column: diagnostic.column,
        severity: diagnostic.forth,
        message: diagnostic.doc,
      )

    # nimsuggest would return duplicate diagnostics
    # so we deduplicate them before returning
    toolResult(FileDiagnosticsOutput(diags: deduplicate(diags)))
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: true,
    )

proc callNimFindTypeDefinition(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.
    async: (
      raises:
        [CancelledError, ValueError, OSError, IOError, RegexError, NimsuggestError]
    )
.} =
  let arguments = params.decodeArguments(PositionArguments).valueOr:
    return toolErrorResult(error)
  let
    path = arguments.path.absolutePath.normalizedPath.Path
    line = arguments.line
    column = arguments.column

  let nimsuggest = await ls.getNimsuggest(path)

  if nimsuggest.isSome:
    let typeDefs = await nimsuggest.get.`type`(path, path, line, column)

    var output: TypeDefinitionsOutput
    for td in typeDefs:
      output.defs.add TypeDefinitionOutput(
        path: td.filePath.string,
        line: td.line,
        column: td.column,
        name: td.name,
        `type`: td.forth,
        kind: td.symkind[2 ..^ 1],
      )
    toolResult(output)
  else:
    McpCallToolResult(
      content:
        @[McpContentBlock(`type`: TextContent, text: "Nimsuggest is unavailable")],
      isError: true,
    )

# Routes
proc initialize*(
    p: tuple[ls: LanguageServer, onExit: OnExitCallback], params: McpInitializeParams
): Future[McpInitializeResult] {.async: (raises: [OSError]).} =
  debug "Initialize received..."
  p.ls.mcpInitializeParams = params
  p.ls.workspaceFolders = @[paths.getCurrentDir()]
  p.ls.mcpClientCapabilities = params.capabilities
  result = McpInitializeResult(
    protocolVersion: McpProtocolVersion,
    capabilities: McpServerCapabilities(tools: McpToolsOptions()),
    serverInfo:
      McpInitializeParams_serverInfo(name: "nimlangserver", version: LSPVersion),
  )
  debug "Initialize completed."

  let ls = p.ls
  ls.mcpServerCapabilities = result.capabilities
  #MCP clients have no settings for us
  ls.setWorkspaceConfiguration(newJArray())
  ls.initialized = true

proc listTools*(
    ls: LanguageServer, params: McpListToolsParams
): Future[McpListToolsResult] {.async: (raises: [ApplicationError]).} =
  ls.checkInitialized()
  debug "Call tool received..."
  McpListToolsResult(
    tools: @[
      nimFindReferences(),
      nimFindSymbols(),
      nimListSymbols(),
      nimCheckProject(),
      nimCheckFile(),
      nimFindTypeDefinition(),
    ]
  )

proc callTool*(
    ls: LanguageServer, params: McpCallToolParams
): Future[McpCallToolResult] {.
    async: (
      raises: [
        ApplicationError, CancelledError, ValueError, OSError, IOError, RegexError,
        AsyncProcessError, NimsuggestError,
      ]
    )
.} =
  ls.checkInitialized()
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
  of "nimFindTypeDefinition":
    await callNimFindTypeDefinition(ls, params)
  else:
    raise (ref ApplicationError)(
      code: ErrorCode.InvalidParams.int, msg: "Unknown tool: " & params.name
    )

# Notifications
proc initialized*(
    ls: LanguageServer, _: JsonNode
) {.async: (raises: [ApplicationError]).} =
  ls.checkInitialized()
  debug "Client initialized."
