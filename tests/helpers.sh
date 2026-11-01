#!/usr/bin/env bash
# Shared subprocess fixtures. Each test owns its temporary HOME and PATH.
set -euo pipefail
TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
TEST_RM=$(command -v rm)
trap '"$TEST_RM" -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/home space"
export HOME="$TEST_TMP/home space"
export XDG_DATA_HOME="$HOME/data space"
export PATH="$TEST_TMP/bin:$PATH"
export NO_COLOR=1
run_installer() {
  STATUS=0
  OUTPUT=$(bash "$TEST_ROOT/scripts/install.sh" "$@" 2>&1) || STATUS=$?
}
assert_status() {
  [[ "$STATUS" == "$1" ]] || {
    printf 'Expected status %s, got %s:\n%s\n' "$1" "$STATUS" "$OUTPUT" >&2
    exit 1
  }
}
assert_contains() {
  [[ "$OUTPUT" == *"$1"* ]] || {
    printf 'Missing %s:\n%s\n' "$1" "$OUTPUT" >&2
    exit 1
  }
}
assert_absent() {
  [[ "$OUTPUT" != *"$1"* ]] || {
    printf 'Unexpected %s:\n%s\n' "$1" "$OUTPUT" >&2
    exit 1
  }
}
