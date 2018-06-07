type
  EditorBuffer* = object
    path*: string
    dirtyPath*: string

  CursorPos* = object
    line*: int
    col*: int

  EditorCommandType* = enum
    GoToDef,
    Suggest

  ProjectConf* = object
    defines*: seq[string]

  ProjectConfRef* = ref ProjectConf

  EditorCommand* = object
    buffer*: EditorBuffer
    conf*: ProjectConfRef
    cursor*: CursorPos
    kind*: EditorCommandType

