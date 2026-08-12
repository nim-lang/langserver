import std/[sugar, sequtils, tables, strformat, strscans, json, strutils, parsejson, sets]
import chronos
import chronos/asyncproc
import chronicles
import json_serialization

import ../nim_compiler/nim_expand
import ../nim_compiler/nim_compiler
import ../nimsuggest/nimsuggest
import ../langserver/langserver
import ../configurations/configurations
import ../utils/utils
import ../protocol/types

import ./[handler_utils, queries_nimsuggest, queries_file_access]

# === textDocument/completion ===
proc toCompletionItem(suggest: Suggest): CompletionItem =
  return
    CompletionItem %* { 
      "label": suggest.qualifiedPath[^1].strip(chars = {'`'}), 
      "kind": nimSymToLSPKind(suggest).int,
      "documentation": suggest.doc,
      "detail": nimSymDetails(suggest),
    }

proc supportSignatureHelp*(cc: LspClientCapabilities): bool =
  if cc.isNil:
    return false
  let caps = cc.textDocument
  caps.isSome and caps.get.signatureHelp.isSome


proc nsCapabilities*(ls: LanguageServer, uri: FileUri): set[NimSuggestCapability] =
  ## Returns the live nimsuggest capabilities for the slot serving `uri`.
  ## Safe to call synchronously after queryAt/queryFile returns — by that point
  ## processQueries has already awaited slot.ns.get so the slot is READY.
  let slotOpt = resolvedSlot(ls.pool, ls.files.openFiles, uri)
  if slotOpt.isNone:
    return {}
  let nsOpt = slotOpt.get.resolvedNs
  if nsOpt.isNone:
    return {}
  nsOpt.get.capabilities

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
    result = unique.values.toSeq()

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
  return processLocationResponsesForAnyFile(response, ls)

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
  return processLocationResponsesForAnyFile(response, ls)

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
  return processLocationResponsesForAnyFile(response, ls)

