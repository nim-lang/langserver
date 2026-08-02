## Widget module — imported by simple.nim.
## Hover on `area` at line 7, col 5.
## Hover on `Widget` at line 4, col 5.
type Widget* = object
  ## A rectangular widget.
  x*, y*: int

proc area*(w: Widget): int =
  ## Returns the area of the widget.
  w.x * w.y

proc perimeter*(w: Widget): int =
  ## Returns the perimeter of the widget.
  2 * (w.x + w.y)
