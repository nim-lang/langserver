import std/[options, sets, strutils, tables, os, sequtils]
import chronos
import chronicles
import ../nimsuggest/[nimsuggest_types, suggestapi_types, nimsuggest_process]
import ../protocol/types
import ./checking
import ../nph/formatting
import ../nimsuggest/nimsuggest_slots
import ./[configurations, diagnostics, dispatcher_utils, nimsuggest_processes, utils]
import ../handlers/request_process
import ../utils/utils as globalUtils
import ../utils/process_utils
import ../configurations/configurations as configParser
import ./[langserver_types, query_types]

proc createNewSuggestSlotAndConsolidate(
  ls: LanguageServer, 
  filePath: string, 
  params: TextDocumentItem
): Future[NimsuggestSlot] {.async.} =

  let workingDir = ls.getWorkingDir(filePath)
  let newSlot = newSlot(filePath, isEntryPoint = true, workingDir)
  ls.pool.addSlot(newSlot)

  let successfulSpawn = await execSpawn(newSlot, ls.pool, filePath)
  if successfulSpawn:
    ls.addFileToOpenFiles(newSlot, params)
    asyncSpawn processNimsuggestQueries(newSlot, ls.pool, ls.files.openFiles)
    # Consolidation: for each other slot, check if the new slot subsumes it.
    var slotsToRemove: seq[string] = @[]
    for projectPath, oldSlot in ls.pool.slots:
      if oldSlot.projectFile == filePath: continue
      let knownQuery = NimsuggestQuery[LspFilePosition](
        id: 0.uint,
        kind: NimsuggestQueryKind.KNOWN,
        uri: pathToUri(oldSlot.projectFile),
        dirtyFile: "",
        responseFuture: newFuture[seq[Suggest]]("known"),
      )
      newSlot.queryMailbox.addLastNoWait(knownQuery)
      let response = await knownQuery.responseFuture
      let newSlotKnowsOldSlot = checkNimsuggestKnownResponse(response)
      if newSlotKnowsOldSlot:
        # New slot knows old slot's entry point → it imported old slot entirely.
        # Transfer all owned URIs and shut the old slot down.
        for oldSlotUri in oldSlot.ownedUris.toSeq:
          oldSlot.unassignUri(oldSlotUri)
          newSlot.assignUri(oldSlotUri)
          if newSlot.state == SlotState.READY:
            newSlot.ns.read.openFiles.incl(oldSlotUri)

          if oldSlotUri in ls.files.openFiles:
            ls.files.openFiles[oldSlotUri].slot = newSlot
        
        discard await execStop(oldSlot, ls.pool)
        slotsToRemove.add(oldSlot.projectFile)
    
    for s in slotsToRemove:
      ls.pool.removeSlot(s)
  else:
    ls.pool.removeSlot(filePath)
  return newSlot


