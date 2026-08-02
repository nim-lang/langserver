## Package B entry point.
## Imports and re-exports btypes.
import ./[btypes]
export btypes

proc red*(): Color =
  ## Returns a pure red colour.
  Color(r: 1.0, g: 0.0)

proc green*(): Color =
  ## Returns a pure green colour.
  Color(r: 0.0, g: 1.0)
