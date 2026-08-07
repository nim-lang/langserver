import std/[options, times, strformat, json]
import chronos
import chronicles
import ../nimsuggest/[nimsuggest_types, suggestapi_types, suggestapi]
import ../configurations/constants
import ../langserver/[utils, query_types, langserver_types, langserver]
import ./handler_utils

# === NIMSUGGEST QUERIES ===
proc initNimsuggestPositionQuery*(
  ls: LanguageServer,
  id: int,
  uri: string,
  kind: NimsuggestQueryKind,
  line, character: int,
): Option[NimsuggestQuery] =
  ## Create a position-based query (hover, definition, completion, …).
  ## line is 0-based (LSP convention); converted to 1-based for nimsuggest internally.
  ## The dirtyFile is resolved automatically from the stash.
  let column = toUtf8Col(ls, uri, line, character)
  if column.isNone:
    return none(NimsuggestQuery)
  else:
    ls.addProjectFileToPendingRequest(id.uint, uri)
    let q = NimsuggestQuery(
      id: id.uint,
      kind: kind,
      uri: uri,
      dirtyFile: ls.uriToStash(uri),
      responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
    )
    q.position = FilePosition(line: line + 1, col: column.get)
    return some(q)

proc initNimsuggestInlayHintQuery*(
  ls: LanguageServer,
  id: int,
  uri: string,
  startLine, startCharacter: int,
  endLine, endCharacter: int,
  inlayHintsOptions: string
): Option[NimsuggestQuery] =
  ## Create an inlay-hints range query.
  ## Lines are 0-based (LSP convention); converted to 1-based for nimsuggest internally.
  ## The dirtyFile is resolved automatically from the stash.
  let startColumn = toUtf8Col(ls, uri, startLine, startCharacter)
  let clampedEndLine =
    if uri in ls.files.openFiles:
      min(endLine, ls.files.openFiles[uri].fingerTable.len - 1)
    else:
      endLine
  let endColumn = toUtf8Col(ls, uri, clampedEndLine, endCharacter)
  if startColumn.isNone:
    return none(NimsuggestQuery)
  else:
    ls.addProjectFileToPendingRequest(id.uint, uri)
    return some(NimsuggestQuery(
      id: id.uint,
      kind: NimsuggestQueryKind.INLAY_HINTS,
      uri: uri,
      dirtyFile: ls.uriToStash(uri),
      responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
      inlayHints: (
        start: FilePosition(
          line: startLine + 1, col: startColumn.get
        ),
        finish: FilePosition(
          line: clampedEndLine + 1, col: endColumn.get(0)
        ),
        options: inlayHintsOptions
      )
    ))

proc initNimsuggestFileQuery*(
  ls: LanguageServer,
  id: int,
  uri: string,
  kind: NimsuggestQueryKind,
): NimsuggestQuery =
  ls.addProjectFileToPendingRequest(id.uint, uri)
  return NimsuggestQuery(
    id: id.uint,
    kind: kind,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
  )

# === QUEUES ===
proc addQueryToQueue*(
  ls: LanguageServer, q: NimsuggestQuery,
): Future[seq[Suggest]] =
  let uri = q.uri
  ls.langserverQueue.addLastNoWait(LangserverQuery(
    kind: LangserverQueryKind.NIMSUGGEST,
    nimsuggest: q
  ))
  return q.responseFuture

