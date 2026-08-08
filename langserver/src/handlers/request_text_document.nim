import std/[sugar, sequtils, tables, strformat, strscans, json, strutils]
import chronos
import chronos/asyncproc
import chronicles
import json_serialization
import with

import ../nimsuggest/[suggestapi, suggestapi_types, nimsuggest_types]
import ../nim_compiler/nim_expand
import ../nim_compiler/nim_compiler
import ../utils/utils as globalUtils
import ../configurations/[constants, configuration_types]
import ../langserver/[utils, langserver_types, langserver, configurations]
import ../protocol/types

import ./[handler_utils, queries_nimsuggest, queries_file_access]

# === textDocument/completion ===
proc processCompletionQuery(
  ls: LanguageServer, 
  q: NimsuggestQuery[LspFilePosition],
  nimsuggestResponse: seq[Suggest]
): seq[CompletionItem] = 
  result = nimsuggestResponse.map(toCompletionItem)
  if ls.capabilities.lspClientCapabilities.supportSignatureHelp() and nsCon in ls.nsCapabilities(q.uri):
    #show only unique overloads if we support signatureHelp
    var unique = initTable[string, CompletionItem]()
    for completion in result:
      if completion.label notin unique:
        unique[completion.label] = completion
    result = unique.values.toSeq

proc completion*(
  ls: LanguageServer, params: CompletionParams, id: int
): Future[seq[CompletionItem]] {.async.} =
  let query: NimsuggestQuery[LspFilePosition] = ls.initNimsuggestPositionQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.SUGGEST, 
    params.position.line,
    params.position.character
  )
  let response = await ls.addQueryToQueue(query)
  return processCompletionQuery(ls, query, response)

# === textDocument/definition ===
proc definition*(
  ls: LanguageServer, params: TextDocumentPositionParams, id: int
): Future[seq[Location]] {.async.} =
  let query: NimsuggestQuery[LspFilePosition] = ls.initNimsuggestPositionQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.DEFINITION, 
    params.position.line,
    params.position.character
  )
  let response = await ls.addQueryToQueue(query)
  return processLocationQuery(ls, response)

# === textDocument/declaration ===
proc declaration*(
  ls: LanguageServer, params: TextDocumentPositionParams, id: int
): Future[seq[Location]] {.async.} =
  let query: NimsuggestQuery[LspFilePosition] = ls.initNimsuggestPositionQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.DECLARATION, 
    params.position.line,
    params.position.character
  )
  let response = await ls.addQueryToQueue(query)
  return processLocationQuery(ls, response)

# === textDocument/typeDefinition ===
proc typeDefinition*(
  ls: LanguageServer, params: TextDocumentPositionParams, id: int
): Future[seq[Location]] {.async.} =
  let query: NimsuggestQuery[LspFilePosition] = ls.initNimsuggestPositionQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.TYPE_DEFINITION, 
    params.position.line,
    params.position.character
  )
  let response = await ls.addQueryToQueue(query)
  return processLocationQuery(ls, response)

# === textDocument/references ===
func processTypeDefinitionQuery(
  ls: LanguageServer,
  includeDeclaration: bool,
  nimsuggestResponse: seq[Suggest]
): seq[Location] =
  return nimsuggestResponse.filter(
    suggest => suggest.section != ideDef or includeDeclaration
  ).map(x => x.toUtf16Pos(ls).toLocation)

proc references*(
  ls: LanguageServer, params: ReferenceParams, id: int
): Future[seq[Location]] {.async.} =
  let query: NimsuggestQuery[LspFilePosition] = ls.initNimsuggestPositionQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.REFERENCES, 
    params.position.line,
    params.position.character
  )
  let response = await ls.addQueryToQueue(query)
  return processTypeDefinitionQuery(ls, params.context.includeDeclaration, response)

