#!/bin/bash
# Test: install_codebasemem.yml (the per-user install into ~/.local/bin) must install the PINNED Codebase Memory release and change nothing on
# a second run. It fetched the installer from the floating `main` branch into the fixed path /tmp/cbm-install.sh and ran it with its default
# (LATEST) release, guarded only by "the file exists". Now: probe the installed version; if the binary is missing or another version, fetch the installer
# of the vX.Y.Z TAG into a private temp file (sha256 checked), run it with CBM_DOWNLOAD_URL at that release, verify the version, remove the file.
# The real tasks are taken out of the playbook (by name) and run with ansible against a temp HOME. SAFETY: the play environment sets HOME to the
# temp dir and sends all proxies to a dead address, so even the OLD tasks (red run) can neither reach the network nor touch the real ~/.local/bin;
# the fake installer refuses to write outside the temp dir. Needs ansible-playbook (PATH or ANSIBLE_PLAYBOOK) and python3 + PyYAML; skips without them.
# usage: test-codebasemem-user-pin.sh [REPO_ROOT]   (default: the checkout this test lives in)
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
HOME_T=$W/home; BIN=$HOME_T/.local/bin; mkdir -p "$BIN" "$W/server" "$W/state"
export FAKE_ROOT=$W FAKE_LOG=$W/installer.log; : > "$FAKE_LOG"
cat > "$W/server/install.sh" <<'STUB'
#!/bin/bash
# fake codebase-memory-mcp installer: --dir=PATH (default ~/.local/bin of the process HOME). The version comes from CBM_DOWNLOAD_URL
# (.../download/vX.Y.Z); with no pin it is the "latest" (0.12.1).
dir="$HOME/.local/bin"; for a; do case $a in --dir=*) dir=${a#--dir=} ;; esac; done
[[ $dir == "$FAKE_ROOT"/* ]] || { echo "fake installer: refusing to write outside $FAKE_ROOT ($dir)" >&2; exit 1; }
echo "installer ran: url=${CBM_DOWNLOAD_URL:-unset} dir=$dir" >> "$FAKE_LOG"
ver=0.12.1; [[ ${CBM_DOWNLOAD_URL:-} =~ /download/v([0-9.]+)$ ]] && ver=${BASH_REMATCH[1]}
mkdir -p "$dir"; printf '#!/bin/bash\necho "codebase-memory-mcp %s"\n' "$ver" > "$dir/codebase-memory-mcp"; chmod +x "$dir/codebase-memory-mcp"
STUB
chmod +x "$W/server/install.sh"
GOODSUM=$(sha256sum "$W/server/install.sh" | cut -d' ' -f1)

python3 -I - "$R" "$W" "$GOODSUM" <<'PY'
import sys, yaml, json
root, w, goodsum = sys.argv[1:4]
p = yaml.safe_load(open(f"{root}/install_codebasemem.yml"))[0]
sel = [t for t in p["tasks"] if any(x in str(t.get("name", "")) for x in ("Which Codebase Memory is installed", "Install Codebase Memory", "Verify installation"))]
home = f"{w}/home"
env = {"HOME": home, "FAKE_ROOT": w, "FAKE_LOG": f"{w}/installer.log",
       "http_proxy": "http://127.0.0.1:9", "https_proxy": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9", "HTTPS_PROXY": "http://127.0.0.1:9"}
def write(name, over):
    v = dict(p.get("vars", {})); v.update({"ansible_env": {"HOME": home}}); v.update(over)
    yaml.safe_dump([{"hosts": "localhost", "connection": "local", "gather_facts": False, "become": False, "environment": env, "vars": v, "tasks": sel}],
                   open(f"{w}/{name}.yml", "w"))
    return v
v = write("play", {"cbm_installer_url": f"file://{w}/server/install.sh", "cbm_installer_sha256": goodsum})
write("play-badsum", {"cbm_installer_url": f"file://{w}/server/install.sh", "cbm_installer_sha256": "0" * 64})
json.dump({"cbm": v.get("cbm_version")}, open(f"{w}/pins.json", "w"))
print(len(sel), "tasks selected")
PY
PC=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["cbm"] or "")' "$W/pins.json")
echo "pin read from the playbook: codebase-memory-mcp='${PC:-<none>}'"
run() { local n=$1 f=$2; shift 2; "$AP" -i localhost, "$@" "$W/$f.yml" >"$W/out.$n" 2>&1; local rc=$?
  [[ $rc -eq 0 ]] || grep -h -E 'fatal:|"msg"' "$W/out.$n" | head -2 | cut -c1-230 | sed 's/^/        | /'; return $rc; }
reset() { rm -f "$BIN/codebase-memory-mcp"; : > "$FAKE_LOG"; [[ -z ${1:-} ]] || { printf '#!/bin/bash\necho "codebase-memory-mcp %s"\n' "$1" > "$BIN/codebase-memory-mcp"; chmod +x "$BIN/codebase-memory-mcp"; }; }
ver() { "$BIN/codebase-memory-mcp" --version 2>/dev/null | awk '{print $2}'; }
df() { sed -n "s/^ARG $1=//p" "$R/docker/vibe-cbm/Dockerfile" | head -n 1; }

echo "== 0. the pin"
chk "the playbook pins $PC; the Dockerfile CBM_VERSION is $(df CBM_VERSION)"                       '[[ -n $PC && $PC == "$(df CBM_VERSION)" ]]'
chk "the installer checksum equals the Dockerfile's and configure_vibe_lumiether.yml's"            'grep -q "$(df CBM_INSTALLER_SHA256)" "$R/install_codebasemem.yml" && grep -q "$(df CBM_INSTALLER_SHA256)" "$R/configure_vibe_lumiether.yml"'
chk "no fixed /tmp/cbm-install.sh path and no installer from the main branch any more"             '! grep -q "/tmp/cbm-install.sh" "$R/install_codebasemem.yml" && ! grep -q "codebase-memory-mcp/main/install.sh" "$R/install_codebasemem.yml"'

echo "== U1. a user without the binary"
reset; run U1 play; rc=$?
chk "succeeds and the binary reports $PC (not the latest 0.12.1)"        '[[ $rc -eq 0 && $(ver) == "$PC" ]]'
chk "the installer was told to download that tag's release, into the user's ~/.local/bin"  'grep -q "installer ran: url=https://github.com/DeusData/codebase-memory-mcp/releases/download/v$PC dir=$BIN\$" "$FAKE_LOG"'
chk "no installer file is left in /tmp"                                  '[[ -z $(ls /tmp 2>/dev/null | grep -E "cbm-install") ]]'
run U1b play; rc=$?
chk "second run: succeeds, runs no installer, changes nothing"           '[[ $rc -eq 0 && $(grep -c "installer ran" "$FAKE_LOG") -eq 1 ]] && grep -q "changed=0" "$W/out.U1b"'

echo "== U2. another version is there (0.12.1)"
reset 0.12.1; run U2 play; rc=$?
chk "it is put on the pinned version"                                    '[[ $rc -eq 0 && $(ver) == "$PC" ]]'
run U2b play; rc=$?
chk "second run: nothing changes"                                        '[[ $rc -eq 0 ]] && grep -q "changed=0" "$W/out.U2b"'

echo "== U3. already on the pinned version (like node-2), check mode and a real run"
reset "$PC"; run U3 play --check; rc=$?
chk "check mode: succeeds, no change, no installer run"                  '[[ $rc -eq 0 && ! -s $FAKE_LOG ]] && grep -q "changed=0" "$W/out.U3"'
reset "$PC"; run U3b play; rc=$?
chk "a real run: no installer run either"                                '[[ $rc -eq 0 && ! -s $FAKE_LOG ]] && grep -q "changed=0" "$W/out.U3b"'

echo "== U4. a wrong installer checksum"
reset; run U4 play-badsum >/dev/null 2>&1; rc=$?
chk "fails, installs nothing, runs no installer"                         '[[ $rc -ne 0 && ! -e $BIN/codebase-memory-mcp && ! -s $FAKE_LOG ]]'

echo; echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
