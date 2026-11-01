#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
mkdir -p "$TEST_TMP/fixture"
printf font >"$TEST_TMP/fixture/Hack.ttf"
tar -cJf "$TEST_TMP/archive" -C "$TEST_TMP/fixture" .
export TEST_ARCHIVE="$TEST_TMP/archive" TEST_COUNT="$TEST_TMP/count"
cat >"$TEST_TMP/bin/uname" <<'SH'
#!/usr/bin/env bash
echo Linux
SH
cat >"$TEST_TMP/bin/fc-cache" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$TEST_TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[[ ! -f "$TEST_COUNT" ]] || count=$(cat "$TEST_COUNT")
count=$((count + 1))
echo "$count" > "$TEST_COUNT"
while [[ $# -gt 0 ]]; do
  case "$1" in -o) dest=$2; shift 2 ;; *) url=$1; shift ;; esac
done
case "${TEST_MODE:-ok}" in
transient) if [[ "$count" -lt 3 ]]; then printf 503; exit 22; fi ;;
stream) if [[ "$count" -lt 3 ]]; then printf 200; exit 18; fi ;;
permanent) printf 404; exit 22 ;;
timeout) exit 28 ;;
invalid) printf html > "$dest"; printf 200; exit 0 ;;
partial) [[ "$url" != *UbuntuMono* ]] || { printf 404; exit 22; } ;;
slow) echo "$$" > "$TEST_COUNT.pid"; exec sleep 30 ;;
esac
cp "$TEST_ARCHIVE" "$dest"
printf 200
SH
chmod +x "$TEST_TMP/bin/"*
export TEST_MODE=transient
run_installer --backend direct --fonts hack
assert_status 0
[[ $(cat "$TEST_COUNT") == 3 ]]
root="$XDG_DATA_HOME/fonts/NerdFonts"
printf original >"$root/hack/Hack.ttf"
rm "$root/hack/Hack.ttf"
export TEST_MODE=invalid
run_installer --backend direct --fonts hack
assert_status 4
[[ -f "$root/hack/.nerdfonts-manifest" ]]
export TEST_MODE=permanent
printf 0 >"$TEST_COUNT"
run_installer --backend direct --fonts ubuntu
assert_status 4
[[ $(cat "$TEST_COUNT") == 1 ]]
export TEST_MODE=timeout
printf 0 >"$TEST_COUNT"
run_installer --backend direct --fonts ubuntu
assert_status 4
[[ $(cat "$TEST_COUNT") == 3 ]]
export TEST_MODE=partial
run_installer --backend direct --fonts ubuntu,ubuntumono
assert_status 4
[[ -f "$root/ubuntu/.nerdfonts-manifest" ]]
[[ ! -e "$root/ubuntumono/.nerdfonts-manifest" ]]
export TEST_MODE=slow
bash "$TEST_ROOT/scripts/install.sh" --backend direct --fonts firacode >"$TEST_TMP/signal.log" 2>&1 &
installer_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ ! -f "$TEST_COUNT.pid" ]] || break
  sleep 0.05
done
[[ -f "$TEST_COUNT.pid" ]]
kill -TERM "$installer_pid"
signal_status=0
wait "$installer_pid" || signal_status=$?
[[ "$signal_status" == 143 ]]
if kill -0 "$(cat "$TEST_COUNT.pid")" 2>/dev/null; then
  echo "FAIL: downloader survived cancellation"
  exit 1
fi
[[ ! -e "$root/.firacode.lock" ]]
[[ ! -e "$root/firacode/.nerdfonts-manifest" ]]
printf 'PASS: retries, HTTP errors, partial failure and SIGTERM cleanup\n'

export TEST_MODE=stream
printf 0 >"$TEST_COUNT"
run_installer --backend direct --fonts geistmono
assert_status 0
[[ $(cat "$TEST_COUNT") == 3 ]]
printf 'PASS: interrupted HTTP 200 transfers are retried\n'
