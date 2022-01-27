import
  faststreams/async_backend,
  faststreams/textio,
  faststreams/inputs,
  faststreams/outputs,
  faststreams/asynctools_adapters,
  strutils,
  os,
  asyncdispatch,
  asynctools/asyncproc,
  faststreams/asynctools_adapters,
  faststreams/textio

proc send(output: AsyncOutputStream): Future[void] {.async} =
  write(OutputStream(output), "sug /home/yyoncho/Sources/nim/langserver/tests/projects/hw/hw.nim:1:0\n")
  flush(output)


proc processOutput(input: AsyncInputStream): Future[void] {.async} =
  while input.readable:
    let line = await input.readLine();
    echo ">>>>>>> ", line
  echo "Done........."

let process = startProcess(command = "nimsuggest --stdin --find /home/yyoncho/Sources/nim/langserver/tests/projects/hw/hw.nim",
                           workingDir = getCurrentDir(),
                           options = {poUsePath, poEvalCommand})

let input = asyncPipeInput(process.outputHandle)
let output = asyncPipeOutput(process.inputHandle, allowWaitFor = true)


# waitFor send(output)
echo "Before"
waitFor processOutput(input)
echo "After"
waitFor processOutput(input)
