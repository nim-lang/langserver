import
  std/options,
  unittest2,
  json_serialization,
  json_serialization/std/options as jsoptions,
  ../protocol/oneof

createJsonFlavor TestJson,
  automaticObjectSerialization = false,
  requireAllFields = true,
  omitOptionalFields = true,
  allowUnknownFields = true,
  skipNullFields = false

type
  Options = ref object of RootObj
    delta: Option[bool]

  NumStrBoolKind = enum
    nsbNum
    nsbStr
    nsbBool

  NumStrBool = object
    case kind: NumStrBoolKind
    of nsbNum: num: int
    of nsbStr: str: string
    of nsbBool: boolean: bool

  BoolOrKind = enum
    boBool
    boValue

  BoolOr[T] = object
    case kind: BoolOrKind
    of boBool: boolean: bool
    of boValue: value: T

  NumOrNullKind = enum
    nonNull
    nonNum

  NumOrNull = object
    case kind: NumOrNullKind
    of nonNull: null: Null
    of nonNum: num: int

  NullHolder = object
    value: NumOrNull

  TwoNullsKind = enum
    tnA
    tnB

  TwoNulls = object
    case kind: TwoNullsKind
    of tnA: a: Null
    of tnB: b: Null

  Holder = object
    first: NumStrBool
    second: Option[BoolOr[Options]]

  ObjectA = object
    a: int

  ObjectB = object
    b: int

  TwoObjectsKind = enum
    toA
    toB

  TwoObjects = object
    case kind: TwoObjectsKind
    of toA: a: ObjectA
    of toB: b: ObjectB

TestJson.useDefaultSerializationFor(Options)
TestJson.useDefaultSerializationFor(ObjectA)
TestJson.useDefaultSerializationFor(ObjectB)
TestJson.useOneOfSerializationFor(NumStrBool)
TestJson.useOneOfSerializationFor(NumOrNull)
TestJson.useDefaultSerializationFor(NullHolder)

proc readValue[T](
    r: var JsonReader[TestJson], x: var BoolOr[T]
) {.raises: [IOError, SerializationError].} =
  readOneOf(r, x)

proc writeValue[T](w: var JsonWriter[TestJson], x: BoolOr[T]) {.raises: [IOError].} =
  writeOneOf(w, x)

TestJson.useDefaultSerializationFor(Holder)

suite "oneOf":
  test "the member is picked by the kind of the JSON value":
    let num = TestJson.decode("5", NumStrBool)
    check num.kind == nsbNum and num.num == 5
    let str = TestJson.decode("\"x\"", NumStrBool)
    check str.kind == nsbStr and str.str == "x"
    let boolean = TestJson.decode("true", NumStrBool)
    check boolean.kind == nsbBool and boolean.boolean

  test "the member that is set is written without a tag":
    check TestJson.encode(NumStrBool(kind: nsbNum, num: 5)) == "5"
    check TestJson.encode(NumStrBool(kind: nsbStr, str: "x")) == "\"x\""
    check TestJson.encode(NumStrBool(kind: nsbBool, boolean: false)) == "false"

  test "a union inside an object is written as its member, with no kind":
    let holder = Holder(
      first: NumStrBool(kind: nsbStr, str: "x"),
      second: some BoolOr[Options](kind: boValue, value: Options(delta: some true)),
    )
    check TestJson.encode(holder) == """{"first":"x","second":{"delta":true}}"""

  test "a JSON kind no member is read from is rejected":
    expect SerializationError:
      discard TestJson.decode("[1]", NumStrBool)
    expect SerializationError:
      discard TestJson.decode("{}", NumStrBool)

  test "a generic union reads its object member, in any field order":
    let holder =
      TestJson.decode("""{"second": {"delta": true}, "first": 1}""", Holder)
    check holder.first.num == 1
    check holder.second.get.kind == boValue
    check holder.second.get.value.delta == some true

  test "a generic union reads its boolean member":
    let holder = TestJson.decode("""{"first": "a", "second": false}""", Holder)
    check holder.second.get.kind == boBool and not holder.second.get.boolean

  test "two members read from the same JSON kind do not compile":
    check not compiles(
      block:
        var r: JsonReader[TestJson]
        var x: TwoObjects
        readOneOf(r, x)
    )

  test "a Null member is JSON null":
    check TestJson.encode(NumOrNull(kind: nonNull)) == "null"
    check TestJson.encode(NumOrNull(kind: nonNum, num: 3)) == "3"
    check TestJson.decode("null", NumOrNull).kind == nonNull
    check TestJson.decode("3", NumOrNull).num == 3

  test "a null member of an object field is read and written":
    check TestJson.encode(NullHolder()) == """{"value":null}"""
    check TestJson.decode("""{"value": null}""", NullHolder).value.kind == nonNull
    check TestJson.decode("""{"value": 4}""", NullHolder).value.num == 4

  test "a missing null member is rejected":
    expect SerializationError:
      discard TestJson.decode("{}", NullHolder)

  test "two Null members do not compile":
    check not compiles(
      block:
        var r: JsonReader[TestJson]
        var x: TwoNulls
        readOneOf(r, x)
    )