# === textDocument/hover ===
proc processHoverQuery(
  ls: LanguageServer,
  query: NimsuggestQuery[LspFilePosition],
  nimsuggestResponse: seq[Suggest]
): Future[Option[Hover]] {.async.} = 
  if nimsuggestResponse.len == 0:
    return none(Hover)
  
  var suggest = nimsuggestResponse[0]
  if suggest.symkind == "skModule": # NOTE: skMoudle always return position (1, 0)
    return some(Hover(contents: some(%toMarkupContent(suggest))))

  else:
    let config = ls.getWorkspaceConfiguration()
    # Convert cursor position from UTF-16 (LSP) to UTF-8 (nimsuggest) for column comparison.
    let utf8Col = ls.getCharacter(
      query.uri,
      int(query.position.line),
      int(query.position.character)
    ).get(int(query.position.character))
    for s in nimsuggestResponse:
      # s.line is 1-based (nimsuggest); query.position.line is 0-based (LSP).
      if s.line == int(query.position.line) + 1:
        # Both s.column and utf8Col are now UTF-8 byte offsets.
        if s.column <= utf8Col:
          suggest = s
        else:
          break

    var content = toMarkupContent(suggest)
    if suggest.symkind == "skMacro" and config.nimExpandMacro.get(NIM_EXPAND_MACRO_BY_DEFAULT):
      # Build a hover query at the macro definition site to fetch its doc string.
      # suggest.line is 1-based → convert to 0-based for LspFilePosition.
      # suggest.column is UTF-8 → convert to UTF-16 via fingerTable.
      let macroLine0 = suggest.line - 1
      let macroChar = toUtf16Pos(ls, query.uri, macroLine0, suggest.column).get(suggest.column)
      let expandedQuery = NimsuggestQuery[LspFilePosition](
        id: 0.uint,
        kind: NimsuggestQueryKind.HOVER,
        uri: query.uri,
        dirtyFile: ls.uriToStash(query.uri),
        responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
        position: LspFilePosition(
          line: Line0Based(macroLine0),
          character: Utf16Int(macroChar),
        ),
      )

      let expandedResponse = await ls.addQueryToQueue(expandedQuery)
      if expandedResponse.len > 0 and expandedResponse[0].doc != "":
        content.value.add &"```nim\n{expandedResponse[0].doc}\n```"
      else:
        let nimPath = config.getNimPath()
        if nimPath.isSome:
          let nimExpanded = await nimExpandMacro(nimPath.get, suggest, string(uriToPath(query.uri)))
          content.value.add &"```nim\n{nimExpanded}\n```"

    if suggest.section == ideDef and suggest.symkind in ["skProc"] and config.nimExpandArc.get(NIM_EXPAND_ARC_BY_DEFAULT):
      debug "#Expanding arc", suggest = suggest[]
      let nimPath = config.getNimPath()
      if nimPath.isSome:
        let expanded = await nimExpandArc(nimPath.get, suggest, string(uriToPath(query.uri)))
        let arcContent = "#Expanded arc \n" & expanded
        content.value.add &"```nim\n{arcContent}\n```"

    return some(Hover(
      contents: some(%content), range: some(toLabelRange(suggest.toUtf16Pos(ls)))
    ))

proc hover*(
  ls: LanguageServer, params: HoverParams, id: int
): Future[Option[Hover]] {.async.} =
  let query: NimsuggestQuery[LspFilePosition] = ls.initNimsuggestPositionQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.HOVER, 
    params.position.line,
    params.position.character
  )
  let response = await ls.addQueryToQueue(query)
  return await processHoverQuery(ls, query, response)

# === textDocument/documentHighlight ===
func toDocumentHighlight(suggest: Suggest): DocumentHighlight =
  return DocumentHighlight %* {"range": toLabelRange(suggest)}

func processDocumentHighlightQuery(
  ls: LanguageServer,
  nimsuggestResponse: seq[Suggest]
): seq[DocumentHighlight] =
  return nimsuggestResponse.map(x => x.toUtf16Pos(ls).toDocumentHighlight)

proc documentHighlight*(
  ls: LanguageServer, params: TextDocumentPositionParams, id: int
): Future[seq[DocumentHighlight]] {.async.} =
  let query: NimsuggestQuery[LspFilePosition] = ls.initNimsuggestPositionQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.DOCUMENT_HIGHLIGHT, 
    params.position.line,
    params.position.character
  )
  let response = await ls.addQueryToQueue(query)
  return processDocumentHighlightQuery(ls, response)

# === textDocument/signatureHelp ===
proc toSignatureInformation(suggest: Suggest): SignatureInformation =
  var fnKind, strParams: string
  var params = newSeq[ParameterInformation]()
  #TODO handle params. Ideally they are handled in the compiler but as fallback we could handle them as follows
  #notice we will need to also handle the  ',' and the back and forths between the client and the server
  if scanf(suggest.forth, "$*($*)", fnKind, strParams):
    for param in strParams.split(","):
      params.add(ParameterInformation(label: param))

  let name = suggest.qualifiedPath[^1].strip(chars = {'`'})
  let detail = suggest.forth.split(" ")
  var label = name
  if detail.len > 1:
    label = &"{fnKind} {name}({strParams})"
  return
    SignatureInformation %* {
      "label": label,
      "documentation": suggest.doc,
      "parameters": newSeq[ParameterInformation](), #notice params is not used
    }

proc processSignatureHelpQuery(
  ls: LanguageServer,
  query: NimsuggestQuery[LspFilePosition],
  nimsuggestResponse: seq[Suggest]
): Option[SignatureHelp] = 
  # nsCapabilities is valid now — slot is READY after addQueryToQueue returns
  if nsCon notin ls.nsCapabilities(query.uri):
    return none[SignatureHelp]()
  let signatures = nimsuggestResponse.map(toSignatureInformation)
  if signatures.len() > 0:
    return some SignatureHelp(
      signatures: some(signatures), activeSignature: some(0), activeParameter: some(0)
    )
  else:
    return none[SignatureHelp]()

