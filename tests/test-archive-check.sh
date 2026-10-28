#!/bin/bash
# Regression test for the secrets-archive listing. A fake encrypted archive in the shape of the real one (SECRETS.sha256, ~/.ssh,
# ~/.cloudflared, /etc/lumiether, then the two .envrc files LAST) with more than 20 entries.
#   1. `restore.sh verify` must show EVERY entry, including the last two (it used to cut the listing after 20 lines)
#   2. backup.sh's verify_archive must fail when a required path is missing from the archive, and pass when all are there
#   3. the helper functions on their own (prefix rule, empty listing)
# usage: tests/test-archive-check.sh [REPO_ROOT]   (default: this checkout; the passphrase is random per run and never leaves the test)
set -u
R=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
sudo -n true 2>/dev/null || { echo "SKIP: needs passwordless sudo (restore.sh checks it)"; exit 0; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PW=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
mk() { # mk NAME [omit-portainer]   -> $W/NAME.tar.zst.gpg
  local d=$W/src-$1; rm -rf "$d"; mkdir -p "$d/home/u/.ssh" "$d/home/u/.cloudflared" "$d/etc/lumiether" "$d/home/u/infra-bootstrap/awx-config" "$d/home/u/infra-bootstrap/portainer-config"
  echo x > "$d/SECRETS.sha256"
  for i in $(seq 1 12); do echo k > "$d/home/u/.ssh/key$i"; done
  for i in 1 2 3 4; do echo c > "$d/home/u/.cloudflared/c$i"; done
  for i in 1 2 3 4 5 6; do echo e > "$d/etc/lumiether/e$i"; done
  echo a > "$d/home/u/infra-bootstrap/awx-config/.envrc-awx"
  [[ ${2:-} == omit-portainer ]] || echo p > "$d/home/u/infra-bootstrap/portainer-config/.envrc-portainer"
  ( cd "$d" && tar -cf - SECRETS.sha256 home/u/.ssh home/u/.cloudflared etc/lumiether home/u/infra-bootstrap ) | zstd -q \
    | gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 -o "$W/$1.tar.zst.gpg" 3< <(printf '%s' "$PW")
}
mk full; mk nopb omit-portainer
LISTED=$(gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --decrypt "$W/full.tar.zst.gpg" 3< <(printf '%s' "$PW") | zstd -dcq | tar -tf - | wc -l)
echo "fake archive: $LISTED entries (more than 20, env files last)"

echo "== 1. restore.sh verify through a pseudo-terminal"
# restore.sh reads the passphrase from /dev/tty, so the test types it into a pseudo-terminal, but only after the prompt appears
# (the child has switched echo off by then; typing it earlier would be echoed back into the output).
cat > "$W/pty_drive.py" <<'PYEOF'
import os, pty, select, sys, time
pw = os.environ["PTY_PW"].encode()
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
buf, sent, end = b"", 0, time.time() + 120
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 1)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if buf.count(b"assphrase") > sent and buf.rstrip().endswith(b":"):
            time.sleep(0.2); os.write(fd, pw + b"\n"); sent += 1
os.waitpid(pid, 0)
sys.stdout.write(buf.decode(errors="replace").replace("\r", ""))
PYEOF
out=$(PTY_PW=$PW python3 -I "$W/pty_drive.py" "$R/scripts/restore.sh" verify "$W/full.tar.zst.gpg" 2>&1)
chk "the listing shows the awx env file (it is entry 22 or later)"        'grep -q "infra-bootstrap/awx-config/.envrc-awx" <<<"$out"'
chk "the listing shows the portainer env file (the last entry)"           'grep -q "infra-bootstrap/portainer-config/.envrc-portainer" <<<"$out"'
chk "the listing says how many entries there are ($LISTED)"               'grep -qE "(^|[^0-9])$LISTED entries" <<<"$out"'
chk "the archive was read cleanly (decrypts and reads)"                 'grep -q "archive decrypts and reads cleanly" <<<"$out"'
chk "the passphrase is not echoed anywhere in the output"                 '! grep -qF "$PW" <<<"$out"'

echo "== 2. backup.sh verify_archive (the function text taken from the real script)"
H=$W/harness.sh
{
  echo 'die() { echo "backup.sh: $*" >&2; return 1 2>/dev/null || exit 1; }; say() { :; }'
  echo 'decrypt() { local -n pw=$1; gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --decrypt "$2" 3< <(printf "%s" "$pw"); }'
  echo ". $R/scripts/lib/archive-check.sh"
  sed -n '/^verify_archive()/,/^}/p' "$R/scripts/backup.sh"
} > "$H"
REQ=(SECRETS.sha256 home/u/.ssh home/u/.cloudflared etc/lumiether home/u/infra-bootstrap/awx-config/.envrc-awx home/u/infra-bootstrap/portainer-config/.envrc-portainer)
( set -euo pipefail; . "$H"; PWV=$PW; verify_archive PWV "$W/full.tar.zst.gpg" "${REQ[@]}" ) >"$W/v1.out" 2>&1; rc=$?
chk "all required paths present -> passes"                                '[[ $rc -eq 0 ]]'
( set -euo pipefail; . "$H"; PWV=$PW; verify_archive PWV "$W/nopb.tar.zst.gpg" "${REQ[@]}" ) >"$W/v2.out" 2>&1; rc=$?
chk "the portainer env file missing -> fails (non-zero)"                  '[[ $rc -ne 0 ]]'
chk "... and names exactly the missing path"                              'grep -q "missing:.*portainer-config/.envrc-portainer" "$W/v2.out" && ! grep -q "missing:.*awx-config" "$W/v2.out"'
( set -euo pipefail; . "$H"; PWV=$PW; verify_archive PWV "$W/nopb.tar.zst.gpg" ) >"$W/v3.out" 2>&1; rc=$?
chk "no required paths given (the data archive) -> still just reads it"   '[[ $rc -eq 0 ]]'

echo "== 3. helper functions"
. "$R/scripts/lib/archive-check.sh"
chk "a name is not a prefix of a longer name (a/b vs a/bc/x)"             '! printf "a/bc/x\n" | archive_missing a/b >/dev/null'
chk "a directory matches its files (a/b vs a/b/x)"                        'printf "a/b/x\n" | archive_missing a/b >/dev/null'
chk "an empty listing reports everything missing"                         '[[ $(printf "" | archive_missing a b | wc -l) -eq 2 ]]'

echo; echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
