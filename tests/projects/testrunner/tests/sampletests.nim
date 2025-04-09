import unittest2

suite "Sample Tests":
  test "Sample Test":
    check(1 == 1)

test "Global test":
  check(1 == 1)

test "Global test 2":
  check(1 == 1)

suite "Sample Suite":
  test "Sample Test":
    check(1 == 1)

  test "Sample Test 2":
    check(1 == 1)

  test "Sample Test 3":
    check(1 == 1)

test "Another global test":
  check(1 == 1)
