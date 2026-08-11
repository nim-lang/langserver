import std/[options, sets, strutils, tables, os, sequtils, times]
import chronos
import chronicles
import ../nimsuggest/[nimsuggest_types, suggestapi_types, nimsuggest_process]
import ../protocol/types
import ../nph/formatting
import ../nimsuggest/nimsuggest_slots
import ./[configurations, dispatcher_utils, nimsuggest_processes, utils]
import ../handlers/request_process
import ../utils/utils as globalUtils
import ../configurations/configurations as configParser
import ./[langserver_types, query_types]

proc consolidateNimsuggestInstances(
  ls: LanguageServer,
  newSlot: NimsuggestSlot,
): Future[seq[FilePath]] {.async.} =
  # Consolidation: for each other slot, check if the new slot subsumes it.
  var slotsToRemove: seq[FilePath] = @[]
  for projectPath, oldSlot in ls.pool.slots:
    if oldSlot.projectFile == newSlot.projectFile: continue
    let knownQuery = NimsuggestQuery[LspFilePosition](
      id: 0.uint,
      kind: NimsuggestQueryKind.KNOWN,
      uri: pathToUri(oldSlot.projectFile),
      dirtyFile: FilePath(""),
      responseFuture: newFuture[seq[Suggest]]("known"),
    )
    newSlot.queryMailbox.addLastNoWait(knownQuery)
    let response = await knownQuery.responseFuture
    let newSlotKnowsOldSlot = checkNimsuggestKnownResponse(response)
    if newSlotKnowsOldSlot:
      debug "consolidateNimsuggestInstances: new slot knows old slot", newSlotProjectFile = newSlot.projectFile, oldSlotProjectFile = oldSlot.projectFile
      # New slot knows old slot's entry point → it imported old slot entirely.
      # Transfer all owned URIs and shut the old slot down.
      newSlot.ownedUris.incl(pathToUri(oldSlot.projectFile))
      if pathToUri(oldSlot.projectFile) in ls.files.openFiles:
        ls.files.openFiles[pathToUri(oldSlot.projectFile)].slot = newSlot
      for oldSlotUri in oldSlot.ownedUris.toSeq:
        debug "consolidateNimsuggestInstances: reassign owned uri ", oldSlotUri = oldSlotUri
        
        oldSlot.ownedUris.excl(oldSlotUri)
        newSlot.ownedUris.incl(oldSlotUri)
        if oldSlotUri in ls.files.openFiles:
          ls.files.openFiles[oldSlotUri].slot = newSlot
        if newSlot.state == SlotState.READY:
          newSlot.ns.read.openFiles.incl(oldSlotUri)

      discard await execStop(oldSlot, ls.pool)
      slotsToRemove.add(oldSlot.projectFile)
    else:
      debug "consolidateNimsuggestInstances: new slot does not know old slot", newSlotProjectFile = newSlot.projectFile, oldSlotProjectFile = oldSlot.projectFile

  debug "consolidateNimsuggestInstances: remove slots", slotsToRemove = slotsToRemove
  for s in slotsToRemove:
    ls.pool.removeSlot(s)
  
  return slotsToRemove

