## Orphan module — NOT imported by simple.nim.
## Used to trigger fix #18 standalone nimsuggest path.
## Hover on `double` at line 7, col 5.
type Orphan* = object
  ## An orphaned value holder.
  val*: float

proc double*(o: Orphan): float =
  ## Returns twice the value.
  o.val * 2.0

proc square*(o: Orphan): float =
  ## Returns the square of the value.
  o.val * o.val
