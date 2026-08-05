import std/[options]
import ../protocol/[enums, types]
import ../langserver/[utils, langserver_types, queue_types]
import ../nim_tools/nimsuggest/suggestapi

proc initNimsuggestPositionQuery*(
  ls: LanguageServer,
  id: int,
  uri: string,
  kind: NimsuggestQueryKind,
  line, character: int,
): Option[NimsuggestQuery] =
  ## Create a position-based query (hover, definition, completion, …).
  ## line is 0-based (LSP convention); converted to 1-based for nimsuggest internally."
  ## The dirtyFile is resolved automatically from the stash.
  let column = toUtf8Col(ls, line, character)
  if column.isNone:
    return none(NimsuggestQuery)
  else:
    ls.addProjectFileToPendingRequest(id.uint, uri)
    return some(NimsuggestQuery(
      id: id.uint,
      kind: kind,
      uri: uri,
      dirtyFile: ls.uriToStash(uri),
      responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
      position: FilePosition(line: line + 1, col: column.get),
    ))

proc initNimsuggestInlayHintQuery*(
  ls: LanguageServer,
  id: int,
  uri: string,
  startLine, startCharacter: int,
  endLine, endCharacter: int,
  inlayHintsOptions: string
): Option[NimsuggestQuery] =
  ## Create a position-based query (hover, definition, completion, …).
  ## line is 0-based (LSP convention); converted to 1-based for nimsuggest internally."
  ## The dirtyFile is resolved automatically from the stash.
  let startColumn = toUtf8Col(ls, startLine, startCharacter)
  let endColumn = toUtf8Col(ls, endLine, endCharacter)
  if startColumn.isNone: # or endColumn.isNone:
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
          line: endLine + 1, col: endColumn.get
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
  return some(NimsuggestQuery(
    id: id.uint,
    kind: kind,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
  ))
