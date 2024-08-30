import ../[
  nimlangserver, ls, lstransports
]
import ../protocol/types
import std/[options, unittest, json, os, jsonutils]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient


suite "Nimlangserver":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  
  test "initialize from the client should call initialized on the server":
    let initParams = InitializeParams(
        processId: some(%getCurrentProcessId()),
        rootUri: some("file:///tmp/"),
        capabilities: ClientCapabilities())
    let initializeResult = client.call("initialize", %initParams).waitFor.string.parseJson.jsonTo(InitializeResult)
    
    check initializeResult.capabilities.textDocumentSync.isSome
    
    

    

