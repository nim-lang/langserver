import chronos
import ../nimsuggest/[nimsuggest_types, suggestapi_types]
import ../langserver/langserver

# === NIMSUGGEST QUERIES ===
proc initNimsuggestPositionQuery*(
  ls: LanguageServer,
  id: int,
  uri: FileUri,
  kind: NimsuggestQueryKind,
  line, character: int,
): NimsuggestQuery[LspFilePosition] =
  ## Create a position-based query (hover, definition, completion, …).
  ## line is 0-based (LSP convention); converted to 1-based for nimsuggest internally.
  ## The dirtyFile is resolved automatically from the stash.
  ls.addProjectFileToPendingRequest(id.uint, uri)
  var q = NimsuggestQuery[LspFilePosition](
    id: id.uint,
    kind: kind,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
  )
  q.position = LspFilePosition(
    line: Line0Based(line), 
    character: Utf16Int(character)
  )
  return q

proc initNimsuggestInlayHintQuery*(
  ls: LanguageServer,
  id: int,
  uri: FileUri,
  startLine, startCharacter: int,
  endLine, endCharacter: int,
  inlayHintsOptions: string
): NimsuggestQuery[LspFilePosition] =
  ## Create an inlay-hints range query.
  ## Lines are 0-based (LSP convention); converted to 1-based for nimsuggest internally.
  ## The dirtyFile is resolved automatically from the stash.
  ls.addProjectFileToPendingRequest(id.uint, uri)
  return NimsuggestQuery[LspFilePosition](
    id: id.uint,
    kind: NimsuggestQueryKind.INLAY_HINTS,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
    inlayHints: (
      start: LspFilePosition(
        line: Line0Based(startLine), 
        character: Utf16Int(startCharacter)
      ),
      finish: LspFilePosition(
        line: Line0Based(endLine), 
        character: Utf16Int(endCharacter)
      ),
      options: inlayHintsOptions
    )
  )

proc initNimsuggestFileQuery*(
  ls: LanguageServer,
  id: int,
  uri: FileUri,
  kind: NimsuggestQueryKind,
): NimsuggestQuery[LspFilePosition] =
  ls.addProjectFileToPendingRequest(id.uint, uri)
  return NimsuggestQuery[LspFilePosition](
    id: id.uint,
    kind: kind,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
  )

# === QUEUES ===
proc addQueryToQueue*(
  ls: LanguageServer, q: NimsuggestQuery[LspFilePosition],
): Future[seq[Suggest]] =
  let uri = q.uri
  ls.langserverQueue.addLastNoWait(LangserverQuery(
    kind: LangserverQueryKind.NIMSUGGEST,
    nimsuggest: q
  ))
  return q.responseFuture

