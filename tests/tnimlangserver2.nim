import ../[
  nimlangserver, ls, lstransports
]
import ../protocol/[enums, types]
import std/[options, unittest, json, os, jsonutils]
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


proc showMessage(params: JsonNode): Future[void] = 
  try:
    let notification = params.jsonTo(tuple[`type`: MessageType, msg: string])
    debug "showMessage Called with ", params = params
  except CatchableError:
    discard
  result = newFuture[void]("showMessage")

proc configuration(params: JsonNode): Future[void] = 
  try:
    let conf = params
    debug "configuration called with ", params = params
  except CatchableError as ex:
    error "Error in configuration ", msg = ex.msg
    discard
  result = newFuture[void]("configuration")

  
suite "Suggest API selection":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  
  client.register("window/showMessage", showMessage)
  client.register("workspace/configuration", configuration)
  waitFor client.connect("localhost", cmdParams.port)
  discard waitFor client.initialize()
  client.notify("initialized", newJObject())


  test "Suggest api":
    client.notify("textDocument/didOpen", %createDidOpenParams("projects/hw/hw.nim"))
    check true
    waitFor sleepAsync(1000)
  


    

