import ../[
  nimlangserver, ls, lstransports, utils
]
import ../protocol/[enums, types]
import std/[options, unittest, json, os, jsonutils, sequtils]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient


suite "Nimlangserver":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  
  test "initialize from the client should call initialized on the server":
    
    let initializeResult = waitFor client.initialize()
    
    check initializeResult.capabilities.textDocumentSync.isSome
   
   
  teardown:
    #TODO properly stop the server
    echo "Teardown"
    client.close()
    ls.onExit()

#TODO once we have a few more of these do proper helpers
proc showMessage(client: LspSocketClient, params: JsonNode): Future[void] = 
  try:
    let notification = params.jsonTo(tuple[`type`: MessageType, msg: string])
    debug "showMessage Called with ", params = params
    var calls = client.calls.getOrDefault("window/showMessage", newSeq[JsonNode]())
    calls.add params
  except CatchableError:
    discard
  result = newFuture[void]("showMessage")

proc suggestInit(params: JsonNode): Future[void] = 
  try:
    let pp = params.jsonTo(ProgressParams)
    debug "SuggestInit called ", pp = pp[]
    result = newFuture[void]()
  except CatchableError:
    discard

proc configuration(params: JsonNode): Future[JsonNode] = 
  try:
    let conf = params
    debug "configuration called with ", params = params
  except CatchableError as ex:
    error "Error in configuration ", msg = ex.msg
    discard
  result = newFuture[JsonNode]("configuration")
  let workspaceConfiguration = %* [{
      "projectMapping": [{
        "projectFile": "missingRoot.nim",
        "fileRegex": "willCrash\\.nim"
      }, {
        "projectFile": "hw.nim",
        "fileRegex": "hw\\.nim"
      }, {
        "projectFile": "root.nim",
        "fileRegex": "useRoot\\.nim"
      }],
      "autoCheckFile": false,
      "autoCheckProject": false
  }]
  result.complete(workspaceConfiguration)

import strutils
suite "Suggest API selection":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  
  client.register("window/showMessage", partial(showMessage, client))
  # client.register("window/workDoneProgress/create", suggestInit)
  # client.register("workspace/configuration", configuration)
  


  waitFor client.connect("localhost", cmdParams.port)
  discard waitFor client.initialize()
  client.notify("initialized", newJObject())


  test "Suggest api":
    client.notify("textDocument/didOpen", %createDidOpenParams("projects/hw/hw.nim"))
    # check client.calls["window/showMessage"].mapIt(it["message"].jsonTo(string)).anyIt("Nimsuggest initialized for " in it)
    # waitFor sleepAsync(100000)
    check true
  


    

