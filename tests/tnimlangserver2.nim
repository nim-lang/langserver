import ../[
  nimlangserver, ls, lstransports, utils
]
import ../protocol/[enums, types]
import std/[options, unittest, json, os, jsonutils, sequtils, strutils, sugar, strformat]
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
proc notificationHandle(args: (LspSocketClient, string), params: JsonNode): Future[void] = 
  try:
    let client = args[0]
    let name = args[1]
    if name in [
      "textDocument/publishDiagnostics", 
      "$/progress"
    ]: #Too much noise. They are split so we can toggle to debug the tests
      debug "[NotificationHandled ] Called for ", name = name
    else:
      debug "[NotificationHandled ] Called for ", name = name, params = params
    client.calls[name].add params   
  except CatchableError: discard

  result = newFuture[void]("notificationHandle")

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

proc waitForNotification(client: LspSocketClient, name: string, predicate: proc(json: JsonNode): bool , accTime = 0): Future[bool] {.async.}=
  let timeout = 10000
  if accTime > timeout: return false
  try:    
    {.cast(gcsafe).}:
      for call in client.calls[name]: 
        if predicate(call):
          debug "[WaitForNotification Predicate Matches] ", name = name, call = call
          return true      
  except Exception as ex: 
    error "[WaitForNotification]", ex = ex.msg
  await sleepAsync(100)
  await waitForNotification(client, name, predicate, accTime + 100)
  
  
suite "Suggest API selection":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  template registerNotification(name: string) = 
    client.register(name, partial(notificationHandle, (client, name)))
  
  registerNotification("window/showMessage")
  registerNotification("window/workDoneProgress/create")
  registerNotification("workspace/configuration")
  registerNotification("extension/statusUpdate")
  registerNotification("textDocument/publishDiagnostics")
  registerNotification("$/progress")
  
  
  waitFor client.connect("localhost", cmdParams.port)
  discard waitFor client.initialize()
  client.notify("initialized", newJObject())


  test "Suggest api":
    #The client adds the notifications into the call table and we wait until they arrived.     
    client.notify("textDocument/didOpen", %createDidOpenParams("projects/hw/hw.nim"))
    #TODO change with the actual file name it should open (but first get all tests done)
    check waitFor client.waitForNotification("window/showMessage", (json: JsonNode) => "Nimsuggest initialized for " in json["message"].jsonTo(string))
    # let helloWorldUri = 
    # let progressParam = %ProgressParams(token: fmt "Creating nimsuggest for {uriToPath(helloWorldUri)}")
    #TODO test the types instead.
    #TODO same as above. Is picking the wrong entry point
    let str = &"""Creating nimsuggest for """ 
    check waitFor client.waitForNotification("$/progress", (json: JsonNode) => str in json["token"].jsonTo(string))
    # waitFor sleepAsync(100000)
    check true
  


    

