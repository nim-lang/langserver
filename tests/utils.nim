when (NimMajor, NimMinor, NimPatch) < (1, 7, 0):
  const defaultPragmas* = "{.noSideEffect, gcsafe, locks: 0.}"
else:
  # Locks is deprecated
  const defaultPragmas* = "{.noSideEffect, gcsafe.}"
