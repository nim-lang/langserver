## Color type module for pkgb.
## Hover on `mix` at line 6, col 5.
type Color* = object
  ## An RGB colour with float components in [0, 1].
  r*, g*: float

proc mix*(a, b: Color): Color =
  ## Returns the average of two colours.
  Color(r: (a.r + b.r) / 2.0, g: (a.g + b.g) / 2.0)

proc isRed*(c: Color): bool =
  ## Returns true if r > 0.5 and g < 0.5.
  c.r > 0.5 and c.g < 0.5
