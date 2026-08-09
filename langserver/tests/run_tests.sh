#!/usr/bin/env bash
# Run each test file individually with a timeout.
# Executables are compiled to bin/ (set in tests_rewrite/config.nims).
# Usage: bash tests_rewrite/run_tests.sh [timeout_seconds]
#   Default timeout: 120 seconds per file

set -euo pipefail
cd "$(dirname "$0")/.."

TIMEOUT=${1:-120}
PASS=0
FAIL=0
FILES=(
  bin/textensions
  bin/tfindnimblepaths
  bin/thover
  bin/tknownbug3
  bin/tmaxlimits
  bin/tmisc
  bin/tmonorepo2
  bin/tmonorepo3
  bin/tnimlangserver
  bin/tstability
  bin/tsuggestapi
  bin/ttestrunner
)

for f in "${FILES[@]}"; do
  name=$(basename "$f" .nim)
  echo ""
  echo "════════════════════════════════════════"
  echo "  Running: $name"
  echo "════════════════════════════════════════"
  if timeout "$TIMEOUT" nim c --path:. -r "$f"; then
    echo "  ✓ $name PASSED"
    ((PASS++)) || true
  else
    code=$?
    if [ $code -eq 124 ]; then
      echo "  ✗ $name TIMED OUT (>${TIMEOUT}s)"
    else
      echo "  ✗ $name FAILED (exit $code)"
    fi
    ((FAIL++)) || true
  fi
done

echo ""
echo "════════════════════════════════════════"
echo "  Total: $((PASS+FAIL))  Passed: $PASS  Failed: $FAIL"
echo "════════════════════════════════════════"
[ $FAIL -eq 0 ]
