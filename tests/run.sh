#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for test_file in tests/*.sh; do
  case "$test_file" in *helpers.sh | *run.sh | *integration.sh) continue ;; esac
  printf 'Running %s\n' "$test_file"
  bash "$test_file"
done
