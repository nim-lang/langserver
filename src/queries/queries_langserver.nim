

# import ../nim_tools/nimsuggest/nimsuggest_types
import ../protocol/types

type
  LangserverQueryKind* {.pure.} = enum
    NIMSUGGEST, FILE_ACCESS
    # , SLOT_COMMAND

  LangserverQuery* = object
    case kind*: LangserverQueryKind
    of LangserverQueryKind.NIMSUGGEST:
      nimsuggest*: NimsuggestQuery
    of LangserverQueryKind.FILE_ACCESS:
      fileAccess*: FileAccessQuery
    # of LangserverQueryKind.SLOT_COMMAND
    #   nimsuggestSlot*: SlotCommand


proc processLanguageServerQuery*(
  ls: LanguageServer,
  query: LanguageserverQuery
) = 
  case query.kind
  of LangserverQueryKind.NIMSUGGEST:
    await ls.processNimsuggestQuery(query.nimsuggest)
  of LangserverQueryKind.FILE_ACCESS:
    await ls.processFileAccessQuery(query.fileAccess)
