import std/[options, net, times]
import json_rpc/[jsonmarshal, rpcclient, router]
import chronicles
import  chronos/threadsync
import chronos

import ./queue_types

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
    query*: Option[NimsuggestQuery]
      ## Set by handlers that call queryAt/queryFile/etc.
      ## $/cancelRequest sets query.get.cancelled = true so processQueries
      ## skips the TCP dispatch and completes responseFuture with @[].

  LspDispatchItem* = object
    dispatch*: proc(): Future[void] {.gcsafe, raises: [].}
      ## Closure that calls runRpc(req, rpc). Captures the request and rpc proc
      ## so messaging_types.nim does not need to import json_rpc internals.
      ## processLspMessages asyncSpawns this without awaiting the result.
