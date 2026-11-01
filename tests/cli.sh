#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
run_installer --backend invalid --list
assert_status 1
assert_absent 'command not found'
run_installer --backend
assert_status 1
for jobs in 0 -2 nope; do
  export NF_JOBS="$jobs"
  run_installer --backend direct --list
  assert_status 1
done
unset NF_JOBS
run_installer --all --list
assert_status 1
run_installer --help
assert_status 0
run_installer --version
assert_status 0
run_installer --backend direct --fonts 'hack,hack' --dry-run
assert_status 0
[[ $(printf '%s\n' "$OUTPUT" | grep -c 'Would download') == 1 ]]
[[ ! -e "$XDG_DATA_HOME" ]]
printf 'PASS: CLI validation and dry-run\n'
