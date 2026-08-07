## AOrphan module — NOT imported by pkga.nim.
## Used to test cross-project standalone (#18, #19).
## Hover on `orphanColor` at line 9, col 5.
import pkgb

type AOrphan* = object
  ## An orphaned coloured object.
  color*: Color

proc orphanColor*(): Color =
  ## Returns a neutral grey colour.
  Color(r: 0.5, g: 0.5)

proc describeOrphan*(o: AOrphan): string =
  ## Returns a string representation.
  "orphan:" & $o.color.r
