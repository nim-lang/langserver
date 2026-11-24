# XXX generalize and move it to nim-serialization

# Note decoding a case object of object fields is not supported.
# It would require parsing into
# a general object of all object fields made optional and then
# "guess" which object was received to construct it. Note also
# JSON fields may be in any order so a "kind" field assumed first
# to decide the type does not work in general. So, it's likely better to
# define such type as the union of all fields made optional explicitly.

{.push raises: [], gcsafe.}

import std/[macros, typetraits], json_serialization

type Null* = object

proc writeValue*(w: var JsonWriter, x: Null) {.raises: [IOError].} =
  w.writeValue(JsonString("null"))

proc readValue*(
    r: var JsonReader, x: var Null
) {.raises: [IOError, SerializationError].} =
  r.parseNull()

func jsonKinds*(T: typedesc): set[JsonValueKind] =
  when T is Null:
    {JsonValueKind.Null}
  elif T is JsonString:
    {.error: "oneOf: a JsonString member can be any JSON kind".}
  elif T is distinct:
    jsonKinds(distinctBase(T))
  elif T is bool:
    {JsonValueKind.Bool}
  elif T is SomeNumber:
    {JsonValueKind.Number}
  elif T is string:
    {JsonValueKind.String}
  elif T is seq | array:
    {JsonValueKind.Array}
  elif T is object | ref object | tuple:
    {JsonValueKind.Object}
  else:
    {.error: "oneOf: cannot tell the JSON kind of " & $T.}

type Branch = tuple[value, field: NimNode]

proc branches(T: NimNode): tuple[discriminator: NimNode, branches: seq[Branch]] =
  var impl = T.getTypeImpl
  if impl.kind == nnkBracketExpr:
    impl = impl[1].getTypeImpl
  if impl.kind == nnkRefTy:
    impl = impl[0].getTypeImpl
  impl.expectKind nnkObjectTy
  var recCase: NimNode
  for node in impl[2]:
    if node.kind == nnkRecCase:
      recCase = node
    else:
      error "oneOf: a union has only its case, no other fields", node
  if recCase.isNil:
    error "oneOf: a union is a case object", T
  result.discriminator = ident(recCase[0][0].strVal)
  for i in 1 ..< recCase.len:
    let branch = recCase[i]
    if branch.kind != nnkOfBranch or branch.len != 2:
      error "oneOf: each branch is one `of` value with one field", branch
    var fields = branch[1]
    if fields.kind == nnkRecList:
      if fields.len != 1:
        error "oneOf: each branch has exactly one field", branch
      fields = fields[0]
    fields.expectKind nnkIdentDefs
    result.branches.add (branch[0], ident(fields[0].strVal))

macro readOneOfImpl(r, x: typed, T: typedesc): untyped =
  let (discriminator, branches) = branches(T)
  result = newStmtList()
  for i in 0 ..< branches.len:
    for j in i + 1 ..< branches.len:
      let (a, b) = (branches[i].field, branches[j].field)
      let msg = newLit(
        "oneOf: " & a.strVal & " and " & b.strVal & " are read from the same JSON kind"
      )
      result.add quote do:
        when (jsonKinds(typeof(`x`.`a`)) * jsonKinds(typeof(`x`.`b`))) != {}:
          {.error: `msg`.}
  let tok = genSym(nskLet, "tok")
  result.add quote do:
    let `tok` = `r`.tokKind
  var ifStmt = nnkIfStmt.newTree()
  for (value, field) in branches:
    let construct = nnkObjConstr.newTree(
      T,
      nnkExprColonExpr.newTree(discriminator, value),
      nnkExprColonExpr.newTree(
        field,
        quote do:
          `r`.readValue(typeof(`x`.`field`)),
      ),
    )
    ifStmt.add nnkElifBranch.newTree(
      quote do:
        `tok` in jsonKinds(typeof(`x`.`field`)),
      quote do:
        `x` = `construct`,
    )
  ifStmt.add nnkElse.newTree(
    quote do:
      `r`.raiseUnexpectedValue("unexpected JSON " & $`tok` & " for " & $`T`)
  )
  result.add ifStmt

macro writeOneOfImpl(w, x: typed, T: typedesc): untyped =
  let (discriminator, branches) = branches(T)
  result = nnkCaseStmt.newTree(newDotExpr(x, discriminator))
  for (value, field) in branches:
    result.add nnkOfBranch.newTree(
      value,
      quote do:
        `w`.writeValue(`x`.`field`),
    )

proc readOneOf*[T](
    r: var JsonReader, x: var T
) {.raises: [IOError, SerializationError].} =
  mixin readValue
  readOneOfImpl(r, x, T)

proc writeOneOf*[T](w: var JsonWriter, x: T) {.raises: [IOError].} =
  mixin writeValue
  writeOneOfImpl(w, x, T)

template useOneOfReaderFor*(Flavor: type, T: type) =
  template readValue*(r: var JsonReader[Flavor], x: var T) =
    readOneOf(r, x)

template useOneOfWriterFor*(Flavor: type, T: type) =
  template writeValue*(w: var JsonWriter[Flavor], x: T) =
    writeOneOf(w, x)

template useOneOfSerializationFor*(Flavor: type, T: type) =
  useOneOfReaderFor(Flavor, T)
  useOneOfWriterFor(Flavor, T)
