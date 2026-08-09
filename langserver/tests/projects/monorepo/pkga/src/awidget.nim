## AWidget module — imported by pkga.nim.
## Hover on `make` at line 9, col 5.
import pkgb

type AWidget* = object
  ## A widget with a colour and a name.
  color*: Color
  name*: string

proc make*(c: Color, name: string): AWidget =
  ## Constructs an AWidget.
  AWidget(color: c, name: name)

proc describe*(w: AWidget): string =
  ## Returns a human-readable description.
  w.name & ": r=" & $w.color.r
