import
  std/options,
  unittest2,
  json_serialization,
  json_serialization/std/options as jsoptions,
  ../protocol/extends

createJsonFlavor TestJson,
  automaticObjectSerialization = false,
  requireAllFields = true,
  omitOptionalFields = true,
  allowUnknownFields = true,
  skipNullFields = true

extendTypes:
  type
    # declared before its parents: the order in the section does not matter
    PrepareRenameParams* {.extends: [TextDocumentPositionParams, WorkDoneProgressParams].} = object

    TextDocumentPositionParams* {.extends: [TextDocumentIdentifier].} = object
      position: Position

    TextDocumentIdentifier* = object
      uri: string

    WorkDoneProgressParams* = object
      workDoneToken: Option[string]

    Position* = object
      line: int

    Meta* = object
      meta {.serializedFieldName: "_meta".}: Option[int]

    WithMeta* {.extends: [Meta].} = object
      name*: string

    Exported* = object
      field*: int

    FromExported* {.extends: [Exported].} = object

  type InAnotherSection* {.extends: [Position].} = object
    column: int

TestJson.useDefaultSerializationFor(Position)
TestJson.useDefaultSerializationFor(TextDocumentPositionParams)
TestJson.useDefaultSerializationFor(PrepareRenameParams)
TestJson.useDefaultSerializationFor(WithMeta)
TestJson.useDefaultSerializationFor(InAnotherSection)

suite "extendsTypes":
  test "the fields of every parent come first, in order, then its own":
    check TestJson.encode(
      TextDocumentPositionParams(uri: "file:///a.nim", position: Position(line: 1))
    ) == """{"uri":"file:///a.nim","position":{"line":1}}"""

  test "the fields of a parent's parents are included":
    let params = PrepareRenameParams(
      uri: "file:///a.nim", position: Position(line: 1), workDoneToken: some "t"
    )
    check TestJson.encode(params) ==
      """{"uri":"file:///a.nim","position":{"line":1},"workDoneToken":"t"}"""

  test "the fields of the parents are read":
    let params = TestJson.decode(
      """{"position": {"line": 2}, "uri": "file:///b.nim"}""", PrepareRenameParams
    )
    check params.uri == "file:///b.nim"
    check params.workDoneToken.isNone
    check params.position.line == 2

  test "a required field of a parent is required":
    expect SerializationError:
      discard TestJson.decode("""{"position": {"line": 2}}""", PrepareRenameParams)

  test "the pragmas of a parent field are kept":
    check TestJson.encode(WithMeta(meta: some 1, name: "n")) == """{"_meta":1,"name":"n"}"""

  test "a type can have only the fields of its parent":
    check FromExported(field: 3).field == 3

  test "a parent from another type section inside extendsTypes is found":
    check TestJson.encode(InAnotherSection(line: 1, column: 2)) ==
      """{"line":1,"column":2}"""

  test "a valid type compiles":
    check compiles(
      block:
        extendTypes:
          type
            P = object
              p: int
            X {.extends: [P].} = object
              x: int
    )

  test "a parent outside extendsTypes does not compile":
    check not compiles(
      block:
        extendTypes:
          type X {.extends: [Position].} = object
    )

  test "a parent that is not an object does not compile":
    check not compiles(
      block:
        extendTypes:
          type
            P = int
            X {.extends: [P].} = object
    )

  test "a parent that inherits from another object does not compile":
    check not compiles(
      block:
        extendTypes:
          type
            A = object of RootObj
              a: int
            B = object of A
              b: int
            X {.extends: [B].} = object
    )

  test "a parent with a case does not compile":
    check not compiles(
      block:
        extendTypes:
          type
            P = object
              case kind: bool
              of true: x: int
              of false: y: int
            X {.extends: [P].} = object
    )

  test "a type that extends but is not an object does not compile":
    check not compiles(
      block:
        extendTypes:
          type
            P = object
              p: int
            X {.extends: [P].} = ref object
    )

  test "a type that extends itself does not compile":
    check not compiles(
      block:
        extendTypes:
          type
            A {.extends: [B].} = object
            B {.extends: [A].} = object
    )

  test "a field declared by a parent too does not compile":
    check not compiles(
      block:
        extendTypes:
          type
            P = object
              p: int
            X {.extends: [P].} = object
              p: int
    )