proc signatureHelp*(
  ls: LanguageServer, params: SignatureHelpParams, id: int
): Future[Option[SignatureHelp]] {.async.} =
  if ls.capabilities.lspClientCapabilities.supportSignatureHelp():
    let query: NimsuggestQuery[LspFilePosition] = ls.initNimsuggestPositionQuery(
      id,
      params.textDocument.uri,
      NimsuggestQueryKind.SIGNATURE_HELP, 
      params.position.line,
      params.position.character
    )
    let response = await ls.addQueryToQueue(query)
    return processSignatureHelpQuery(ls, query, response)
  else:
    #Some clients doesnt support signatureHelp
    return none[SignatureHelp]()

# === textDocument/documentSymbol ===
proc toSymbolInformation*(suggest: Suggest): SymbolInformation =
  with suggest:
    return
      SymbolInformation %* {
        "location": toLocation(suggest),
        "kind": nimSymToLSPSymbolKind(suggest.symKind).int,
        "name": suggest.name,
      }

proc processDocumentSymbolQuery(
  ls: LanguageServer,
  nimsuggestResponse: seq[Suggest]
): seq[SymbolInformation] =
  return nimsuggestResponse.map(x => x.toUtf16Pos(ls).toSymbolInformation)

proc documentSymbols*(
    ls: LanguageServer, params: DocumentSymbolParams, id: int
): Future[seq[SymbolInformation]] {.async.} =
  let query = ls.initNimsuggestFileQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.DOCUMENT_SYMBOLS
  )
  let response = await ls.addQueryToQueue(query)
  return processDocumentSymbolQuery(ls, response)

# === textDocument/prepareRename ===
proc processPrepareRenameQuery(
  ls: LanguageServer,
  nimsuggestResponse: seq[Suggest]
): JsonNode =
  let projectDir = ls.capabilities.lspInitializeParams.getRootPath
  if nimsuggestResponse.len > 0 and string(nimsuggestResponse[0].filePath).isRelTo(projectDir):
    return %nimsuggestResponse[0].toLocation().range
  return newJNull()

proc prepareRename*(
  ls: LanguageServer, params: PrepareRenameParams, id: int
): Future[JsonNode] {.async.} =
  let query: NimsuggestQuery[LspFilePosition] = ls.initNimsuggestPositionQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.DEFINITION,
    params.position.line,
    params.position.character
  )
  let response = await ls.addQueryToQueue(query)
  return processPrepareRenameQuery(ls, response)

# === textDocument/rename ===
proc processRenameQuery(
  ls: LanguageServer,
  newName: string,
  nimsuggestResponse: seq[Suggest]
): WorkspaceEdit =
  # Build up list of edits that the client needs to perform for each file
  let projectDir = ls.capabilities.lspInitializeParams.getRootPath
  var edits = newJObject()
  for reference in nimsuggestResponse:
    # Only rename symbols in the project.
    # If client supports prepareRename then an error will already have been thrown
    let uri = pathToUri(reference.filePath)
    if string(reference.filePath).isRelTo(projectDir):
      if string(uri) notin edits:
        edits[string(uri)] = newJArray()
      edits[string(uri)] &= %TextEdit(range: reference.toLabelRange(), newText: newName)
  return WorkspaceEdit(changes: some edits)

proc rename*(
  ls: LanguageServer, params: RenameParams, id: int
): Future[WorkspaceEdit] {.async.} =
  # We reuse the references command as to not duplicate it
  let query: NimsuggestQuery[LspFilePosition] = ls.initNimsuggestPositionQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.REFERENCES,
    params.position.line,
    params.position.character
  )
  let response = await ls.addQueryToQueue(query)
  return processRenameQuery(ls, params.newName, response)


# === textDocument/inlayHint ====
proc convertInlayHintKind(kind: SuggestInlayHintKind): InlayHintKind_int =
  case kind
  of sihkType:
    result = 1
  of sihkParameter:
    result = 2
  of sihkException:
    # LSP doesn't have an exception inlay hint type, so we pretend (i.e. lie) that it is a type hint.
    result = 1

