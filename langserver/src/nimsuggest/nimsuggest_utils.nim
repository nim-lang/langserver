import std/[options, tables]
import chronos
import chronicles
import ../utils/utils
import ./[suggestapi_types, nimsuggest_types]
import ../protocol/types

proc mailboxHasQueryOfKind*(
  slot: NimsuggestSlot, 
  queryKind: NimsuggestQueryKind,
  uri: FileUri, 
): bool = 
  result = false
  for queueQuery in slot.queryMailbox.items():
    if queueQuery.kind == queryKind and queueQuery.uri == uri:
      return true

proc mailboxHasChangedQueryForSameUriAnyOtherUri*(
  slot: NimsuggestSlot, 
  uri: FileUri, 
): bool = 
  ## Checks if there is another KIND messages for the same URI later in the queue, but with no other KIND queries for other URIs in between.
  result = false
  for queueQuery in slot.queryMailbox.items():
    if queueQuery.kind == NimsuggestQueryKind.CHANGED:
      if queueQuery.uri == uri:
        return true
      else:
        return false

proc getFilePath*(s: Suggest): FilePath = s.filePath

proc toNimsuggestFilePosition*(
  position: LspFilePosition,
  uri: FileUri,
  openFiles: TableRef[FileUri, NlsFileInfo]
): Option[NimsuggestFilePosition] =
  # Finger tables are 0-based
  if uri in openFiles:
    if int(position.line) < openFiles[uri].fingerTable.len:
      let fingerTableLine = openFiles[uri].fingerTable[int(position.line)]
      let colValue = utf16to8(fingerTableLine, int(position.character))
      return some(
        NimsuggestFilePosition(
          line: int(position.line) + 1,
          col: colValue
        ))
    else:
      debug "toNimsuggestFilePosition: finger table is too short", uri = uri
  else:
    debug "toNimsuggestFilePosition: uri is not in openFiles", uri = uri
    return none(NimsuggestFilePosition)

proc toNimsuggestQuery*(
  q: NimsuggestQuery[LspFilePosition],
  openFiles: TableRef[FileUri, NlsFileInfo]
): Option[NimsuggestQuery[NimsuggestFilePosition]] =
  ## Converts a LSP-space query to a nimsuggest-space query, translating
  ## positions from (0-based line, UTF-16 col) to (1-based line, UTF-8 col)
  ## via the finger table in openFiles.
  ##
  ## The responseFuture is shared — not re-created — so any coroutine already
  ## awaiting q.responseFuture will observe the result when the converted query
  ## is completed by processNimsuggestQueries.
  ##
  ## Returns none if position conversion fails (URI not in openFiles, or line
  ## out of range). Always succeeds for position-less query kinds.
  case q.kind
  of NimsuggestQueryKind.SUGGEST,
    NimsuggestQueryKind.DEFINITION,
    NimsuggestQueryKind.DECLARATION,
    NimsuggestQueryKind.TYPE_DEFINITION,
    NimsuggestQueryKind.REFERENCES,
    NimsuggestQueryKind.HOVER,
    NimsuggestQueryKind.DOCUMENT_HIGHLIGHT,
    NimsuggestQueryKind.SIGNATURE_HELP:
    let posOpt = toNimsuggestFilePosition(q.position, q.uri, openFiles)
    if posOpt.isNone:
      debug "toNimsuggestQuery: toNimsuggestFilePosition failed."
      return none(NimsuggestQuery[NimsuggestFilePosition])
    # Two-step construction required: Nim disallows putting both a runtime
    # discriminant (kind: q.kind) and a variant field (position:) in the
    # same object constructor. Assign position after construction instead.
    var converted = NimsuggestQuery[NimsuggestFilePosition](
      id: q.id, 
      uri: q.uri, 
      dirtyFile: q.dirtyFile,
      responseFuture: q.responseFuture, 
      cancelled: q.cancelled,
      kind: q.kind,
    )
    converted.position = posOpt.get()
    return some(converted)
  of NimsuggestQueryKind.INLAY_HINTS:
    let startOpt = toNimsuggestFilePosition(q.inlayHints.start, q.uri, openFiles)
    let finishOpt = toNimsuggestFilePosition(q.inlayHints.finish, q.uri, openFiles)
    if startOpt.isNone or finishOpt.isNone:
      return none(NimsuggestQuery[NimsuggestFilePosition])
    return some(NimsuggestQuery[NimsuggestFilePosition](
      id: q.id, uri: q.uri, dirtyFile: q.dirtyFile,
      responseFuture: q.responseFuture, cancelled: q.cancelled,
      kind: NimsuggestQueryKind.INLAY_HINTS,
      inlayHints: (
        start: startOpt.get(),
        finish: finishOpt.get(),
        options: q.inlayHints.options,
      ),
    ))
  of NimsuggestQueryKind.EXPAND:
    let posOpt = toNimsuggestFilePosition(q.expand.position, q.uri, openFiles)
    if posOpt.isNone:
      return none(NimsuggestQuery[NimsuggestFilePosition])
    return some(NimsuggestQuery[NimsuggestFilePosition](
      id: q.id, uri: q.uri, dirtyFile: q.dirtyFile,
      responseFuture: q.responseFuture, cancelled: q.cancelled,
      kind: NimsuggestQueryKind.EXPAND,
      expand: (position: posOpt.get(), tag: q.expand.tag),
    ))
  of NimsuggestQueryKind.DOCUMENT_SYMBOLS,
    NimsuggestQueryKind.WORKSPACE_SYMBOLS,
    NimsuggestQueryKind.CHECK_FILE,
    NimsuggestQueryKind.CHECK_PROJECT,
    NimsuggestQueryKind.RECOMPILE,
    NimsuggestQueryKind.KNOWN:
    return some(NimsuggestQuery[NimsuggestFilePosition](
      id: q.id, uri: q.uri, dirtyFile: q.dirtyFile,
      responseFuture: q.responseFuture, cancelled: q.cancelled,
      kind: q.kind,
    ))
  of NimsuggestQueryKind.CHANGED:
    return some(NimsuggestQuery[NimsuggestFilePosition](
      id: q.id, uri: q.uri, dirtyFile: q.dirtyFile,
      responseFuture: q.responseFuture, 
      cancelled: q.cancelled,
      kind: NimsuggestQueryKind.CHANGED,
      saved: q.saved      
    ))

