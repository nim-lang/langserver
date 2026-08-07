import std/[options, sets, strutils, tables, os]
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
    let query = await ls.langserverQueue.popFirst()
    case query.kind
    of LangserverQueryKind.NIMSUGGEST:
      let q = query.nimsuggest
      # First, check if the current file is owned by a nimsuggest instance
      let fileInfo = ls.files.openFiles.getOrDefault(q.uri)
      if fileInfo != nil:
        # NimsuggestSlot is a ref object, so fileInfo.slot is just a pointer to the same heap object that lives in pool.slots[projectFile].
        fileInfo.slot.queryMailbox.addLastNoWait(q)
      else:
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
          # Check if file is known to any nimsuggest instance
          let fileIsKnown: Option[NimsuggestSlot] = await isKnownByANimsuggestSlot(ls.pool, uri)
          if fileIsKnown.isSome:
            ls.addFileToOpenFiles(fileIsKnown.get(), q.didOpen.textDocument)
          else:
            # This file is not known by any running nimsuggest instance.

            # Find the correct entry point for this file, otherwise, treat the file as an orphan and run nimsuggest using it as the projectFile.
            var projectFile = uriToPath(uri)
            let correctProjectFile = getIntendedProject(ls, uri)
            if correctProjectFile.len > 0:
              projectFile = correctProjectFile
            
            let workingDir = ls.getWorkingDir(projectFile)
            # Ensure nimsuggest path is set (may not be if initialized before config arrived).
            if ls.pool.nimsuggestPath == "":
              let (nsPath, nsVer) = await ls.getNimSuggestPathAndVersion(ls.getWorkspaceConfiguration(), workingDir)
              ls.pool.nimsuggestPath = nsPath
              ls.pool.nimVersion = nsVer
            if ls.pool.canSpawn:
              # Free slot available — create a new nimsuggest instance.
              let newSlot = newSlot(
                projectFile,
                isEntryPoint = projectFile == correctProjectFile,
                workingDir = workingDir,
              )
              ls.pool.addSlot(newSlot)
              # Start the query queue running
              let successfulSpawn: bool = await execSpawn(newSlot, ls.pool, projectFile)
              if successfulSpawn:
                discard await newSlot.ns.get()
                ls.addFileToOpenFiles(newSlot, q.didOpen.textDocument)
                asyncSpawn processNimsuggestQueries(newSlot, ls.pool)
              else:
                ls.pool.removeSlot(projectFile)

            else:
              # Pool at capacity — evict a slot.
              let slotToEvict = nimsuggestSlotToEvict(ls.pool)
              while slotToEvict.queryMailbox.len > 0:
                let pendingQ = slotToEvict.queryMailbox.popFirstNoWait()
                if not pendingQ.responseFuture.finished:
                  pendingQ.responseFuture.complete(@[])

              slotToEvict.state = SlotState.STOPPING
              let successfulStop = await execStop(slotToEvict, ls.pool)
              if successfulStop:
                ls.pool.removeSlot(slotToEvict.projectFile)

              # Create a new slot
              let newSlot = newSlot(
                projectFile,
                isEntryPoint = projectFile == correctProjectFile,
                workingDir = workingDir,
              )
              ls.pool.addSlot(newSlot)
              # Start the query queue running
              let successfulSpawn = await execSpawn(newSlot, ls.pool, projectFile)
              if successfulSpawn:
                discard await newSlot.ns.get()
                ls.addFileToOpenFiles(newSlot, q.didOpen.textDocument)
                asyncSpawn processNimsuggestQueries(newSlot, ls.pool)
              else:
                debug "Failed to spawn nimsuggest for file", uri = uri
                ls.pool.removeSlot(projectFile)
            
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
        # I have removed the scheduled file-checking that runs after the user has not been typing for 1 second, or so, and instead just have this run on the user saving.

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
        let changedQuery = LangserverQuery(
           kind: LangserverQueryKind.NIMSUGGEST,
          nimsuggest: NimsuggestQuery(
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
                let recompileQuery = NimsuggestQuery(
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
              let recompileQuery = NimsuggestQuery(
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