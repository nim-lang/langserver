#
#
#                     flatdb
#        (c) Copyright 2017 David Krause
#
#    See the file "licence", included in this
#    distribution, for details about the copyright.
#
#    Port by Saem

## flat db table
## double linked list with table indexes on the values
import std/[lists, tables, jsffi]

type
  FlatDbString* = cstring
  FlatDbInt* = cint
  Node* = DoublyLinkedNode[Entry]
  Entry* = tuple[key: cstring, value: JsObject]
  FlatDbTableData = DoublyLinkedList[Entry]
  FlatDbTableIndex = Table[cstring, Node]
  FlatDbTableId = cstring
  FlatDbTable* = ref object
    data: FlatDbTableData
    index: FlatDbTableIndex
    size: cint

proc newFlatDbTable*(): FlatDbTable =
  result = FlatDbTable()
  result.data = initDoublyLinkedList[Entry]()
  result.size = 0
  result.index = initTable[cstring, Node]()

proc `[]`*(table: FlatDbTable, key: cstring): JsObject =
  return table.index[key].value[1]

proc `[]=`*(table: FlatDbTable, key: cstring, value: JsObject) =
  table.data.append((key, value))
  table.index[key] = table.data.tail
  table.size.inc

proc getNode*(table: FlatDbTable, key: cstring): Node =
  ## retrieves the `Node` by id
  ## this is the doubly linked list entry, which exposes next and prev!
  return table.index[key]

proc hasKey*(table: FlatDbTable, key: cstring): bool =
  ## returns true if table has a items with key == key
  return table.index.hasKey(key)

proc del*(table: FlatDbTable, key: cstring) =
  var it = table.index[key]
  table.index.del(key)
  table.data.remove(it)
  table.size.dec

proc clear*(table: FlatDbTable) =
  table.index.clear()
  # table.data.remove()
  # TODO clear linked list better?
  for it in table.data.nodes:
    table.data.remove(it)
  table.size = 0

proc len*(table: FlatDbTable): cint =
  return table.size

iterator values*(table: FlatDbTable): JsObject =
  var it = table.data.head
  while it != nil:
    yield it.value.value
    it = it.next

iterator valuesReverse*(table: FlatDbTable): JsObject =
  # for elem in table.data.items.tail:
  # yield elem
  var it = table.data.tail
  while it != nil:
    yield it.value.value
    it = it.prev

iterator pairs*(table: FlatDbTable): Entry =
  var it = table.data.head
  while it != nil:
    yield it.value
    it = it.next

iterator pairsReverse*(table: FlatDbTable): Entry =
  var it = table.data.tail
  while it != nil:
    yield it.value
    it = it.prev

when isMainModule:
  import sequtils, jsNode

  block:
    var t1 = jsonStr{"foo": 1}
    var t2 = jsonStr{"foo": 2}
    var table = newFlatDbTable()
    table.add("id1", t1)
    table.add("id2", t2)

    assert table["id1"] == t1
    assert table["id2"] == t2

    assert table["id1"].getOrDefault("foo").getNum() == 1

    assert toSeq(table.values) == @[t1, t2]
    assert toSeq(table.valuesReverse) == @[t2, t1]

    assert toSeq(table.pairs) == @[("id1", t1), ("id2", t2)]
    assert toSeq(table.pairsReverse) == @[("id2", t2), ("id1", t1)]

    assert table.len == 2
    table.del("id2")
    assert toSeq(table.values) == @[t1]
    assert toSeq(table.valuesReverse) == @[t1]
    assert table.len == 1

  block: # clear
    var t1 = jsonStr{"foo": 1}
    var t2 = jsonStr{"foo": 2}
    var table = newFlatDbTable()
    table.add("id1", t1)
    table.add("id2", t2)
    table.clear()
    assert table.len == 0
    assert toSeq(table.values) == @[]
    assert toSeq(table.valuesReverse) == @[]

  block: # change/update
    var t1 = jsonStr{"foo": 1}
    var t2 = jsonStr{"foo": 2}
    var table = newFlatDbTable()
    table.add("id1", t1)
    table.add("id2", t2)

    let entry = table["id1"]
    entry["foo"] = %"klaus"
    assert toSeq(table.pairs) == @[("id1", jsonStr{"foo": "klaus"}), ("id2", t2)]

    table["id2"] = jsonStr{"klaus": "klauspeter"}
    assert toSeq(table.pairs) ==
      @[("id1", jsonStr{"foo": "klaus"}), ("id2", jsonStr{"klaus": "klauspeter"})]

  block:
    var table = newFlatDbTable()
    for idx in 0 .. 10_000:
      var t1 = jsonStr{"foo": idx}
    table.add($idx, t1)

    for each in table.valuesReverse():
      echo each