# === textDocument/references ===
proc processTypeDefinitionQuery(
  ls: LanguageServer,
  includeDeclaration: bool,
  nimsuggestResponse: seq[Suggest]
): seq[Location] =
  let filteredResponses = nimsuggestResponse.filter(
    suggest => suggest.section != ideDef or includeDeclaration
  )
  return processLocationResponsesForAnyFile(filteredResponses, ls)

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
    let config = ls.configurations.currentConfig
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
    if suggest.symkind == "skMacro" and config.nimExpandMacro:
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
        let nimPath = getNimPath(config)
        if nimPath.isSome:
          let nimExpanded = await nimExpandMacro(nimPath.get, suggest, string(uriToPath(query.uri)))
          content.value.add &"```nim\n{nimExpanded}\n```"

    if suggest.section == ideDef and suggest.symkind in ["skProc"] and config.nimExpandArc:
      debug "#Expanding arc", suggest = suggest[]
      let nimPath = getNimPath(config)
      if nimPath.isSome:
        let expanded = await nimExpandArc(nimPath.get, suggest, string(uriToPath(query.uri)))
        let arcContent = "#Expanded arc \n" & expanded
        content.value.add &"```nim\n{arcContent}\n```"

    return some(Hover(
      contents: some(%content), 
      `range`: some(initLabelRangeForAnyFile(suggest, ls))
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
proc processDocumentHighlightResponses(
  nimsuggestResponses: seq[Suggest],
  ls: LanguageServer,
): seq[DocumentHighlight] =
  result = @[]
  var seen: HashSet[tuple[line: int, col: int, section: IdeCmd]]
  for response in nimsuggestResponses:
    let pos = (response.line, response.column, response.section)
    if pos in seen: continue
    let documentHighlightJson = DocumentHighlight %* {
      "range": initLabelRangeForAnyFile(response, ls),
      "kind": 1  # DocumentHighlightKind.Text
    }
    seen.incl(pos)
    result.add(documentHighlightJson)      

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
  debug "documentHighlight: RESPONSES START"
  for r in response:
    debug "documentHighlight: suggest response", jsonOutput = $(%*r)

  let processedResponses = processDocumentHighlightResponses(response, ls)

  for r in processedResponses:
    debug "documentHighlight: json response", jsonOutput = $(%*r)
  debug "documentHighlight: RESPONSES END"
  return processedResponses

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
proc processDocumentSymbolResponses*(
  nimsuggestResponses: seq[Suggest],
  ls: LanguageServer,
): seq[SymbolInformation] =
  result = @[]
  for response in nimsuggestResponses:
    let uri = pathToUri(response.filepath)
    let labelRange = initLabelRangeForAnyFile(response, ls)
    let locationJson = Location %* {
      "uri": uri, 
      "range": labelRange
    }
    let symbolInformationJson = SymbolInformation %* {
      "location": locationJson,
      "kind": nimSymToLSPSymbolKind(response.symKind).int,
      "name": response.name,
    }
    result.add(symbolInformationJson)  


# proc processDocumentSymbolQuery(
#   ls: LanguageServer,
#   nimsuggestResponse: seq[Suggest]
# ): seq[SymbolInformation] =
#   return nimsuggestResponse.map(x => x.toUtf16Pos(ls).toSymbolInformation)

proc documentSymbols*(
    ls: LanguageServer, params: DocumentSymbolParams, id: int
): Future[seq[SymbolInformation]] {.async.} =
  let query = ls.initNimsuggestFileQuery(
    id,
    params.textDocument.uri,
    NimsuggestQueryKind.DOCUMENT_SYMBOLS
  )
  let response = await ls.addQueryToQueue(query)
  return processDocumentSymbolResponses(response, ls)

# === textDocument/prepareRename ===
proc processPrepareRenameQuery(
  ls: LanguageServer,
  nimsuggestResponse: seq[Suggest]
): JsonNode =
  let projectDir = ls.capabilities.lspInitializeParams.getRootPath
  if nimsuggestResponse.len > 0 and string(nimsuggestResponse[0].filePath).isRelTo(projectDir):
    let locationJson = toLocationJsonForAnyFile(
      nimsuggestResponse[0], ls
    )
    return %locationJson.range
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

      edits[string(uri)] &= %TextEdit(
        `range`: initLabelRangeForAnyFile(reference, ls), 
        newText: newName
      )
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

func getInlayHintLabel(
  inlayLabel: string,
  inlayKind: SuggestInlayHintKind,
  inlayHintsCfg: NlsInlayHintsConfig
): string = 
  result = inlayLabel
  if inlayLabel.contains("Error Type"): 
    result = ""

  if inlayKind == sihkException and inlayLabel == "try " and inlayHintsCfg.exceptionHints.enable:
    result = inlayHintsCfg.exceptionHints.hintStringLeft

  if inlayKind == sihkException and inlayLabel == "!" and inlayHintsCfg.exceptionHints.enable:
    result = inlayHintsCfg.exceptionHints.hintStringRight

proc processInlayHintResponses(
  nimsuggestResponses: seq[Suggest],
  uri: FileUri,
  ls: LanguageServer,
  inlayHintsCfg: NlsInlayHintsConfig
): seq[InlayHint] =
  var typeHintsEnabled = inlayHintsCfg.typeHints.enable
  var parameterHintsEnabled = inlayHintsCfg.parameterHints.enable
  var exceptionHintsEnabled = inlayHintsCfg.exceptionHints.enable

  for response in nimsuggestResponses:
    let showHint = (response.inlayHintInfo.kind == sihkType) and typeHintsEnabled
    let showException = (response.inlayHintInfo.kind == sihkException) and exceptionHintsEnabled
    let showParameter = (response.inlayHintInfo.kind == sihkParameter) and parameterHintsEnabled

    if showHint or showException or showParameter:
      let asLspFilePosition = toLspFilePosition(
        NimsuggestFilePosition(
          line: response.inlayHintInfo.line,
          col: response.inlayHintInfo.column
        ),
        uri,
        ls.files.openFiles
      )

      if asLspFilePosition.isSome:
        let pos = asLspFilePosition.get()
        let label = getInlayHintLabel(response.inlayHintInfo.label, response.inlayHintInfo.kind, inlayHintsCfg)
        if label != "":
          var outputHint = InlayHint(
            position: Position(line: int(pos.line), character: int(pos.character)),
            label: label,
            kind: some(convertInlayHintKind(response.inlayHintInfo.kind)),
            tooltip: if response.inlayHintInfo.tooltip != "": some(response.inlayHintInfo.tooltip) else: some(""),
            paddingLeft: some(response.inlayHintInfo.paddingLeft),
            paddingRight: some(response.inlayHintInfo.paddingRight), 
            textEdits: none(seq[TextEdit])
          )

          if response.inlayHintInfo.allowInsert:
            outputHint.textEdits = some(
              @[
                TextEdit(
                  newText: response.inlayHintInfo.label,
                  `range`: Range(
                    start: Position(line: int(pos.line), character: int(pos.character)),
                    `end`: Position(line: int(pos.line), character: int(pos.character)),
                  ),
                )
              ]
            )
          result.add(outputHint)

proc inlayHint*(
  ls: LanguageServer, 
  params: InlayHintParams, 
  id: int
): Future[seq[InlayHint]] {.async.} =
  debug "inlayHint received..."
  let configuration = ls.configurations.currentConfig

  let query = ls.initNimsuggestInlayHintQuery(
    id, 
    params.textDocument.uri,
    params.`range`.start.line,
    params.`range`.start.character,
    params.`range`.`end`.line,
    params.`range`.`end`.character,
    " +exceptionHints +parameterHints",
  )
  let responses = await ls.addQueryToQueue(query)
  # nsProtocolVersion is valid now — slot is READY after queryInlayHints returns
  let protocolVersion = nsProtocolVersion(
    ls.pool, ls.files.openFiles, params.textDocument.uri
  )
  if protocolVersion < 4:
    return @[]

  return processInlayHintResponses(
    responses, params.textDocument.uri,
    ls, configuration.inlayHints,
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
          "command": "nimtortoise.recompile",
          "arguments": @[projectUri],
        },
      },
      {
        "title": "Refresh project errors",
        "kind": "source",
        "command": {
          "title": "Refresh project errors",
          "command": "nimtortoise.checkProject",
          "arguments": @[projectUri],
        },
      },
      {
        "title": "Restart nimsuggest",
        "kind": "source",
        "command": {
          "title": "Restart nimsuggest",
          "command": "nimtortoise.restart",
          "arguments": @[projectUri],
        },
      },
    ]

# === textDocument/formatting ===
proc formatting*(
  ls: LanguageServer, params: DocumentFormattingParams, id: int
): Future[seq[TextEdit]] {.async.} =
  return await ls.addFormattingQueryToQueue(params)
