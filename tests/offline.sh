#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
mkdir "$TEST_TMP/offline"
ln -s "$(command -v bash)" "$TEST_TMP/offline/bash"
cat >"$TEST_TMP/offline/uname" <<'SH'
#!/usr/bin/env bash
echo Linux
SH
chmod +x "$TEST_TMP/offline/uname"
# Only these two tools are visible; list/empty inventory/removal do not need tar/curl.
original_path=$PATH
export PATH="$TEST_TMP/offline"
run_installer --backend direct --list
assert_status 0
assert_contains heavydata
run_installer --backend direct --installed
assert_status 0
run_installer --backend direct --uninstall all
assert_status 0
export PATH="$original_path"
printf 'PASS: direct metadata/removal without download tools\n'
