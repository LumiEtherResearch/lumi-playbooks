#!/bin/bash
# Regression test: wip_capture must survive a stale git index when git runs as root and the temp directory is sticky and owned by root
# (like /tmp). Before the fix, git replaced the temporary index copy with a root-owned file, the cleanup rm failed ("Operation not
# permitted") and `set -e` aborted backup.sh half way. Needs passwordless sudo (skips without it).
# usage: tests/test-wip-tmpdir.sh [PATH/TO/workspace-wip.sh]   (default: scripts/lib/workspace-wip.sh of this checkout)
set -u
LIB=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib/workspace-wip.sh}
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
sudo -n true 2>/dev/null || { echo "SKIP: needs passwordless sudo"; exit 0; }

W=$(mktemp -d)
trap 'sudo -n rm -rf "$W"' EXIT
sudo -n install -d -m 1777 -o root -g root "$W/tmp"        # sticky, root-owned: the caller cannot remove a root-owned file in it
mkdir -p "$W/homes/dev/r" "$W/out"
(
  cd "$W/homes/dev/r" && git init -q . && git config user.email t@t && git config user.name t
  echo one > f; echo same > g; git add f g && git commit -qm base
  sleep 1
  touch g                                   # same content, new mtime: the index entry is stat-stale, git diff will rewrite the index
  echo changed > f; echo new > untracked.txt
)
idx=$W/homes/dev/r/.git/index
before=$(sha256sum < "$idx")

echo "== wip_capture under set -euo pipefail, git as root, sticky root-owned TMPDIR"
(
  set -euo pipefail
  export TMPDIR=$W/tmp WIP_SUDO='sudo -n'
  # shellcheck disable=SC1090
  . "$LIB"
  wip_capture "$W/out" "$W/homes/dev:2" 2>"$W/stderr.txt"
)
rc=$?
chk "wip_capture finished (exit 0), the script was not aborted"      '[[ $rc -eq 0 ]]'
patch=$(find "$W/out" -name wip.patch | head -n 1)
chk "the patch of the tracked change was written"                     '[[ -n $patch ]] && grep -q "^+changed" "$patch"'
chk "the untracked file was captured"                                 'tar -tf "$(find "$W/out" -name untracked.tar | head -n 1)" 2>/dev/null | grep -q untracked.txt'
chk "no file or directory is left in the temp directory"              '[[ -z $(ls -A "$W/tmp") ]]'
chk "the developer's real index was not touched"                      '[[ $(sha256sum < "$idx") == "$before" ]]'
chk "the repository index is still owned by the developer (me)"       '[[ $(stat -c %U "$idx") == $(id -un) ]]'
chk "no 'Operation not permitted' in the error output"                '! grep -q "Operation not permitted" "$W/stderr.txt"'

echo; echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
