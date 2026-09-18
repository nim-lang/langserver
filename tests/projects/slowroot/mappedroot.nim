import other

# This is a mapped root separate from the Nimble entry point, like a mapped
# entry point in a multi-entry-point project.
const busy = block:
  var x = 0
  for i in 0 ..< 20_000_000:
    x = x xor i
  x

proc root*(): int =
  other() + busy
