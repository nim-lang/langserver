import osproc, streams, json, base_protocol

type
  LspClient = object
    server: Process
    serverInput, serverOutput: Stream

proc initLspClient*(serverExe = "nls"): LspClient =
  result.server = startCmd(serverExe)
  result.serverInput = result.server.inputStream
  result.serverOutput = result.server.outputStream

proc sendFrame*(c: LspClient, frame: string) =
  c.serverInput.write "Content-Length: ", frame.len, "\r\n\r\n",
                      frame, "\r\n\r\n"
  c.serverInput.flush

proc sendJson*(c: LspClient, data: JsonNode) =
  var frame = newStringOfCap(1024)
  toUgly(frame, data)
  c.sendFrame(frame)

proc readFrame*(c: LspClient): JsonNode =
  let s = c.serverOutput.readFrame
  result = parseJson($s)

iterator frames*(c: LspClient): JsonNode =
  while true:
    try:
      yield c.readFrame
    except EOFError:
      break

