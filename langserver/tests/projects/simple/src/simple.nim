## Entry point for the simple test project.
## Imports widget so nimsuggest can resolve Widget and area().
import ./[widget]

proc makeWidget*(x, y: int): Widget =
  ## Create a widget with given dimensions.
  Widget(x: x, y: y)

proc run*(): int =
  ## Run the simple project; returns area of a 3x4 widget.
  makeWidget(3, 4).area()
