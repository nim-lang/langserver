import
  json, asyncdispatch, json_rpc/streamconnection, os,
  faststreams/async_backend,
  faststreams/inputs,
  faststreams/textio,
  faststreams/outputs,
  faststreams/asynctools_adapters

# let input = fileInput(system.stdin)
# sleep(1000)

# let input = asyncWrap(stdout.getFileHandle(), stdin.getFileHandle());
# echo readableNow(asyncPipeInput(input))

# echo waitFor readLine(asyncPipeInput(input))

# echo waitFor readLine(asyncPipeInput(stdin.getFileHandle()))

# echo readableNow(fileInput(stdin).s)
# echo waitFor readLine(Async(fileInput(stdin).s))
# echo readLine(stdin)

proc echo(params: JsonNode): Future[RpcResult] {.async,
    raises: [CatchableError, Exception].} =
  echo "|||||"
  return some(StringOfJson($params))

# let a = stdin.getFileHandle()
# echo a

# let output = fileOutput(system.stdout)

# let aas = Async(fileInput(stdin));

# let outputStream = Async(fileOutput(stdout).s)

let inputStream = fileInput("/home/yyoncho/aa.txt")
echo readLine(inputStream)

# let pipe

# let outputStream = Async(fileOutput(stdout).s)

# proc foo(i: AsyncInputStream ): Future[bool] {.async} =
#    let a = i.readable
#    return a

# proc readAllAndClose(s: InputStream): seq[byte] =
#   while s.readable:
#     result.add s.read

#   close(s)

# echo "XXX", readAllAndClose(fileInput("/home/yyoncho/aa.txt"))


# let inputStreamF = fileInput("/home/yyoncho/aa.txt")

# echo "XXX", readLine(inputStream)

# let connection = StreamConnection.new(inputStream, outputStream);
# connection.register("echo", echo)
# waitFor connection.start();
# sleep(1000)

# echo "2"
