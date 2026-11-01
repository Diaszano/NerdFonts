#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
mkdir -p "$TEST_TMP/fixture" "$TEST_TMP/active" "$TEST_TMP/started"
printf font >"$TEST_TMP/fixture/Regular.ttf"
tar -cJf "$TEST_TMP/archive" -C "$TEST_TMP/fixture" .
export TEST_ARCHIVE="$TEST_TMP/archive" TEST_ACTIVE="$TEST_TMP/active" TEST_STARTED="$TEST_TMP/started"
cat >"$TEST_TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
mkdir "$TEST_ACTIVE/$$"
touch "$TEST_STARTED/$$"
count=0
for entry in "$TEST_ACTIVE/"*; do [[ ! -d "$entry" ]] || count=$((count + 1)); done
if (( count > 2 )); then touch "$TEST_STARTED/overflow"; fi
sleep 0.2
while [[ $# -gt 0 ]]; do
  case "$1" in -o) dest=$2; shift 2 ;; *) shift ;; esac
done
cp "$TEST_ARCHIVE" "$dest"
rmdir "$TEST_ACTIVE/$$"
SH
cat >"$TEST_TMP/bin/fc-cache" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$TEST_TMP/bin/uname" <<'SH'
#!/usr/bin/env bash
echo Linux
SH
chmod +x "$TEST_TMP/bin/"*
run_installer --backend direct --fonts hack,firacode,ubuntu,ubuntumono --jobs 2
assert_status 0
[[ ! -e "$TEST_STARTED/overflow" ]]
count=0
for entry in "$TEST_STARTED/"*; do [[ ! -f "$entry" ]] || count=$((count + 1)); done
[[ "$count" == 4 ]]
root="$XDG_DATA_HOME/fonts/NerdFonts"
for id in hack firacode ubuntu ubuntumono; do [[ -f "$root/$id/.nerdfonts-manifest" ]]; done
printf 'PASS: concurrency limit and full download batches\n'
