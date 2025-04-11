import unittest2

suite "Failing Tests":
  test "Failing Test":
    check(1 == 2)
  
  test "Passing test":
    check(1 == 1)