proc toInlayHint(suggest: SuggestInlayHint, configuration: NlsConfig): InlayHint =
  let hint_line = suggest.line - 1
  # suggest.column is already UTF-16 — callers apply toUtf16Pos before calling this proc.
  var hint_col = suggest.column
  var suggest = suggest
  if suggest.label.contains("Error Type"):
    suggest.label = ""
  result = InlayHint(
    position: Position(line: hint_line, character: hint_col),
    label: suggest.label,
    kind: some(convertInlayHintKind(suggest.kind)),
    paddingLeft: some(suggest.paddingLeft),
    paddingRight: some(suggest.paddingRight),
  )
  if suggest.kind == sihkException and suggest.label == "try " and
      configuration.inlayHints.isSome and
      configuration.inlayHints.get.exceptionHints.isSome and
      configuration.inlayHints.get.exceptionHints.get.hintStringLeft.isSome:
    result.label = configuration.inlayHints.get.exceptionHints.get.hintStringLeft.get
  if suggest.kind == sihkException and suggest.label == "!" and
      configuration.inlayHints.isSome and
      configuration.inlayHints.get.exceptionHints.isSome and
      configuration.inlayHints.get.exceptionHints.get.hintStringRight.isSome:
    result.label = configuration.inlayHints.get.exceptionHints.get.hintStringRight.get
  if suggest.tooltip != "":
    result.tooltip = some(suggest.tooltip)
  else:
    result.tooltip = some("")
  if suggest.allowInsert:
    result.textEdits = some(
      @[
        TextEdit(
          newText: suggest.label,
          `range`: Range(
            start: Position(line: hint_line, character: hint_col),
            `end`: Position(line: hint_line, character: hint_col),
          ),
        )
      ]
    )

proc processInlayHintQuery(
  ls: LanguageServer,
  uri: FileUri,
  nimsuggestResponse: seq[Suggest],
  configuration: NlsConfig,
  typeHintsEnabled: bool,
  exceptionHintsEnabled: bool,
  parameterHintsEnabled: bool,
): seq[InlayHint] =
  return nimsuggestResponse.filter(
    x => ((x.inlayHintInfo.kind == sihkType) and typeHintsEnabled) or ((x.inlayHintInfo.kind == sihkException) and exceptionHintsEnabled) or ((x.inlayHintInfo.kind == sihkParameter) and parameterHintsEnabled)
  ).map(x => x.inlayHintInfo.toUtf16Pos(ls, uri).toInlayHint(configuration)
  ).filter(x => x.label != "")

proc inlayHint*(
  ls: LanguageServer, params: InlayHintParams, id: int
): Future[seq[InlayHint]] {.async.} =
  debug "inlayHint received..."
  let configuration = ls.getWorkspaceConfiguration()
  if configuration.inlayHints.isNone:
    debug "inlayHints not enabled in configuration"
    return @[]

  let query = ls.initNimsuggestInlayHintQuery(
    id, 
    params.textDocument.uri,
    params.`range`.start.line,
    params.`range`.start.character,
    params.`range`.`end`.line,
    params.`range`.`end`.character,
    " +exceptionHints +parameterHints",
  )
  let response = await ls.addQueryToQueue(query)
  # nsProtocolVersion is valid now — slot is READY after queryInlayHints returns
  if ls.nsProtocolVersion(params.textDocument.uri) < 4:
    return @[]

  let inlayHintsCfg = configuration.inlayHints.get()
  return processInlayHintQuery(
    ls, params.textDocument.uri,
    response,
    configuration,
    inlayHintsCfg.typeHints.isSome and inlayHintsCfg.typeHints.get().enable.get(true),
    inlayHintsCfg.exceptionHints.isSome and inlayHintsCfg.exceptionHints.get().enable.get(true),
    inlayHintsCfg.parameterHints.isSome and inlayHintsCfg.parameterHints.get().enable.get(true),
  )

# === textDocument/codeAction ===
proc codeAction*(
  ls: LanguageServer, params: CodeActionParams
): Future[seq[CodeAction]] {.async.} =
  let uri = params.textDocument.uri
  let fileInfo = ls.files.openFiles.getOrDefault(uri)
  let projectUri =
    if fileInfo != nil:
      fileInfo.slot.projectFile.pathToUri
    else:
      uri
  return
    seq[CodeAction] %* [
      {
        "title": "Clean build",
        "kind": "source",
        "command": {
          "title": "Clean build",
          "command": RECOMPILE_COMMAND,
          "arguments": @[projectUri],
        },
      },
      {
        "title": "Refresh project errors",
        "kind": "source",
        "command": {
          "title": "Refresh project errors",
          "command": CHECK_PROJECT_COMMAND,
          "arguments": @[projectUri],
        },
      },
      {
        "title": "Restart nimsuggest",
        "kind": "source",
        "command": {
          "title": "Restart nimsuggest",
          "command": RESTART_COMMAND,
          "arguments": @[projectUri],
        },
      },
    ]

# === textDocument/formatting ===
proc formatting*(
  ls: LanguageServer, params: DocumentFormattingParams, id: int
): Future[seq[TextEdit]] {.async.} =
  return await ls.addFormattingQueryToQueue(params)
