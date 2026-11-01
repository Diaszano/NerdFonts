#!/usr/bin/env bash
# Python is a test driver only: it launches a foreground child that can receive
# SIGINT (asynchronous Bash commands inherit SIGINT ignored).
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
export TEST_ROOT TEST_TMP
export TEST_BASH
TEST_BASH=$(command -v bash)
mkdir "$TEST_TMP/signal-tools"
for tool in bash mkdir mktemp rm rmdir cat cp mv touch dirname find tar xz awk sleep tr grep; do
  ln -s "$(command -v "$tool")" "$TEST_TMP/signal-tools/$tool"
done
cat >"$TEST_TMP/signal-tools/uname" <<'SH'
#!/usr/bin/env bash
echo Linux
SH
chmod +x "$TEST_TMP/signal-tools/uname"
python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import time

root = Path(os.environ['TEST_ROOT'])
tmp = Path(os.environ['TEST_TMP'])
tools = tmp / 'signal-tools'
for client in ('curl', 'wget'):
    script = tools / client
    script.write_text('#!/usr/bin/env bash\necho "$$" > "$TEST_PID_FILE"\nexec sleep 30\n')
    script.chmod(0o755)
    for sig, status in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
        pid_file = tmp / f'{client}-{status}.pid'
        data = tmp / f'{client}-{status}'
        env = dict(os.environ, PATH=str(tools), TEST_PID_FILE=str(pid_file), XDG_DATA_HOME=str(data))
        with (tmp / f'{client}-{status}.log').open('w+') as log:
            process = subprocess.Popen([os.environ['TEST_BASH'], str(root / 'scripts/install.sh'),
                                        '--backend', 'direct', '--fonts', 'hack'],
                                       env=env, stdout=log, stderr=subprocess.STDOUT)
            child_pid = None
            try:
                deadline = time.monotonic() + 10
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                assert pid_file.exists(), 'Downloader did not start'
                child_pid = int(pid_file.read_text())
                process.send_signal(sig)
                result = process.wait(timeout=10)
                log.seek(0)
                assert result == status, (client, sig, result, log.read())
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError('Downloader survived cancellation')
                managed = data / 'fonts' / 'NerdFonts'
                assert not (managed / '.hack.lock').exists(), 'Lock survived cancellation'
                assert not list(managed.glob('.hack.stage.*')), 'Staging survived cancellation'
                assert not (managed / 'hack' / '.nerdfonts-manifest').exists()
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                if child_pid is not None:
                    try:
                        os.kill(child_pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
    script.unlink()
print('PASS: curl/wget SIGINT and SIGTERM cleanup')
PY
