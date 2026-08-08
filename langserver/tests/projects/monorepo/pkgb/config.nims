# No inter-package deps; pkgb only uses stdlib.
when fileExists("nimble.paths"):
  include "nimble.paths"
