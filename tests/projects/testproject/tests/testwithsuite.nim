import unittest

import testproject


suite "test suite":
  test "can add":
    check add(5, 5) == 10

  test "can add 2":
    check add(5, 5) == 10

  test "can add 3":
    check add(5, 5) == 10

suite "test suite 2":
  test "can add 4":
    check add(5, 5) == 10

  test "can add 5":
    check add(5, 5) == 10


test "can add 6":
  check add(5, 5) == 10
