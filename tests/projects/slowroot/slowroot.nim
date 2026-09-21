# The Nimble entry point is deliberately slow so files can be opened while
# nimsuggest is still compiling it.
const busy = block:
  var x = 0
  for i in 0 ..< 20_000_000:
    x = x xor i
  x

proc entry*(): int =
  busy
