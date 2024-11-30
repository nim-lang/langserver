proc a안녕() = discard
#[안녕]#a안녕()
var bbb = 100
bbb = 200
bbb = ""

import std/options
var
  x: Option[string]
  y: Option[string]

import std/macros

macro myAssertMacroInner(arg: untyped): untyped =
  result = quote do:
    `arg`

macro helloMacro*(prc: untyped): untyped =
  result = quote do:
    proc helloProc(): string = "Hello"

proc helloProc(): void {.helloMacro.}=
  discard

import with

type
  Obj = ref object of RootObj
    field1*: string
    field2*: string

proc f(a: Obj) =
  with a:
    field1 = field2

let a안녕bcd = 0
