#!/bin/bash
# Test: Mistral Vibe and Codebase Memory must be installed at the PINNED versions, and a second run must change nothing.
# install_vibe.yml ran `uv pip install mistral-vibe` (no version, and a bare command: "changed" on every run); configure_vibe_lumiether.yml
# piped the installer from the floating `main` branch into bash (guarded only by `creates:`). A new server therefore got the latest
# releases (vibe 3.0.3, codebase-memory-mcp 0.12.1) instead of the 2.25.8 / 0.11.0 that node-2 and the vibe-cbm image have.
# Now: vibe is installed with ==VERSION only when another version (or none) is there; Codebase Memory comes from the installer of the
# vX.Y.Z TAG (checksum checked) with CBM_DOWNLOAD_URL pointing at that release, only when the binary is missing or another version.
# The real tasks are taken out of the playbooks (by name) and run with ansible against temp directories. `uv` and `curl` are stubs, so
# nothing is downloaded and nothing outside the temp directory is written. Needs ansible-playbook (PATH or ANSIBLE_PLAYBOOK) and
# python3 + PyYAML; skips without them.
# usage: test-vibe-cbm-pins.sh [REPO_ROOT]   (default: the checkout this test lives in)
set -u
R=${1:-$(cd "$(dirname "$0")/.." && pwd)}
AP=${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook || true)}
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
chk() { if eval "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }
[[ -n $AP && -x $AP ]] || { echo "SKIP: needs ansible-playbook (PATH or ANSIBLE_PLAYBOOK)"; exit 0; }
python3 -I -c 'import yaml' 2>/dev/null || { echo "SKIP: needs python3 PyYAML"; exit 0; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export ANSIBLE_HOME=$W/ansible-home ANSIBLE_NOCOLOR=1 ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False
mkdir -p "$W/bin" "$W/state" "$W/server" "$W/venv/bin"
export STUB_STATE=$W/state

# --- stubs -------------------------------------------------------------------------------------------------------------------------------
cat > "$W/bin/uv" <<'STUB'
#!/bin/bash
# stub uv: `pip show --python P mistral-vibe`, `pip install --python P SPEC...`. State: $STUB_STATE/vibe-version. An unpinned install gets the "latest" (3.0.3).
# `pip install` fails like a real slow download unless UV_HTTP_TIMEOUT is at least 120 (seconds).
S=$STUB_STATE; echo "uv $*" >> "$S/uv.log"
[[ ${1:-} == pip ]] || exit 0; shift; sub=$1; shift
case $sub in
  show)    [[ -f $S/vibe-version ]] || { echo "warning: Package(s) not found for: mistral-vibe" >&2; exit 1; }
           echo "Name: mistral-vibe"; echo "Version: $(cat "$S/vibe-version")" ;;
  install) echo "env UV_HTTP_TIMEOUT=${UV_HTTP_TIMEOUT:-unset}" >> "$S/uv.log"
           # a slow link, as in the VM: the big wheel needs about 120 s, and uv gives up after UV_HTTP_TIMEOUT seconds (default 30)
           if [[ ${UV_HTTP_TIMEOUT:-30} -lt 120 ]]; then
             printf 'error: Failed to download `mistral-vibe==2.25.8`\n  cause: Failed to download distribution due to network timeout. Try increasing UV_HTTP_TIMEOUT (current value: %ss).\n' "${UV_HTTP_TIMEOUT:-30}" >&2; exit 1
           fi
           for a; do case $a in mistral-vibe==*) echo "${a#mistral-vibe==}" > "$S/vibe-version" ;; mistral-vibe) echo 3.0.3 > "$S/vibe-version" ;; esac; done
           echo "Installed 1 package" >&2 ;;
