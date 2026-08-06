
# === Injected async callbacks ===
type
  SpawnProc* = proc(
    projectFile: string, nimPaths: seq[string]
  ): Future[NimSuggest] {.gcsafe, raises: [].}

  StopProc* = proc(ns: NimSuggest): Future[void] {.gcsafe, raises: [].}

  IsKnownProc* = proc(
    ns: NimSuggest, filePath: string
  ): Future[bool] {.gcsafe, raises: [].}

  NotifyProc* = proc(meth: string, params: JsonNode) {.gcsafe, raises: [].}
  StatusChangedProc* = proc() {.gcsafe, raises: [].}

# === NIMSUGGEST POOL TYPES === 
type 
  NimsuggestPool* = ref object
    slots*: Table[string, NimsuggestSlot]
    maxSlots*: int
    spawnProc*: SpawnProc
    stopProc*: StopProc
    isKnownProc*: IsKnownProc
    notifyProc*: NotifyPro
    statusChangedProc*: StatusChangedProc
