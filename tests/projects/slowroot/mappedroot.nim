import other

# Make this `projectMapping` root. Slow comptime operation to make nimsuggest slow to start.
const busy = block:
  var x = 0
  for i in 0 ..< 20_000_000:
    x = x xor i
  x

proc root*(): int =
  other() + busy