esac
STUB
cat > "$W/server/install.sh" <<'STUB'
#!/bin/bash
# fake codebase-memory-mcp installer: --dir=PATH. The version comes from CBM_DOWNLOAD_URL (.../download/vX.Y.Z); unpinned = "latest" (0.12.1).
for a; do case $a in --dir=*) dir=${a#--dir=} ;; esac; done
[[ $dir == "$FAKE_ROOT"/* ]] || { echo "fake installer: refusing to write outside $FAKE_ROOT ($dir)" >&2; exit 1; }
echo "installer ran: url=${CBM_DOWNLOAD_URL:-unset}" >> "$FAKE_LOG"
ver=0.12.1; [[ ${CBM_DOWNLOAD_URL:-} =~ /download/v([0-9.]+)$ ]] && ver=${BASH_REMATCH[1]}
printf '#!/bin/bash\necho "codebase-memory-mcp %s"\n' "$ver" > "$dir/codebase-memory-mcp"; chmod +x "$dir/codebase-memory-mcp"
STUB
cat > "$W/bin/curl" <<'STUB'
#!/bin/bash
# stub curl: never touches the network; serves the fake installer for any URL and logs the URL (old code: `curl ... | bash`)
echo "curl $*" >> "$FAKE_LOG"; cat "$FAKE_ROOT/server/install.sh"
STUB
chmod +x "$W/bin/uv" "$W/bin/curl" "$W/server/install.sh"
export FAKE_ROOT=$W FAKE_LOG=$W/installer.log; : > "$FAKE_LOG"
GOODSUM=$(sha256sum "$W/server/install.sh" | cut -d' ' -f1)

# --- the real tasks, with test paths ----------------------------------------------------------------------------------------------------
python3 -I - "$R" "$W" "$GOODSUM" <<'PY'
import sys, yaml, json
root, w, goodsum = sys.argv[1:4]
def play(path):
    return yaml.safe_load(open(f"{root}/{path}"))[0]
def pick(p, phrases):
    return [t for t in p["tasks"] if any(x in str(t.get("name", "")) for x in phrases)]
iv, lv = play("install_vibe.yml"), play("configure_vibe_lumiether.yml")
vibe_tasks = pick(iv, ("Which mistral-vibe is installed", "Install mistral-vibe into the shared venv"))
cbm_tasks = pick(lv, ("Which Codebase Memory is installed", "Install Codebase Memory"))
env = {"PATH": f"{w}/bin:/usr/bin:/bin", "STUB_STATE": f"{w}/state", "FAKE_ROOT": w, "FAKE_LOG": f"{w}/installer.log"}
def write(name, p, tasks, over):
    v = dict(p.get("vars", {})); v.update(over)
    yaml.safe_dump([{"hosts": "localhost", "connection": "local", "gather_facts": False, "environment": env, "vars": v, "tasks": tasks}],
                   open(f"{w}/{name}.yml", "w"))
    return v
vv = write("vibe", iv, vibe_tasks, {"uv_bin": f"{w}/bin/uv", "vibe_install_dir": f"{w}/venv"})
cv = write("cbm", lv, cbm_tasks, {"cbm_bin": f"{w}/bin/codebase-memory-mcp", "cbm_installer_url": f"file://{w}/server/install.sh",
                                   "cbm_installer_sha256": goodsum, "cbm_installer_home": w, "install_cbm": True})
write("cbm-badsum", lv, cbm_tasks, {"cbm_bin": f"{w}/bin/codebase-memory-mcp", "cbm_installer_url": f"file://{w}/server/install.sh",
                                     "cbm_installer_sha256": "0" * 64, "cbm_installer_home": w, "install_cbm": True})
write("cbm-off", lv, cbm_tasks, {"cbm_bin": f"{w}/bin/codebase-memory-mcp", "cbm_installer_home": w, "install_cbm": False})
json.dump({"vibe": vv.get("vibe_pinned"), "cbm": cv.get("cbm_version"), "uvto": str(vv.get("uv_http_timeout", ""))}, open(f"{w}/pins.json", "w"))
print(len(vibe_tasks), "vibe tasks,", len(cbm_tasks), "codebase-memory tasks selected")
PY
PV=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["vibe"] or "")' "$W/pins.json"); PC=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["cbm"] or "")' "$W/pins.json")
TO=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["uvto"])' "$W/pins.json")
echo "pins read from the playbooks: vibe='${PV:-<none>}' codebase-memory-mcp='${PC:-<none>}'; uv_http_timeout='${TO:-<none>}'"
run() { # run NAME PLAYFILE [ansible args]  : output in $W/out.NAME
  local n=$1 f=$2; shift 2
  "$AP" -i localhost, "$@" "$W/$f.yml" >"$W/out.$n" 2>&1; local rc=$?
  [[ $rc -eq 0 ]] || grep -h -E 'fatal:|"msg"' "$W/out.$n" | head -2 | cut -c1-230 | sed 's/^/        | /'
  return $rc
}
installs() { grep -c "^uv pip install" "$W/state/uv.log" 2>/dev/null || true; }
reset_vibe() { rm -f "$W/state/vibe-version" "$W/state/uv.log"; [[ -z ${1:-} ]] || echo "$1" > "$W/state/vibe-version"; }
reset_cbm() { rm -f "$W/bin/codebase-memory-mcp"; : > "$FAKE_LOG"; [[ -z ${1:-} ]] || printf '#!/bin/bash\necho "codebase-memory-mcp %s"\n' "$1" > "$W/bin/codebase-memory-mcp"; chmod +x "$W/bin/codebase-memory-mcp" 2>/dev/null; }
cbm_ver() { "$W/bin/codebase-memory-mcp" --version 2>/dev/null | awk '{print $2}'; }

echo "== 0. the pins are the same as in the vibe-cbm image (docker/vibe-cbm/Dockerfile)"
df() { sed -n "s/^ARG $1=//p" "$R/docker/vibe-cbm/Dockerfile" | head -n 1; }
chk "vibe: the playbook pins $PV, the Dockerfile VIBE_VERSION is $(df VIBE_VERSION)"          '[[ -n $PV && $PV == "$(df VIBE_VERSION)" ]]'
chk "codebase-memory-mcp: the playbook pins $PC, the Dockerfile CBM_VERSION is $(df CBM_VERSION)"  '[[ -n $PC && $PC == "$(df CBM_VERSION)" ]]'
chk "the installer checksum in the playbook equals the Dockerfile's CBM_INSTALLER_SHA256"      'grep -q "$(df CBM_INSTALLER_SHA256)" "$R/configure_vibe_lumiether.yml"'

echo "== V1. vibe: a new server (nothing installed)"
reset_vibe; run V1 vibe; rc=$?
chk "the task succeeds and installs mistral-vibe==$PV (not the latest)"      '[[ $rc -eq 0 && $(cat "$W/state/vibe-version") == "$PV" ]]'
chk "the install command names the pinned version"                           'grep -q "mistral-vibe==$PV" "$W/state/uv.log"'
run V1b vibe; rc=$?
chk "second run: succeeds, installs nothing, changes nothing"                '[[ $rc -eq 0 && $(installs) -eq 1 ]] && grep -q "changed=0" "$W/out.V1b"'

echo "== V1t. vibe: a slow download (the real failure in the VM: uv's 30 s default timeout against a 54 MiB wheel)"
chk "the playbook sets uv_http_timeout, at least 300 seconds"                              '[[ -n $TO && $TO -ge 300 ]]'
chk "the install command runs with UV_HTTP_TIMEOUT=$TO (what the playbook says)"           'grep -qx "env UV_HTTP_TIMEOUT=$TO" "$W/state/uv.log"'
chk "uv venv (which downloads the Python) and uv pip install both carry the timeout"       'python3 -I -c "
import sys, yaml
t = yaml.safe_load(open(sys.argv[1] + \"/install_vibe.yml\"))[0][\"tasks\"]
need = (\"Create shared venv\", \"Install mistral-vibe into the shared venv\")
sys.exit(0 if all(any(n in str(x.get(\"name\")) and \"UV_HTTP_TIMEOUT\" in (x.get(\"environment\") or {}) for x in t) for n in need) else 1)" "$R"'

echo "== V2. vibe: another version is installed (3.0.3)"
reset_vibe 3.0.3; run V2 vibe; rc=$?
chk "it is put on the pinned version"                                        '[[ $rc -eq 0 && $(cat "$W/state/vibe-version") == "$PV" ]]'
run V2b vibe; rc=$?
chk "second run: nothing changes"                                            '[[ $rc -eq 0 ]] && grep -q "changed=0" "$W/out.V2b"'

echo "== V3. vibe: already on the pinned version, in check mode (like node-2)"
reset_vibe "$PV"; run V3 vibe --check; rc=$?
chk "check mode: succeeds, no change, no install attempted"                  '[[ $rc -eq 0 && $(installs) -eq 0 ]] && grep -q "changed=0" "$W/out.V3"'
reset_vibe "$PV"; run V3b vibe; rc=$?
chk "a real run: no install attempted either"                                '[[ $rc -eq 0 && $(installs) -eq 0 ]] && grep -q "changed=0" "$W/out.V3b"'

echo "== C1. codebase-memory-mcp: a new server (no binary)"
reset_cbm; run C1 cbm; rc=$?
chk "the task succeeds and the binary reports $PC (not the latest 0.12.1)"   '[[ $rc -eq 0 && $(cbm_ver) == "$PC" ]]'
chk "the installer was told to download that tag's release"                  'grep -q "installer ran: url=https://github.com/DeusData/codebase-memory-mcp/releases/download/v$PC\$" "$FAKE_LOG"'
chk "the installer script came from the tag, not from main"                  '! grep -q "/main/install.sh" "$W/out.C1"'
run C1b cbm; rc=$?
chk "second run: succeeds, runs no installer, changes nothing"               '[[ $rc -eq 0 && $(grep -c "installer ran" "$FAKE_LOG") -eq 1 ]] && grep -q "changed=0" "$W/out.C1b"'

echo "== C2. codebase-memory-mcp: another version is installed (0.12.1)"
reset_cbm 0.12.1; run C2 cbm; rc=$?
chk "it is put on the pinned version"                                        '[[ $rc -eq 0 && $(cbm_ver) == "$PC" ]]'
run C2b cbm; rc=$?
chk "second run: nothing changes"                                            '[[ $rc -eq 0 ]] && grep -q "changed=0" "$W/out.C2b"'

echo "== C3. codebase-memory-mcp: already on the pinned version, in check mode (like node-2)"
reset_cbm "$PC"; run C3 cbm --check; rc=$?
chk "check mode: succeeds, no change, no installer run"                      '[[ $rc -eq 0 && ! -s $FAKE_LOG ]] && grep -q "changed=0" "$W/out.C3"'
reset_cbm "$PC"; run C3b cbm; rc=$?
chk "a real run: no installer run either"                                    '[[ $rc -eq 0 && ! -s $FAKE_LOG ]] && grep -q "changed=0" "$W/out.C3b"'

echo "== C4. a wrong installer checksum"
reset_cbm; run C4 cbm-badsum >/dev/null 2>&1; rc=$?
chk "fails"                                                                  '[[ $rc -ne 0 ]]'
chk "installs nothing and runs no installer"                                 '[[ ! -e $W/bin/codebase-memory-mcp && ! -s $FAKE_LOG ]]'

echo "== C5. install_cbm: false"
reset_cbm; run C5 cbm-off; rc=$?
chk "nothing is probed, downloaded or installed"                             '[[ $rc -eq 0 && ! -e $W/bin/codebase-memory-mcp && ! -s $FAKE_LOG ]]'

echo; echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
