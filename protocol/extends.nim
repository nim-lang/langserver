# TypeScript-like `interface A extends B, C`: the fields of B and C, then those of A.
# `extendsTypes` wraps the type sections; parents are looked up by name inside it.

import std/[macros, tables, sets]

proc baseName(name: NimNode): string =
  case name.kind
  of nnkIdent:
    name.strVal
  of nnkPostfix:
    baseName(name[1])
  of nnkPragmaExpr:
    baseName(name[0])
  else:
    error "extends: unexpected type name", name

proc takeExtends(typeDef: NimNode): seq[NimNode] =
  let name = typeDef[0]
  if name.kind != nnkPragmaExpr:
    return
  var pragmas = newNimNode(nnkPragma)
  for pragma in name[1]:
    if pragma.kind == nnkExprColonExpr and pragma[0].eqIdent("extends"):
      if pragma[1].kind != nnkBracket:
        error "extends: expected a list of types, as in {.extends: [A, B].}", pragma
      for parent in pragma[1]:
        if parent.kind != nnkIdent:
          error "extends: expected a type name", parent
        result.add parent
    else:
      pragmas.add pragma
  typeDef[0] =
    if pragmas.len == 0:
      name[0]
    else:
      nnkPragmaExpr.newTree(name[0], pragmas)

proc objectOf(typeDef: NimNode): NimNode =
  result = typeDef[2]
  if result.kind == nnkRefTy:
    result = result[0]
  if result.kind != nnkObjectTy:
    error "extends: " & baseName(typeDef[0]) & " is not an object", typeDef
  if result[1].kind != nnkEmpty and not result[1][0].eqIdent("RootObj"):
    error "extends: " & baseName(typeDef[0]) & " inherits from another object", typeDef

proc ownFields(typeDef: NimNode): seq[NimNode] =
  let fields = objectOf(typeDef)[2]
  if fields.kind == nnkEmpty:
    return
  for field in fields:
    case field.kind
    of nnkIdentDefs:
      result.add field
    of nnkCommentStmt, nnkEmpty:
      discard
    else:
      error "extends: " & baseName(typeDef[0]) & " has a field that is not a plain field",
        field

type Section = object
  typeDefs: Table[string, NimNode]
  parents: Table[string, seq[NimNode]]
  fields: Table[string, seq[NimNode]]
  resolving: HashSet[string]

proc fieldsOf(section: var Section, name: string, at: NimNode): seq[NimNode] =
  if name in section.fields:
    return section.fields[name]
  if name notin section.typeDefs:
    error "extends: " & name & " is not declared in this extendsTypes section", at
  if name in section.resolving:
    error "extends: " & name & " extends itself", at
  section.resolving.incl name
  let typeDef = section.typeDefs[name]
  for parent in section.parents.getOrDefault(name):
    for field in section.fieldsOf(parent.strVal, parent):
      result.add field
  for field in ownFields(typeDef):
    result.add field
  section.resolving.excl name
  section.fields[name] = result

macro extendTypes*(body: untyped): untyped =
  result = copyNimTree(body)
  var section: Section
  for stmt in result:
    if stmt.kind != nnkTypeSection:
      continue
    for typeDef in stmt:
      if typeDef.kind != nnkTypeDef:
        continue
      let name = baseName(typeDef[0])
      section.typeDefs[name] = typeDef
      let parents = takeExtends(typeDef)
      if parents.len > 0:
        if typeDef[2].kind != nnkObjectTy:
          error "extends: " & name & " must be an object", typeDef
        section.parents[name] = parents
  for name in section.parents.keys:
    let fields = newNimNode(nnkRecList)
    for field in section.fieldsOf(name, section.typeDefs[name]):
      fields.add copyNimTree(field)
    section.typeDefs[name][2][2] = fields
