# The nimble entry point. Slow to compile so nimsuggest takes long to start
const busy = block:
  var x = 0
  for i in 0 ..< 20_000_000:
    x = x xor i
  x

proc entry*(): int =
  busy