proc processLangserverQueue*(ls: LanguageServer): Future[void] {.async.} =
  ## Single coroutine that drains ls.langserverQueue in FIFO order.
  ##
  ## All LSP-triggered work — file operations and nimsuggest queries alike —
  ## flows through this queue. Processing order matches LSP message arrival
  ## order, guaranteeing that a didChange stash write is applied before any
  ## subsequent hover query is dispatched to the per-slot mailbox.
  ##
  ## Invariant: use `while true` not tail recursion. Each recursive async call
  ## creates a new Future object that is never freed until the chain resolves
  ## (which for an infinite loop means never), corrupting the heap under ORC.
  while true:
    debug "processLangserverQueue: waiting for next item", queueLen = ls.langserverQueue.len
    let query = await ls.langserverQueue.popFirst()
    # Wait for initNimsuggestInstances to complete so that:
    # (a) config is available for getIntendedProject, and
    # (b) entry-point slots are in the pool so we can assign to them.
    await ls.waitForLsInitialized()

    debug "processLangserverQueue: dequeued item", kind = $query.kind
    case query.kind
    of LangserverQueryKind.NIMSUGGEST:
      let q = query.nimsuggest
      # Refresh dirtyFile at dispatch time. The query was constructed in the LSP
      # handler before any FILE_ACCESS (DID_CHANGE) in front of it was processed,
      # so dirtyFile may have been captured as "" even though changed=true by now.
      q.dirtyFile = ls.uriToStash(q.uri)
      # First, check if the current file is owned by a nimsuggest instance
      let fileInfo = ls.files.openFiles.getOrDefault(q.uri)
      debug "dispatcher NIMSUGGEST branch", uri = q.uri, kind = $q.kind,
        fileInfoIsNil = (fileInfo == nil),
        slotIsNil = (fileInfo != nil and fileInfo.slot == nil)
      if fileInfo != nil:
        if fileInfo.slot != nil:
          debug "dispatcher: adding to slot mailbox", uri = q.uri, projectFile = fileInfo.slot.projectFile
          # NimsuggestSlot is a ref object, so fileInfo.slot is just a pointer to the same heap object that lives in pool.slots[projectFile].
          fileInfo.slot.queryMailbox.addLastNoWait(q)
        else:
          debug "dispatcher: fileInfo.slot is nil, completing with empty", uri = q.uri
          q.responseFuture.complete(@[])
      else:
        debug "dispatcher: fileInfo is nil, completing with empty", uri = q.uri
        q.responseFuture.complete(@[])
      
    of LangserverQueryKind.FILE_ACCESS:
      let q = query.fileAccess
      case q.kind
      of FileAccessQueryKind.DID_OPEN:
        let uri = q.didOpen.textDocument.uri
        # Check if file is already open
        if uri in ls.files.openFiles:
          debug "didOpenFile: URI already tracked, skipping", uri = uri

        else:
          # Re-entry guard: another coroutine may have opened this URI while we awaited.
          if uri in ls.files.openFiles:
            debug "didOpenFile: URI opened by concurrent coroutine, skipping", uri = uri
          else:
            # Check if file is known to any nimsuggest instance
            debug "didOpen: calling isKnownByANimsuggestSlot", uri = uri
            let fileIsKnown: Option[NimsuggestSlot] = await isKnownByANimsuggestSlot(ls.pool, uri)
            debug "didOpen: isKnownByANimsuggestSlot returned", uri = uri, isKnown = fileIsKnown.isSome

            if fileIsKnown.isSome:
              debug "didOpen: known file, calling addFileToOpenFiles", uri = uri
              ls.addFileToOpenFiles(fileIsKnown.get(), q.didOpen.textDocument)
              debug "didOpen: known file, addFileToOpenFiles done", uri = uri
            else:
              # This file is not known by any running nimsuggest instance.
              # Check there is a free nimsuggest slot
              let filePath = uriToPath(uri)

              debug "didOpen: Check if it is a true orphan", uri = uri, filePath = filePath
              # does it have a project file?
              let intendedProjectPath = getIntendedProject(ls, uri)

              if intendedProjectPath != "" and intendedProjectPath != filePath:
                # File maps to a specific project entry point (via projectMapping regex).
                debug "didOpen: It has an intended project file", uri = uri, intendedProjectPath = intendedProjectPath
                if ls.pool.slots.hasKey(intendedProjectPath):
                  # Slot already running for the intended project — assign directly.
                  debug "didOpen: Intended project slot already running, assigning directly", uri = uri, intendedProjectPath = intendedProjectPath
                  discard await createNewSuggestSlotAndConsolidate(ls, filePath, q.didOpen.textDocument)
                  
                else:
                  # No slot for this project yet — spawn it, then check if it knows our file.
                  let projectWorkingDir = ls.getWorkingDir(intendedProjectPath)
                  let newProjectSlot = newSlot(
                    intendedProjectPath,
                    isEntryPoint = true,
                    workingDir = projectWorkingDir
                  )
                  ls.pool.addSlot(newProjectSlot)
                  let intendedProjectSpawn = await execSpawn(newProjectSlot, ls.pool, intendedProjectPath)
                  if intendedProjectSpawn:
                    asyncSpawn processNimsuggestQueries(newProjectSlot, ls.pool, ls.files.openFiles)
                    let projectKnownQuery = NimsuggestQuery[LspFilePosition](
                      id: 0.uint,
                      kind: NimsuggestQueryKind.KNOWN,
                      uri: uri,
                      dirtyFile: "",
                      responseFuture: newFuture[seq[Suggest]]("known"),
                    )
                    newProjectSlot.queryMailbox.addLastNoWait(projectKnownQuery)
                    let projectResponse = await projectKnownQuery.responseFuture
                    let thisProjectKnowsTheFile = checkNimsuggestKnownResponse(projectResponse)
                    if thisProjectKnowsTheFile:
                      debug "didOpen: The project does know the current file."
                      ls.addFileToOpenFiles(newProjectSlot, q.didOpen.textDocument)
                    else:
                      debug "didOpen: The project does not know the current file. Spin up a new standalone orphan."
                      discard await execStop(newProjectSlot, ls.pool)
                      ls.pool.removeSlot(intendedProjectPath)
                      discard await createNewSuggestSlotAndConsolidate(ls, filePath, q.didOpen.textDocument)
                  else:
                    ls.pool.removeSlot(intendedProjectPath)

              else:
                # True orphan (no mapping) or file is its own entry point.
                # if intendedProjectPath == filePath and ls.pool.slots.hasKey(filePath):
                #   # This file is already running as its own slot — assign directly.
                #   debug "didOpen: File is its own project and slot already running, assigning directly", uri = uri
                #   ls.addFileToOpenFiles(ls.pool.slots[filePath], q.didOpen.textDocument)
                # else:
                let entryPoint = if intendedProjectPath != "": intendedProjectPath else: filePath
                debug "didOpen: Spawning standalone nimsuggest", uri = uri, entryPoint = entryPoint
                discard await createNewSuggestSlotAndConsolidate(ls, entryPoint, q.didOpen.textDocument)

              let needToEvict = ls.pool.maxSlots > 0 and ls.pool.slots.len > ls.pool.maxSlots
                
              if needToEvict:
                # Evict a slot.
                let slotToEvict = nimsuggestSlotToEvict(ls.pool)
                while slotToEvict.queryMailbox.len > 0:
                  let pendingQ = slotToEvict.queryMailbox.popFirstNoWait()
                  if not pendingQ.responseFuture.finished:
                    pendingQ.responseFuture.complete(@[])

                let successfulStop = await execStop(slotToEvict, ls.pool)
                if successfulStop:
                  debug "didOpen: Removing from slot: ", projectFile = slotToEvict.projectFile
                  # Nil out fileInfo.slot for all files the evicted slot owned.
                  # Without this, their slot pointers dangle to a stopped, pool-removed
                  # slot — LSP requests for those files are silently dropped, and
                  # DID_CLOSE re-stops an already-dead slot.
                  for uri in slotToEvict.ownedUris:
                    let fi = ls.files.openFiles.getOrDefault(uri)
                    if fi != nil:
                      fi.slot = nil
                  ls.pool.removeSlot(slotToEvict.projectFile)
            
      of FileAccessQueryKind.DID_CHANGE:
        let uri = q.didChange.textDocument.uri
        let contentChanges = q.didChange.contentChanges
    
        if uri notin ls.files.openFiles:
          continue
        let file = open(ls.uriStorageLocation(uri), fmWrite)

        ls.files.openFiles[uri].fingerTable = @[]
        ls.files.openFiles[uri].changed = true
        if contentChanges.len <= 0:
          file.close()
          continue
        for line in contentChanges[0].text.splitLines:
          ls.files.openFiles[uri].fingerTable.add line.createUTFMapping()
          file.writeLine line
        file.close()
        ls.scheduleFileCheck(uri)
        # Queue CHANGED immediately at the front so it is processed before any
        # position query (hover, definition, completion) already in the queue.
        # addFirstNoWait matches the pattern used by DID_SAVE.
        let changedQuery = LangserverQuery(
          kind: LangserverQueryKind.NIMSUGGEST,
          nimsuggest: NimsuggestQuery[LspFilePosition](
            id: 0,
            kind: NimsuggestQueryKind.CHANGED,
            uri: uri,
            dirtyFile: ls.uriToStash(uri),
            responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
          )
        )
        ls.langserverQueue.addFirstNoWait(changedQuery)

      of FileAccessQueryKind.DID_SAVE:
        let uri = q.didSave.textDocument.uri
        let config = ls.getWorkspaceConfiguration()
        debug "didSave: enter", uri = uri
        if uri in ls.files.openFiles:
          let fileInfo = ls.files.openFiles[uri]
          if fileInfo.slot != nil and uri in fileInfo.slot.crashedUris:
            fileInfo.slot.crashedUris.excl(uri)

        ls.files.openFiles[uri].changed = false
        debug "didSave: sending CHANGED query", uri = uri
        # Directly query nimsuggest
        # WHy do we call this, if it has been saved?  It is not changed, no?
        let changedQuery = LangserverQuery(
           kind: LangserverQueryKind.NIMSUGGEST,
          nimsuggest: NimsuggestQuery[LspFilePosition](
            id: 0,
            kind: NimsuggestQueryKind.CHANGED,
            uri: uri,
            dirtyFile: ls.uriToStash(uri),
            responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
          )
        )

        ls.langserverQueue.addFirstNoWait(changedQuery)

        if config.checkOnSave.get(true):
          debug "Checking project", uri = uri
          traceAsyncErrors ls.checkProject(uri)

      of FileAccessQueryKind.DID_CLOSE:
        let uri = q.didClose.textDocument.uri
        debug "Closed the following document:", uri = uri
        if uri notin ls.files.openFiles:
          continue
        let fileInfo = ls.files.openFiles[uri]
        if fileInfo.changed:
          # TODO CHECK FILE
          asyncSpawn ls.checkFile(uri)

        if fileInfo.slot != nil:
          fileInfo.slot.unassignUri(uri)
          # If the slot has no remaining tracked files, shut it down — important for standalone orphan slots.
          debug "Check the amount of owned uris for this slot:", uri = uri, ownedUris = fileInfo.slot.ownedUris.len
          if fileInfo.slot.ownedUris.len == 0:
            debug "Stopping this slot:", uri = uri
            discard await execStop(fileInfo.slot, ls.pool)
            ls.pool.removeSlot(fileInfo.slot.projectFile)
        ls.files.openFiles.del(uri)
        if fileInfo.cancelFileCheck != nil and not fileInfo.cancelFileCheck.finished:
          fileInfo.cancelFileCheck.complete()


      of FileAccessQueryKind.WILL_SAVE_WAIT_UNTIL:
        let uri = q.willSave.textDocument.uri
        let config = ls.getWorkspaceConfiguration()
        let nphPath = getNphPath()

        let shouldFormat =
          nphPath.isSome and ls.capabilities.lspServerCapabilities.documentFormattingProvider.get(false) and
          config.formatOnSave.get(false)

        if shouldFormat:
          debug "Formatting document before save", uri = uri
          # THis runs the formatting 
          let formatTextEdit = await format(ls, nphPath.get(), uri)
          if formatTextEdit.isSome:
            q.willSaveResponse.complete(@[formatTextEdit.get])
          else:
            q.willSaveResponse.complete(@[])
        else:
          q.willSaveResponse.complete(@[])

      of FileAccessQueryKind.DID_RENAME_FILES:
        for r in q.renameFiles.files:
          let oldUri = r.oldUri
          let newUri = r.newUri
          debug "File renamed", oldUri = oldUri, newUri = newUri
          let oldStash = ls.uriStorageLocation(oldUri)
          let newStash = ls.uriStorageLocation(newUri)

          if oldStash.fileExists:
            try:
              moveFile(oldStash, newStash)
            except Exception as e:
              debug "Failed to move stash file on rename",
                oldStash = oldStash, newStash = newStash, msg = e.msg

          let oldPath = uriToPath(oldUri)
          if oldPath.endsWith(".nimble"):
            ls.nimDumpCache.del(oldPath)
            ls.nimDumpCache.del(uriToPath(newUri))
          if oldUri in ls.files.openFiles:
            let fileInfo = ls.files.openFiles[oldUri]
            let slot = fileInfo.slot
            slot.unassignUri(oldUri)
            slot.assignUri(newUri)
            ls.files.openFiles[newUri] = NlsFileInfo(
              slot: slot,
              changed: fileInfo.changed,
              fingerTable: fileInfo.fingerTable,
              textDocument: TextDocumentItem(
                uri: newUri,
                languageId: fileInfo.textDocument.languageId,
                version: fileInfo.textDocument.version,
                text: fileInfo.textDocument.text,
              ),
            )
            ls.files.openFiles.del(oldUri)
            ls.sendDiagnostics(newSeq[Suggest](), oldPath)

            if oldPath.endsWith(".nim"):
              # RECOMPILE The Nimsuggest Instance
              let nsOpt = slot.resolvedNs
              if nsOpt.isSome:
                debug "processCommands: sending recompile", projectFile = slot.projectFile
                let recompileQuery = NimsuggestQuery[LspFilePosition](
                  kind: NimsuggestQueryKind.RECOMPILE,
                  uri: pathToUri(slot.projectFile),
                  dirtyFile: "",
                  responseFuture: newFuture[seq[Suggest]]("recompile"),
                )
                slot.queryMailbox.addLastNoWait(recompileQuery)

      of FileAccessQueryKind.DID_DELETE_FILES:
        for f in q.deleteFiles.files:
          let uri = f.uri
          debug "File deleted", uri = uri
          let path = uriToPath(uri)
          if path.endsWith(".nimble"):
            ls.nimDumpCache.del(path)
          if uri in ls.files.openFiles:
            let fileInfo = ls.files.openFiles[uri]
            fileInfo.slot.unassignUri(uri)
            if path.endsWith(".nim"):
              let recompileQuery = NimsuggestQuery[LspFilePosition](
                kind: NimsuggestQueryKind.RECOMPILE,
                uri: pathToUri(fileInfo.slot.projectFile),
                dirtyFile: "",
                responseFuture: newFuture[seq[Suggest]]("recompile"),
              )
              fileInfo.slot.queryMailbox.addLastNoWait(recompileQuery)
            ls.files.openFiles.del(uri)

      of FileAccessQueryKind.DID_CHANGE_CONFIGURATION:
        debug "Changed configuration: ", conf = q.didChangeConfiguration
        if ls.usePullConfigurationModel:
          ls.maybeRequestConfigurationFromClient
        else:
          let oldConfiguration = ls.getWorkspaceConfiguration()
          let newConfiguration = parseWorkspaceConfiguration(q.didChangeConfiguration)
          ls.configurations.currentConfig = some(newConfiguration)
          clearCompiledRegexCache()
          ls.configurations.configReady.fire()
          if oldConfiguration.nimsuggestPath != newConfiguration.nimsuggestPath or
              oldConfiguration.maxNimsuggestProcesses != newConfiguration.maxNimsuggestProcesses:
            debug "Nimsuggest config changed, stopping all instances (restart not yet implemented)"
            asyncSpawn ls.stopNimsuggestProcesses()

      of FileAccessQueryKind.FORMATTING:
        let uri = q.formatting.textDocument.uri
        let nphPath = getNphPath()
        if nphPath.isSome:
          let formatTextEdit = await format(ls, nphPath.get(), uri)
          if formatTextEdit.isSome:
            q.formattingResponse.complete(@[formatTextEdit.get])
          else:
            q.formattingResponse.complete(@[])
        else:
          q.formattingResponse.complete(@[])