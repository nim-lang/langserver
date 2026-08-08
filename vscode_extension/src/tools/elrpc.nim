import platform/js/[jsNode, jsNodeNet, jsNodeUtil, jsString, jsPromise]

import std/[jsffi, jscore, jsconsole]
from std/strformat import fmt

import nimsuggest/sexp

# Reference: https://github.com/kiwanami/node-elrpc/blob/master/lib/elrpc.js

type
  QueueState {.pure.} = enum
    blocked
    flowing

  EPCPeer* = ref object
    id: cint
    socket: NetSocket
    receivedBuffer: Buffer
    sessions: Map[cint, proc(data: seq[SExpNode]): void]
    socketClosed: bool
    queueState: QueueState
    queue: seq[cstring]

var uidSeq: cint = 0

proc envelop(content: cstring): cstring =
  var
    strLen = content.len
    length = util.newTextEncoder().encode(content).len
    hexLength = ("000000" & length.toString(16))[^6 ..^ 1]
  console.log(
    fmt"strLen:{strLen}, length:{length}, hexLength:{hexLength}, content:{content}".cstring
  )
  return hexLength & content

proc generateUid(epc: EPCPeer): cint =
  inc uidSeq
  return uidSeq

proc write(epc: EPCPeer, msg: cstring): void =
  if epc.socketClosed:
    return # ignore the rest
  case epc.queueState
  of blocked:
    console.log(epc.id, "blocked write - queueing msg:", msg)
    epc.queue.add(msg)
  of flowing:
    var expectedBytes = epc.socket.bytesWritten + msg.len
    console.log(epc.id, fmt"flowing write {expectedBytes} msg:".cstring, msg)
    var flushed = epc.socket.write(msg)
    if expectedBytes != epc.socket.bytesWritten:
      console.error(
        epc.id,
        fmt"Bytes written expected {expectedBytes}, actual {epc.socket.bytesWritten}".cstring,
      )
    if not flushed:
      console.log(epc.id, "write blocked")
      epc.queueState = QueueState.blocked

proc onDrain(epc: EPCPeer): void =
  case epc.queueState
  of blocked:
    console.log(epc.id, "onDrain - writes unblocked, queue len:", epc.queue.len)
    epc.queueState = flowing
    while epc.queueState == flowing and epc.queue.len > 0:
      var msg = epc.queue[0]
      epc.queue.delete(0)
      epc.write(msg)
  of flowing:
    console.log(epc.id, "onDrain - noop - writes not blocked")
    discard

proc newEPCPeer(id: cint, socket: NetSocket): EPCPeer =
  var epc = EPCPeer(
    id: id,
    socket: socket,
    receivedBuffer: bufferAlloc(0),
    sessions: newMap[cint, proc(d: seq[SExpNode])](),
    socketClosed: false,
    queueState: QueueState.flowing,
    queue: @[],
  )

  epc.socket.onData(
    proc(data: Buffer) =
      if data.toJs().to(bool):
        epc.receivedBuffer =
          bufferConcat(newArrayWith[Buffer](epc.receivedBuffer, data))
      while epc.receivedBuffer.len > 0:
        if epc.receivedBuffer.len >= 6:
          var length = parseCint(epc.receivedBuffer.toStringUtf8(0, 6), 16)
          if epc.receivedBuffer.len >= (length + 6):
            try:
              console.log(epc.id, "onData - receieved")
              var content = parseSexp($(epc.receivedBuffer.toStringUtf8(6, 6 + length)))
              if not content.isNil():
                var contentSexp: seq[SExpNode] = content.getElems()
                var guid = cint(contentSexp[1].getNum())
                var handle = epc.sessions[guid]
                console.log(
                  fmt"{epc.id} onData - handling:{guid} length:{length}".cstring
                )
                handle(contentSexp)
                epc.sessions.delete(guid)
            except:
              for session in epc.sessions.values():
                session("Received invalid SExp data".toJs().to(seq[SexpNode]))
            finally:
              epc.receivedBuffer = epc.receivedBuffer.slice(6 + length)
          else:
            # input not complete, wait for input
            console.log(
              epc.id,
              "onData - incomplete data, current:",
              epc.receivedBuffer.len,
              "required:",
              length + 6,
              "preview:",
              epc.receivedBuffer.toStringUtf8(
                0, cint(Math.min(50, Math.max(epc.receivedBuffer.len, 6)))
              ),
            )
            return
        else:
          # wait for more input
          console.log(epc.id, "onData - no hexbytes, current:", epc.receivedBuffer.len)
          return
  )

  epc.socket.onDrain(
    proc(): void =
      epc.onDrain()
  )

  epc.socket.onClose(
    proc(error: bool) =
      if error:
        console.error(epc.id, "Connection closed due to an error")
      else:
        console.log(epc.id, "Connection closed")
      epc.socket.destroy()
      for session in epc.sessions.values():
        session("Connection closed".toJs().to(seq[SexpNode]))
      epc.socketClosed = true
      epc.queue = @[]
      epc.queueState = QueueState.blocked
  )

  return epc

proc callMethod*(
    epc: EPCPeer, meth: cstring, params: seq[SExpNode]
): Promise[seq[SExpNode]] =
  return newPromise(
    proc(resolve: proc(data: seq[SExpNode]), reject: proc(reason: JsObject)) =
      if epc.socketClosed:
        reject("Connection closed".toJs())

      var guid = epc.generateUid()
      var payload = fmt"(call {guid} {meth} {$(sexp(params))})"
      epc.sessions[guid] = proc(data: seq[SExpNode]) =
        if not data.toJs().isJsArray():
          reject(data.toJs())
        else:
          case (data[0].getSymbol())
          of "return":
            resolve(data[2].getElems())
          of "return-error", "epc-error":
            reject(data[2].toJs())
          else:
            console.error("Unknown error handling sexp")

      epc.write(envelop(payload.cstring))
  )

proc stop*(epc: EPCPeer): void =
  console.log(epc.id, "stop epc peer")
  if not epc.socketClosed:
    epc.socket.`end`()

proc startClient*(id, port: cint): Promise[EPCPeer] =
  return newPromise(
    proc(resolve: proc(e: EPCPeer), reject: proc(reason: JsObject)) =
      try:
        var socket: NetSocket
        socket = net.createConnection(
          port,
          "localhost",
          proc() =
            resolve(newEPCPeer(id, socket)),
        )
      except:
        console.error(
          "Failed to start client with message: '",
          getCurrentExceptionMsg().cstring,
          "' see exception:",
          getCurrentException(),
        )
        reject(getCurrentException().toJs())
  )
