## Testsuit for flatdb
## 
## TODO - figure out how to get tests working with aysnc calls

import nimvscode/flatdbnode, unittest
import nimvscode/jsNode, nimvscode/jsNodeFs

suite "flatdb test":
  setup:
    var tst = jsonParse("""{"foo": 1}""")
    var tst2 = jsonParse("""{"foo": 2}""")
    var tstStr = jsonParse("""{"foo": "a string!!"}""")
    var tstFloat = jsonParse("""{"foo": 1.337}""")
    var tstOther = jsonParse("""{"rix": 1.337}""")
  teardown:
    fs.unlinkSync("test.db")
    fs.unlinkSync("test.db.bak")

  test "basic tests":
    var db = newFlatDb("tests.db")
    assert db.nodes.len == 0

    var eid = db.append(tst)
    assert db[eid] == tst
    assert db.len == 1
    assert db.nodes.len == 1
    assert db.query(qs().lim(1), equal("foo", 1)) == @[tst]
    assert db.queryReverse(qs().lim(1), equal("foo", 1)) == @[tst]
    assert db.query(qs().lim(0), equal("foo", 1)) == @[]
    assert db.query(qs().skp(1), equal("foo", 1)) == @[]
    assert db.query(qs().skp(0).lim(0), equal("foo", 1)) == @[]
    assert db.query(qs().skp(0).lim(1), equal("foo", 1)) == @[tst]
    assert db.exists(eid)
    assert db.exists(equal("foo", 1))
    assert db.notExists(equal("foo", 2))
    assert db.exists(lower("foo", 2) and higher("foo", 0))

    var eidStr = db.append(tstStr)
    assert db.query(dbcontains("foo", "string")) == @[tstStr]

    var eidFloat = db.append(tstFloat)
    assert db.exists(between("foo", 1.0, 2.0))
    assert db.exists(between("foo", 0, 2))

    assert not db.exists(has("rix"))
    var eidOther = db.append(tstOther)
    assert db.exists(has("rix"))
    db.close()

  test "load/store":
    var db = newFlatDb("tests.db")
    discard db.load()
    db.drop()
    discard db.append(tst)
    discard db.append(tst)
    db.flush()
    check readFile("tests.db").strip().splitLines().len == 2

  test "filters":
    var db = newFlatDb("tests.db")
    var eid1 = db.append(tst)
    var eid2 = db.append(tst2)
    db.keepIf(lower("foo", 2))
    assert db.nodes.len() == 1
    assert db[eid1] == tst

    db.delete(eid1)
    assert db.nodes.len() == 0
    db.close()

  test "write and preserves order":
    # fast write test
    let howMany = 10
    var db = newFlatDb("test.db", false)
    db.drop()
    var ids = newSeq[EntryId]()
    for each in 0..howMany:
      var entry = jsonStr {"foo": each}
      ids.add db.append(entry)
    db.close()

    # Now read everything again and check if its good
    db = newFlatDb("test.db", false)
    assert true == db.load()
    var cnt = 0
    for id in ids:
      var entry = jsonStr {"foo": cnt}
      assert db.nodes[id] == entry
      cnt.inc

    # Test if table preserves order
    var idx = 0
    for each in db.nodes.values():
      var entry = jsonStr {"foo": idx}
      assert each == entry
      idx.inc
    db.close()

  test "keep if with custom matcher proc":
    var db = newFlatDb("test.db", false)
    db.drop()

    for each in 1..100:
      var entry = jsonStr {"foo": each}
      discard db.append(entry)
    db.close()

    db.keepIf(proc(x: JsonNode): bool = return x["foo"].getInt mod 2 == 0)
    assert db.nodes.len == 50

    db.keepIf(proc(x: JsonNode): bool = return x["foo"].getInt mod 2 != 0)
    assert db.nodes.len == 0

    db.close()

  test "reversing and limits":
    block:
      var db = newFlatDb("test.db", false)
      db.drop()

      var entry1 = jsonStr {"user": "sn0re", "id": 1}
      discard db.append(entry1)

      var entry2 = jsonStr {"user": "sn0re", "id": 2}
      discard db.append(entry2)

      var entry3 = jsonStr {"user": "sn0re", "id": 3}
      discard db.append(entry3)

      var entry4 = jsonStr {"user": "sn0re", "id": 4}
      discard db.append(entry4)


      assert db.queryReverse(qs().lim(2).skp(2), equal("user", "sn0re")) == [
          entry2, entry1
      ]

      assert db.queryReverse(qs().lim(2).skp(2), equal("user",
          "sn0re")).reversed() == [entry1, entry2
      ]

      assert db.queryReverse(qs().lim(2), equal("user", "sn0re")) == [
          entry4, entry3
      ]

      assert db.queryReverse(qs().lim(2), equal("user", "sn0re")).reversed() ==
          [entry3, entry4
      ]
      db.close()

  test "update":
    # an example of an "update"
    var db = newFlatDb("test.db", false)
    db.drop()

    # testdata
    var entry: JsonNode
    entry = jsonStr {"user": "sn0re", "password": "asdflkjsaflkjsaf"}
    discard db.append(entry)

    entry = jsonStr {"user": "klaus", "password": "hahahahsdfksafjj"}
    let id = db.append(entry)

    # The actual update
    db.nodes[id]["password"] = % "123"
    db.flush()
    db.close()

    # Test if preserved to disk
    db = newFlatDb("test.db", false)
    discard db.load()
    assert db.nodes[id]["password"] == % "123"
    db.close()

    # Test again (no flush was called before)
    db = newFlatDb("test.db", false)
    discard db.load()
    assert db.nodes[id]["password"] == % "123"
    db.close()

  test "abstracted real world testcase":
    ## a similar query was used in a login proc
    var db = newFlatDb("test.db", false)
    db.drop()

    # testdata
    var entry: JsonNode
    entry = jsonStr {"user": "sn0re", "password": "pw1"}
    discard db.append(entry)

    entry = jsonStr {"user": "sn0re", "password": "pw2"}
    discard db.append(entry)

    entry = jsonStr {"user": "sn0re", "password": "pw3"}
    discard db.append(entry)

    entry = jsonStr {"user": "klaus", "password": "asdflkjsaflkjsaf"}
    discard db.append(entry)

    entry = jsonStr {"user": "uggu", "password": "asdflkjsaflkjsaf"}
    discard db.append(entry)

    assert db.query((equal("user", "sn0re") and equal("password", "pw2")))[0][
        "password"].getStr == "pw2"
    let res = db.query((equal("user", "sn0re") and (equal("password", "pw2") or
        equal("password", "pw1"))))
    assert res[0]["password"].getStr == "pw1"
    assert res[1]["password"].getStr == "pw2"
    db.close()

  test "another abstracted real world testcast":
    var db = newFlatDb("test.db", false)
    db.drop()

    var entry1 = jsonStr {"user": "sn0re", "timestamp": 10.0}
    discard db.append(entry1)

    var entry2 = jsonStr {"user": "sn0re", "timestamp": 100.0}
    discard db.append(entry2)

    var entry3 = jsonStr {"user": "klaus", "timestamp": 200.0}
    discard db.append(entry3)

    var entry4 = jsonStr {"user": "klaus", "timestamp": 250.0}
    discard db.append(entry4)

    assert @[entry3, entry4] == db.query higher("timestamp", 150.0)
    assert @[entry3] == db.query higher("timestamp", 150.0) and lower(
        "timestamp", 210.0)
    assert @[entry2] == db.query equal("user", "sn0re") and (higher("timestamp",
        20.0) and (lower("timestamp", 210.0)))

    var res = db.query(not(equal("user", "sn0re")))
    assert res[0] == db[res[0]["_id"].getStr]
    db.close()

  test "custom query, with array access":
    var db = newFlatDb("test.db", false)
    assert db.load() == true

    var entry1 = jsonStr {"some": "json", "things": [1, 2]}
    discard db.append(entry1)

    var entry2 = jsonStr {"some": "json"}
    discard db.append(entry2)

    var entry3 = jsonStr {"hahahahahahhaha": "json", "things": [1, 2, 3]}
    discard db.append(entry3)

    proc m1(m: JsonNode): bool =
      # a custom query example
      if not m.hasKey("things"):
        return false
      if m["things"].len <= 2:
        return false
      if m["things"][1].getInt == 2:
        return true
      return false
    assert @[entry3] == db.query(m1)
    db.close()

  test "upsert by id":
    var db = newFlatDb("test.db", false)
    assert db.load() == true
    db.drop()
    let entry1 = jsonStr {"user": "sn0re", "timestamp": 10.0}
    let entry1Id = db.append(entry1)
    let entry2 = jsonStr {"user": "peter", "timestamp": 10.0}
    check entry1Id == db.upsert(entry2, entry1Id)
    check db[entry1Id]["user"].getStr() == "peter"

  test "upsert by matcher":
    var db = newFlatDb("test.db", false)
    assert db.load() == true
    db.drop()
    let entry1 = jsonStr {"user": "sn0re", "timestamp": 10.0}
    let entry1Id = db.append(entry1)
    let entry2 = jsonStr {"user": "peter", "timestamp": 10.0}
    check entry1Id == db.upsert(entry2, equal("user", "sn0re"))
    check db[entry1Id]["user"].getStr() == "peter"

  test "all":
    var db = newFlatDb("test.db", false)
    assert db.load() == true
    db.drop()
    let entry1 = jsonStr {"user": "sn0re", "timestamp": 10.0}
    let entry2 = jsonStr {"user": "peter", "timestamp": 10.0}
    db.append(entry1)
    db.append(entry2)
    check toSeq(db.items) == @[entry1, entry2]
    check toSeq(db.items(qs().skp(1))) == @[entry2]
    check toSeq(db.itemsReverse) == @[entry2, entry1]
    check toSeq(db.itemsReverse(qs().skp(1))) == @[entry1]

  ### TODO ?
  # test "upsertMany by matcher":
  #   var db = newFlatDb("test.db", false)
  #   assert db.load() == true
  #   db.drop()
  #   let entry1 = jsonStr {"user":"sn0re", "timestamp": 10.0}
  #   let entry1Id = db.append(entry1)
  #   let entry2 = jsonStr {"user":"peter", "timestamp": 10.0}
  #   check entry1Id == db.upsert(entry2, equal("user", "sn0re"))
  #   check db[entry1Id]["user"].getStr() == "peter"

  # test "matcher":
  #   var tt1 = jsonStr {"foo": 1}
  #   var tt2 = jsonStr {"foo": "raxrax"}
  #   var tt3 = jsonStr {"foo": "1"}
  #   var tt4 = jsonStr {"foo": 1}
  #   var tt5 = jsonStr {"foo": 1}
  #   discard db.append(tt1)
  #   discard db.append(tt2)
  #   discard db.append(tt3)
  #   discard db.append(tt4)
  #   discard db.append(tt5)
  # block:
  # TODO save some fun for later
  # var db = newFlatDb("tests.db")
  # var tst = jsonStr {"foo": 1}
  # var tst2 = jsonStr {"foo": 2}
  # var eid = db.append( tst )
  # var eid2 = db.append( tst2 )
  # db.len ==
  # db.close()

  # assert @[entry1, entry2] == db[eid]
  # assert @[entry1, entry2] == repr db.getNode(eid)
