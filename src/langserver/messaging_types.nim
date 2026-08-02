import std/[options, net, times]
import json_rpc/[jsonmarshal, rpcclient, router]
import chronicles
import  chronos/threadsync

type
  CommandLineParams* = object
    clientProcessId*: Option[int]
    mode*: Option[ServerMode]
    transport*: Option[TransportMode]
    port*: Port #only for sockets

  ServerMode* = enum
    lsp = "lsp"
    mcp = "mcp"

  TransportMode* = enum
    stdio = "stdio"
    socket = "socket"

  ReadStdinContext* = object
    onStdReadSignal*: ThreadSignalPtr #used by the thread to notify it read from the std
    onMainReadSignal*: ThreadSignalPtr
      #used by the main thread to notify it read the value from the signal
    value*: cstring

  PendingRequestState* = enum
    prsOnGoing = "OnGoing"
    prsCancelled = "Cancelled"
    prsComplete = "Complete"

  PendingRequest* = object
    id*: uint
    name*: string
    request*: Future[JsonString]
    projectFile*: Option[string]
    startTime*: DateTime
    endTime*: DateTime
    state*: PendingRequestState
    