proc createNewSuggestSlotAndConsolidate(
  ls: LanguageServer,
  filePath: FilePath,
  params: TextDocumentItem
): Future[NimsuggestSlot] {.async.} =

  let workingDir = ls.getWorkingDir(filePath)
  let newSlot = newSlot(filePath, isEntryPoint = true, workingDir)
  ls.pool.addSlot(newSlot)
  debug "createNewSuggestSlotAndConsolidate: spawn new nimsuggest slot", workingDir = workingDir
  let successfulSpawn = await execSpawn(newSlot, ls.pool, filePath)
  if successfulSpawn:
    debug "createNewSuggestSlotAndConsolidate:add file to open files", filePath = $(filePath)
    ls.addFileToOpenFiles(newSlot, params)
    asyncSpawn processNimsuggestQueries(
      newSlot, ls.pool, ls.files.openFiles, ls.notify
    )
    # Consolidation: for each other slot, check if the new slot subsumes it.
    discard await ls.consolidateNimsuggestInstances(newSlot)
    
  else:
    debug "createNewSuggestSlotAndConsolidate: spawn unsuccessful"
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
      if q.uri in ls.files.openFiles:
        let fileInfo = ls.files.openFiles[q.uri]
        fileInfo.slot.queryMailbox.addLastNoWait(q)
        
        debug "processLangserverQueue: dispatcher added message to slot mailbox", uri = q.uri, kind = $q.kind, fileInfoIsNil = (fileInfo == nil), projectFile = fileInfo.slot.projectFile

      else:
        debug "processLangserverQueue: Could not add message to mailbox, file is no longer open. ", uri = q.uri, kind = $q.kind

    of LangserverQueryKind.FILE_ACCESS:
      let q = query.fileAccess
      case q.kind
      of FileAccessQueryKind.DID_OPEN:
        let uri = q.didOpen.textDocument.uri
        # Check if file is already open
        if uri in ls.files.openFiles:
          debug "didOpenFile: URI already tracked, skipping", uri = uri

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
            let filePath: FilePath = uriToPath(uri)

            debug "didOpen: Check if it is a true orphan", uri = uri, filePath = filePath
            # does it have a project file?
            let intendedProjectPath: FilePath = getIntendedProject(ls, uri)

            if string(intendedProjectPath) != "" and intendedProjectPath != filePath:
              # File maps to a specific project entry point (via projectMapping regex).
              debug "didOpen: It has an intended project file", uri = uri, intendedProjectPath = intendedProjectPath
              if ls.pool.slots.hasKey(intendedProjectPath):
                # Slot already running for the intended project — assign directly.
                debug "didOpen: Intended project slot already running, assigning directly", uri = uri, intendedProjectPath = intendedProjectPath
                discard await createNewSuggestSlotAndConsolidate(ls, filePath, q.didOpen.textDocument)
                
              else:
                # No slot for this project yet — spawn it, then check if it knows our file.
                debug "didOpen: No slot for the project yet, so spawn it ", intendedProjectPath = intendedProjectPath
                let projectWorkingDir = ls.getWorkingDir(intendedProjectPath)
                let newProjectSlot = newSlot(
                  intendedProjectPath,
                  isEntryPoint = true,
                  workingDir = projectWorkingDir
                )
                ls.pool.addSlot(newProjectSlot)
                let intendedProjectSpawn = await execSpawn(newProjectSlot, ls.pool, intendedProjectPath)
                if intendedProjectSpawn:
                  asyncSpawn processNimsuggestQueries(
                    newProjectSlot, ls.pool, ls.files.openFiles, ls.notify
                  )
                  let projectKnownQuery = NimsuggestQuery[LspFilePosition](
                    id: 0.uint,
                    kind: NimsuggestQueryKind.KNOWN,
                    uri: uri,
                    dirtyFile: FilePath(""),
                    responseFuture: newFuture[seq[Suggest]]("known"),
                  )
                  newProjectSlot.queryMailbox.addLastNoWait(projectKnownQuery)
                  let projectResponse = await projectKnownQuery.responseFuture
                  let thisProjectKnowsTheFile = checkNimsuggestKnownResponse(projectResponse)
                  if thisProjectKnowsTheFile:
                    debug "didOpen: The project does know the current file.", fileThatKnows = intendedProjectPath,  fileThatIsKnown = uri
                      #Here is where consolidation is needed.
                    ls.addFileToOpenFiles(newProjectSlot, q.didOpen.textDocument)
                    discard await ls.consolidateNimsuggestInstances(newProjectSlot)
                  else:
                    debug "didOpen: The project does not know the current file. Spin up a new standalone orphan."
                    discard await execStop(newProjectSlot, ls.pool)
                    ls.pool.removeSlot(intendedProjectPath)
                    discard await createNewSuggestSlotAndConsolidate(ls, filePath, q.didOpen.textDocument)
                else:
                  ls.pool.removeSlot(intendedProjectPath)

            else:
              # True orphan (no mapping) or file is its own entry point.
              let entryPoint = if string(intendedProjectPath) != "": intendedProjectPath else: filePath
              debug "didOpen: Spawning standalone nimsuggest", entryPoint = entryPoint
              discard await createNewSuggestSlotAndConsolidate(ls, entryPoint, q.didOpen.textDocument)

            let needToEvict = ls.pool.maxSlots > 0 and ls.pool.slots.len > ls.pool.maxSlots
              
            debug "didOpen: Should slot be evicted?", maxSlots = ls.pool.maxSlots, filledSlots = ls.pool.slots.len 
            if needToEvict:
              # Evict a slot.
              let slotToEvict = nimsuggestSlotToEvict(ls.pool)
              debug "didOpen: Evicting a slot.", slotToEvict = slotToEvict.projectFile
              while slotToEvict.queryMailbox.len > 0:
                let pendingQ = slotToEvict.queryMailbox.popFirstNoWait()
                if not pendingQ.responseFuture.finished:
                  pendingQ.responseFuture.complete(@[])
              # slotToEvict.pendingChangedUris.clear()

              let successfulStop = await execStop(slotToEvict, ls.pool)
              if successfulStop:
                debug "didOpen: Removing from slot: ", projectFile = slotToEvict.projectFile
                # Move evicted files to idleOpenFiles so they can be re-assigned on next use.
                # for uri in slotToEvict.ownedUris:
                  # if uri in ls.files.openFiles:
                    # ls.files.idleOpenFiles[uri] = ls.files.openFiles[uri]
                    # ls.files.openFiles.del(uri)
                ls.pool.removeSlot(slotToEvict.projectFile)
            
      of FileAccessQueryKind.DID_CHANGE:
        let uri = q.didChange.textDocument.uri
        let contentChanges = q.didChange.contentChanges
        let openFiles = ls.files.openFiles.keys.toSeq()
        debug "Dispatcher: DID_CHANGE ", uri = uri, openFiles = openFiles
    
        if uri notin ls.files.openFiles:
          continue
        let stashLocation = ls.uriStorageLocation(uri)
        let file = open(string(stashLocation), fmWrite)

        ls.files.openFiles[uri].fingerTable = @[]
        # ls.files.openFiles[uri].changed = true
        if contentChanges.len <= 0:
          file.close()
          continue
        for line in contentChanges[0].text.splitLines:
          # fingertable is 0-based.
          ls.files.openFiles[uri].fingerTable.add(line.createUTFMapping())
          file.writeLine(line)
        file.close()

        # We should schedule a changed query, nimsuggets doesn't know it has changed.
        # ls.files.openFiles[uri].changed = true
        ls.files.openFiles[uri].lastChanged = times.now()

        let changedQuery = LangserverQuery(
          kind: LangserverQueryKind.NIMSUGGEST,
          nimsuggest: NimsuggestQuery[LspFilePosition](
            id: 0, # NOTE: Check that this doesn't get cancelled accidentally
            kind: NimsuggestQueryKind.CHANGED,
            uri: uri,
            dirtyFile: stashLocation, #ls.uriToStash(uri),
            responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
          )
        )
        ls.langserverQueue.addLastNoWait(changedQuery)

      of FileAccessQueryKind.DID_SAVE:
        let uri = q.didSave.textDocument.uri
        debug "didSave: enter", uri = uri
        if uri in ls.files.openFiles:
          let fileInfo = ls.files.openFiles[uri]
          if uri in fileInfo.slot.crashedUris:
            fileInfo.slot.crashedUris.excl(uri)

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
        ls.langserverQueue.addLastNoWait(changedQuery)

        # if config.checkOnSave.get(true):
        # CHECK PROJECT 
        # Send chk with the slot's project file, not the saved URI. nimsuggest's chk
        # command takes the entry-point path it was spawned with; any other file would
        # cause it to check the wrong scope.
        
        # NOTE: IS THIS NECESSARY ANY MORE?
        # debug "Checking project", uri = uri
        # let slotForUri = ls.pool.slotForUri(uri)
        # if slotForUri.isSome:
        #   let chkQuery = LangserverQuery(
        #     kind: LangserverQueryKind.NIMSUGGEST,
        #     nimsuggest: NimsuggestQuery[LspFilePosition](
        #       id: 0,
        #       kind: NimsuggestQueryKind.CHECK_PROJECT,
        #       uri: pathToUri(slotForUri.get().projectFile),
        #       dirtyFile: FilePath(""),
        #       responseFuture: newFuture[seq[Suggest]]("checkProject"),
        #     )
        #   )
        #   ls.langserverQueue.addLastNoWait(chkQuery)

      of FileAccessQueryKind.DID_CLOSE:
        let uri = q.didClose.textDocument.uri
        debug "Closed the following document:", uri = uri
        if uri notin ls.files.openFiles:
          continue
        let fileInfo = ls.files.openFiles[uri]
        # if fileInfo.changed:
        let checkQuery = await ls.queryFile(uri, NimsuggestQueryKind.CHECK_FILE)

        fileInfo.slot.unassignUri(uri)
        # If the slot has no remaining tracked files, shut it down — important for standalone orphan slots.
        debug "Check the amount of owned uris for this slot:", uri = uri, ownedUris = fileInfo.slot.ownedUris.len
        if fileInfo.slot.ownedUris.len == 0 and ls.pool.slots.len > 1:
          # The ls.pool.slots.len > 1 qualification means that if there is only one slot left, it is persisted, so nimsuggest is not constantly spawning and stopping.
          debug "Stopping this slot:", uri = uri
          discard await execStop(fileInfo.slot, ls.pool)
          ls.pool.removeSlot(fileInfo.slot.projectFile)
        ls.files.openFiles.del(uri)

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

          if string(oldStash).fileExists:
            try:
              moveFile(string(oldStash), string(newStash))
            except Exception as e:
              debug "Failed to move stash file on rename",
                oldStash = oldStash, newStash = newStash, msg = e.msg

          let oldPath: FilePath = uriToPath(oldUri)
          if string(oldPath).endsWith(".nimble"):
            ls.nimDumpCache.del(string(oldPath))
            ls.nimDumpCache.del(string(uriToPath(newUri)))
          if oldUri in ls.files.openFiles:
            let fileInfo = ls.files.openFiles[oldUri]
            let slot = fileInfo.slot
            slot.unassignUri(oldUri)
            slot.assignUri(newUri)
            ls.files.openFiles[newUri] = NlsFileInfo(
              slot: slot,
              fingerTable: fileInfo.fingerTable,
              lastChanged: fileInfo.lastChanged,
              lastChecked: fileInfo.lastChecked,
              textDocument: TextDocumentItem(
                uri: newUri,
                languageId: fileInfo.textDocument.languageId,
                version: fileInfo.textDocument.version,
                text: fileInfo.textDocument.text,
              ),
            )
            ls.files.openFiles.del(oldUri)

            if string(oldPath).endsWith(".nim"):
              # RECOMPILE The Nimsuggest Instance
              let nsOpt = slot.resolvedNs
              if nsOpt.isSome:
                debug "processCommands: sending recompile", projectFile = slot.projectFile
                let recompileQuery = NimsuggestQuery[LspFilePosition](
                  kind: NimsuggestQueryKind.RECOMPILE,
                  uri: pathToUri(slot.projectFile),
                  dirtyFile: FilePath(""),
                  responseFuture: newFuture[seq[Suggest]]("recompile"),
                )
                slot.queryMailbox.addLastNoWait(recompileQuery)

      of FileAccessQueryKind.DID_DELETE_FILES:
        for f in q.deleteFiles.files:
          let uri = f.uri
          debug "File deleted", uri = uri
          let path: FilePath = uriToPath(uri)
          if string(path).endsWith(".nimble"):
            ls.nimDumpCache.del(string(path))
          if uri in ls.files.openFiles:
            let fileInfo = ls.files.openFiles[uri]
            fileInfo.slot.unassignUri(uri)
            if string(path).endsWith(".nim"):
              let recompileQuery = NimsuggestQuery[LspFilePosition](
                kind: NimsuggestQueryKind.RECOMPILE,
                uri: pathToUri(fileInfo.slot.projectFile),
                dirtyFile: FilePath(""),
                responseFuture: newFuture[seq[Suggest]]("recompile"),
              )
              fileInfo.slot.queryMailbox.addLastNoWait(recompileQuery)
            ls.files.openFiles.del(uri)

      of FileAccessQueryKind.DID_CHANGE_CONFIGURATION:
        debug "Changed configuration: "
        if ls.usePullConfigurationModel:
          ls.maybeRequestConfigurationFromClient
        else:
          let oldConfiguration = ls.getWorkspaceConfiguration()
          let newConfiguration = parseWorkspaceConfiguration(q.didChangeConfiguration)
          ls.configurations.currentConfig = some(newConfiguration)
          clearCompiledRegexCache()
          ls.configurations.configReady.fire()
          if configurationChanged(oldConfiguration, newConfiguration):
            debug "Configuration changed, restarting all nimsuggest instances"
            ls.restartAllNimsuggestInstances()

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
