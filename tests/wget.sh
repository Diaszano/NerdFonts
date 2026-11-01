#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
mkdir -p "$TEST_TMP/fixture" "$TEST_TMP/wget-tools"
printf font >"$TEST_TMP/fixture/Hack.ttf"
tar -cJf "$TEST_TMP/archive" -C "$TEST_TMP/fixture" .
export TEST_ARCHIVE="$TEST_TMP/archive" TEST_COUNT="$TEST_TMP/count"
for tool in bash mkdir mktemp rm rmdir cat cp mv touch dirname find tar xz awk sleep tr grep; do
  ln -s "$(command -v "$tool")" "$TEST_TMP/wget-tools/$tool"
done
cat >"$TEST_TMP/wget-tools/uname" <<'SH'
#!/usr/bin/env bash
echo Linux
SH
cat >"$TEST_TMP/wget-tools/wget" <<'SH'
#!/usr/bin/env bash
count=0
[[ ! -f "$TEST_COUNT" ]] || count=$(cat "$TEST_COUNT")
count=$((count + 1)); echo "$count" > "$TEST_COUNT"
while [[ $# -gt 0 ]]; do
  case "$1" in -O) dest=$2; shift 2 ;; *) shift ;; esac
done
case "${TEST_MODE:-ok}" in
transient) if [[ "$count" -lt 3 ]]; then echo '  HTTP/1.1 503 Unavailable' >&2; exit 8; fi ;;
permanent) echo '  HTTP/1.1 404 Not Found' >&2; exit 8 ;;
stream) if [[ "$count" -lt 3 ]]; then echo '  HTTP/1.1 200 OK' >&2; exit 4; fi ;;
esac
cp "$TEST_ARCHIVE" "$dest"
echo '  HTTP/1.1 200 OK' >&2
SH
chmod +x "$TEST_TMP/wget-tools/uname" "$TEST_TMP/wget-tools/wget"
original_path=$PATH
export PATH="$TEST_TMP/wget-tools"
for mode in ok transient stream permanent; do
  export TEST_MODE=$mode
  printf 0 >"$TEST_COUNT"
  run_installer --backend direct --fonts hack
  if [[ "$mode" == permanent ]]; then
    assert_status 4
    [[ $(cat "$TEST_COUNT") == 1 ]]
  else
    assert_status 0
    if [[ "$mode" != ok ]]; then [[ $(cat "$TEST_COUNT") == 3 ]]; fi
    run_installer --backend direct --uninstall hack
    assert_status 0
  fi
done
export PATH="$original_path"
printf 'PASS: wget installation and retry policy\n'
