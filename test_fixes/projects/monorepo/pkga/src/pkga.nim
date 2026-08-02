## Package A entry point.
## Imports pkgb and awidget.
import pkgb
import ./[awidget]

proc run*(): AWidget =
  ## Creates a default red widget.
  make(red(), "default")

proc blendWidgets*(a, b: AWidget): AWidget =
  ## Blends two widgets by averaging their colours.
  make(mix(a.color, b.color), a.name & "+" & b.name)
