#!/bin/bash
# Regression test: the Plum bridge script (/usr/local/bin/vibe-acp-bridge) must not be a precondition on a NEW server.
# configure_plum_isolation.yml used to fail its first task when the file was missing, and configure_plum_readonly.yml then copied the
# missing file to .bak-pre-readonly (remote_src) before installing the repo's version. Both assumed the hand-made script of node-2.
# The tasks about the bridge script are taken out of the REAL playbooks (by task name) and run with ansible against a temp directory:
#   A. new server (no script)      -> the tasks succeed, the repo's script is installed, no .bak is made
#   B. node-2 like (script exists) -> the old script is kept once as .bak-pre-readonly, the repo's script is installed
#   C. second run                  -> idempotent, the .bak still holds the OLD content
#   D. check mode on a new server  -> succeeds and creates nothing
# Needs ansible-playbook (PATH or ANSIBLE_PLAYBOOK=/path), python3 with PyYAML and passwordless sudo; skips without them.
# usage: test-plum-bridge-bootstrap.sh [REPO_ROOT]   (default: the checkout this test lives in)
set -u
R=${1:-$(cd "$(dirname "$0")/.." && pwd)}
AP=${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook || true)}
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
[[ -n $AP && -x $AP ]] || { echo "SKIP: needs ansible-playbook (PATH or ANSIBLE_PLAYBOOK)"; exit 0; }
python3 -I -c 'import yaml' 2>/dev/null || { echo "SKIP: needs python3 PyYAML"; exit 0; }
sudo -n true 2>/dev/null || { echo "SKIP: needs passwordless sudo"; exit 0; }

W=$(mktemp -d); trap 'sudo -n rm -rf "$W"' EXIT
export ANSIBLE_HOME=$W/ansible-home ANSIBLE_NOCOLOR=1 ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False
SRC=$R/docker/vibe-cbm/lumiether/chat/vibe-acp-bridge
BR=$W/bin/vibe-acp-bridge

echo "== syntax of the real playbooks"
chk "configure_plum_isolation.yml (with its import) passes --syntax-check"  '"$AP" --syntax-check -i localhost, "$R/configure_plum_isolation.yml" >/dev/null 2>"$W/syn1"'
chk "configure_plum_readonly.yml passes --syntax-check"                      '"$AP" --syntax-check -i localhost, "$R/configure_plum_readonly.yml" >/dev/null 2>"$W/syn2"'

# the bridge tasks of the real playbooks, in playbook order: isolation first (its checks), then readonly (keep + install)
python3 -I - "$R" "$W/play.yml" "$BR" "$R/docker/vibe-cbm/lumiether/chat" <<'PY'
import sys, yaml
root, out, bridge, chat = sys.argv[1:5]
def tasks(path):
    plays = yaml.safe_load(open(f"{root}/{path}"))
    return [t for p in plays for t in (p.get("tasks") or [])]
want_iso = ("Bridge forced command", "Bridge script")
want_ro = ("Is there a bridge script", "Keep the current bridge script once", "Install the read-only sandboxed bridge script")
sel = [t for t in tasks("configure_plum_isolation.yml") if str(t.get("name", "")).startswith(want_iso)]
sel += [t for t in tasks("configure_plum_readonly.yml") if str(t.get("name", "")).startswith(want_ro)]
play = [{"hosts": "localhost", "connection": "local", "gather_facts": False, "become": True,
         "vars": {"bridge_cmd": bridge, "chat_src": chat}, "tasks": sel}]
yaml.safe_dump(play, open(out, "w"))
print(len(sel), "tasks selected")
PY
run() { # run NAME [ansible args]; on failure the reason is shown, indented
  "$AP" -i localhost, ${2:-} "$W/play.yml" >"$W/out.$1" 2>&1; local rc=$?
  [[ $rc -eq 0 ]] || grep -h -E 'fatal:|"msg"' "$W/out.$1" | head -2 | cut -c1-220 | sed 's/^/        | /'
  return $rc
}

echo "== A. new server: no bridge script"
mkdir -p "$W/bin"; run A; rc=$?
chk "the bridge tasks succeed"                                               '[[ $rc -eq 0 ]]'
chk "the repo's bridge script is installed (same content, mode 755, root)"   'cmp -s "$SRC" "$BR" && [[ $(sudo -n stat -c "%a %U" "$BR") == "755 root" ]]'
chk "no .bak-pre-readonly was made (there was nothing to keep)"              '[[ ! -e $BR.bak-pre-readonly ]]'

echo "== B. node-2 like: a hand-made script exists"
sudo -n rm -f "$BR"; echo "old hand-made bridge" > "$BR"; run B; rc=$?
chk "the bridge tasks succeed"                                               '[[ $rc -eq 0 ]]'
chk "the old script was kept once as .bak-pre-readonly"                      'grep -qx "old hand-made bridge" "$BR.bak-pre-readonly"'
chk "the repo's script replaced it"                                          'cmp -s "$SRC" "$BR"'

echo "== C. second run"
run C; rc=$?
chk "succeeds"                                                               '[[ $rc -eq 0 ]]'
chk "the .bak still holds the OLD content (not overwritten)"                 'grep -qx "old hand-made bridge" "$BR.bak-pre-readonly"'
chk "nothing changed on the second run"                                      'grep -q "changed=0" "$W/out.C"'

echo "== D. check mode on a new server"
sudo -n rm -f "$BR" "$BR.bak-pre-readonly"; run D --check; rc=$?
chk "succeeds in check mode"                                                 '[[ $rc -eq 0 ]]'
chk "creates nothing"                                                        '[[ ! -e $BR && ! -e $BR.bak-pre-readonly ]]'

echo "== E. bubblewrap: installed by the play (apt), not a precondition"
python3 -I - "$R" "$W/play-bwrap.yml" "$W/no-such-bwrap" <<'PY'
import sys, yaml
root, out, bwrap = sys.argv[1:4]
plays = yaml.safe_load(open(f"{root}/configure_plum_readonly.yml"))
sel = [t for p in plays for t in (p.get("tasks") or []) if str(t.get("name", "")).startswith("bubblewrap is installed")]
yaml.safe_dump([{"hosts": "localhost", "connection": "local", "gather_facts": False, "become": True,
                 "vars": {"bwrap_bin": bwrap}, "tasks": sel}], open(out, "w"))
print(len(sel), "task selected")
PY
chk "the task installs the package with the apt module (state present)"     'python3 -I -c "import sys,yaml; t=yaml.safe_load(open(sys.argv[1]))[0][\"tasks\"][0]; a=t.get(\"ansible.builtin.apt\") or {}; sys.exit(0 if a.get(\"name\")==\"bubblewrap\" and a.get(\"state\")==\"present\" else 1)" "$W/play-bwrap.yml"'
"$AP" -i localhost, --check "$W/play-bwrap.yml" >"$W/out.E" 2>&1; rc=$?
[[ $rc -eq 0 ]] || grep -h -E 'fatal:|"msg"' "$W/out.E" | head -2 | cut -c1-220 | sed 's/^/        | /'
chk "check mode succeeds although bwrap_bin points at a file that does not exist"  '[[ $rc -eq 0 ]]'
if dpkg -s bubblewrap 2>/dev/null | grep -q "^Status: install ok installed"; then want=0; else want=1; fi
chk "check mode reports changed=$want, failed=0 (the package is $([[ $want -eq 0 ]] && echo installed || echo missing) on this machine)"  'grep -Eq "changed=$want +unreachable=0 +failed=0" "$W/out.E"'

echo; echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
