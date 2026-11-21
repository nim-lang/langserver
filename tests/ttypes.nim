import unittest2, ../protocol/types

suite "decoding cancel params":
  test "a number id is decoded as a number":
    let id = LspJson.decode("""{"id": 5}""", CancelParams).id
    check id.kind == riNumber and id.num == 5

  test "a string id is decoded as a string":
    let id = LspJson.decode("""{"id": "abc"}""", CancelParams).id
    check id.kind == riString and id.str == "abc"

  test "a missing id is rejected":
    expect SerializationError:
      discard LspJson.decode("{}", CancelParams)

suite "diagnostic code":
  test "a number code is decoded as a number":
    let code = LspJson.decode("5", NumOrStr)
    check code.kind == nosNum and code.num == 5

  test "a string code is decoded as a string":
    let code = LspJson.decode("\"UnusedImport\"", NumOrStr)
    check code.kind == nosStr and code.str == "UnusedImport"

  test "a code that is neither is rejected":
    expect SerializationError:
      discard LspJson.decode("true", NumOrStr)

  test "a code is encoded as a number or a string":
    check LspJson.encode(NumOrStr(kind: nosNum, num: 5)) == "5"
    check LspJson.encode(NumOrStr(kind: nosStr, str: "UnusedImport")) == "\"UnusedImport\""

suite "decoding a uinteger":
  test "0 and 2^31 - 1 are accepted":
    check LspJson.decode("0", uinteger).int == 0
    check LspJson.decode("2147483647", uinteger).int == 2147483647

  test "a negative value is rejected":
    expect SerializationError:
      discard LspJson.decode("-1", uinteger)

  test "a value above 2^31 - 1 is rejected":
    expect SerializationError:
      discard LspJson.decode("2147483648", uinteger)

  test "a position with an out of range field is rejected":
    expect SerializationError:
      discard LspJson.decode("""{"line": -1, "character": 0}""", Position)

  test "a uinteger is encoded as a number":
    check LspJson.encode(uinteger(5)) == "5"
