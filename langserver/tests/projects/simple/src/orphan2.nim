## Orphan2 module — NOT imported by simple.nim.
## Used to trigger fix #19 cascade prevention (second unimported file).
## Hover on `shout` at line 7, col 5.
type Orphan2* = object
  ## A second orphaned value holder.
  label*: string

proc shout*(o: Orphan2): string =
  ## Returns the label in uppercase with exclamation.
  o.label & "!"

proc whisper*(o: Orphan2): string =
  ## Returns the label in lowercase.
  o.label & "..."
