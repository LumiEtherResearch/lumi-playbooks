#!/bin/bash
# Test: Plum's own config (~/.vibe-plum/config.toml) must get its provider and models without a hand-made base config.
# tasks/plum_readonly_user.yml seeds ~/.vibe-plum/config.toml ONCE from the user's normal ~/.vibe/config.toml, then required that copy to
# already contain `models = [` and a `provider = "wif-local"` entry. On node-2 every user has them by hand (nothing in the IaC writes
# them: merge-config.py manages only default_agent and the mcp_servers blocks), so on a new server the play failed with
# "Plum config has a models list that can be extended". Now:
#   A. a new server's config (no providers, no models)      -> the play appends the provider and both models; Plum ends up complete
#   B. node-2's config (inline `models = [`, `providers`)    -> the model is added to the inline list as before; no second provider
#   C. both are idempotent on a second run, and the user's own ~/.vibe/config.toml is never changed
#   D. a config this play cannot extend (providers but no models) -> a clear failure, nothing is guessed
# The real tasks are taken out of tasks/plum_readonly_user.yml (by name) and run with ansible against a temp home; needs ansible-playbook
# (PATH or ANSIBLE_PLAYBOOK), python3 + PyYAML, and a user whose primary group has the same name; skips without them.
# usage: test-plum-models-bootstrap.sh [REPO_ROOT]   (default: the checkout this test lives in)
set -u
R=${1:-$(cd "$(dirname "$0")/.." && pwd)}
AP=${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook || true)}
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
chk() { if eval "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }
[[ -n $AP && -x $AP ]] || { echo "SKIP: needs ansible-playbook (PATH or ANSIBLE_PLAYBOOK)"; exit 0; }
python3 -I -c 'import yaml' 2>/dev/null || { echo "SKIP: needs python3 PyYAML"; exit 0; }
ME=$(id -un); [[ $ME == "$(id -gn)" ]] || { echo "SKIP: needs a user whose primary group has the same name"; exit 0; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export ANSIBLE_HOME=$W/ansible-home ANSIBLE_NOCOLOR=1 ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False
H=$W/home/$ME

# the Plum-config tasks of the real tasks file, in file order, with the play's real variables
python3 -I - "$R" "$W/play.yml" "$H" "$ME" <<'PY'
import sys, yaml
root, out, home, user = sys.argv[1:5]
tasks = yaml.safe_load(open(f"{root}/tasks/plum_readonly_user.yml"))
flat = []
for t in tasks:
    flat += t["block"] if "block" in t else [t]
want = ("Plum config, seeded once", "Plum starts in the chat agent", "exactly one default_agent", "models list", "Plum config models state",
        "Plum config models are", "Plum provider and models", "Plum model ", "Plum uses ", "exactly one active_model", "Plum config verified")
sel = [t for t in flat if any(w in str(t.get("name", "")) for w in want)]
pv = yaml.safe_load(open(f"{root}/configure_plum_readonly.yml"))[0]["vars"]
keep = ("plum_model_name", "plum_model_alias", "plum_provider_name", "plum_provider_api_base", "plum_base_model_name", "plum_base_model_alias")
v = {k: pv[k] for k in keep if k in pv}; v.update(pr=user, pr_home=home)
yaml.safe_dump([{"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": v, "tasks": sel}], open(out, "w"))
print(len(sel), "tasks selected")
PY

BASE_FRESH='default_agent = "lumiether"

# >>> LUMIETHER MANAGED (tables) >>>
[[mcp_servers]]
name = "codebase-memory-mcp"
transport = "stdio"
command = "/usr/local/bin/codebase-memory-mcp"
args = []
# <<< LUMIETHER MANAGED (tables) <<<

[tools.bash]
permission = "ask"
allowlist = ["ls", "cat"]
'
BASE_NODE2='active_model = "mistral-small-4"
default_agent = "lumiether"
models = [
    { name = "mistral-small-2603", provider = "wif-local", alias = "mistral-small-4" },
]
providers = [
    { name = "wif-local", api_base = "http://127.0.0.1:8090/v1", backend = "generic" },
]

[[mcp_servers]]
name = "codebase-memory-mcp"
transport = "stdio"
command = "/usr/local/bin/codebase-memory-mcp"
args = []
'
BASE_PARTIAL='default_agent = "lumiether"
providers = [
    { name = "wif-local", api_base = "http://127.0.0.1:8090/v1", backend = "generic" },
]
'
run() { # run NAME  : the Plum-config tasks as the user; output in $W/out.NAME
  "$AP" -i localhost, "$W/play.yml" >"$W/out.NAME.tmp" 2>&1; local rc=$?; mv "$W/out.NAME.tmp" "$W/out.$1"
  [[ $rc -eq 0 ]] || grep -h -E 'fatal:|"msg"' "$W/out.$1" | head -2 | cut -c1-230 | sed 's/^/        | /'
  return $rc
}
setup() { rm -rf "$W/home"; mkdir -p "$H/.vibe" "$H/.vibe-plum"; printf '%s' "$1" > "$H/.vibe/config.toml"; }
tomlq() { python3 -I -c 'import sys,tomllib,json; c=tomllib.load(open(sys.argv[1],"rb")); print(json.dumps(eval(sys.argv[2])))' "$H/.vibe-plum/config.toml" "$1"; }

echo "== A. a new server: the normal config has no provider and no models"
setup "$BASE_FRESH"; before=$(sha256sum < "$H/.vibe/config.toml"); run A; rc=$?
chk "the Plum tasks succeed"                                                  '[[ $rc -eq 0 ]]'
chk "the Plum config is valid TOML with the provider once"                    '[[ $(tomlq "[p[\"name\"] for p in c[\"providers\"]]") == "[\"wif-local\"]" ]]'
chk "... the provider points at the host adapter, without a key"              '[[ $(tomlq "[[p[\"api_base\"], \"api_key_env_var\" in p] for p in c[\"providers\"]]") == "[[\"http://127.0.0.1:8090/v1\", false]]" ]]'
chk "... both models are defined: the small one and the Plum model"           '[[ $(tomlq "sorted(m[\"alias\"] for m in c[\"models\"])") == "[\"mistral-large\", \"mistral-small-4\"]" ]]'
chk "... every model uses the provider"                                       '[[ $(tomlq "sorted({m[\"provider\"] for m in c[\"models\"]})") == "[\"wif-local\"]" ]]'
chk "Plum uses the large model and starts in the chat agent"                  '[[ $(tomlq "[c[\"active_model\"], c[\"default_agent\"]]") == "[\"mistral-large\", \"lumiether-chat\"]" ]]'
chk "the user's own mcp_servers entry came along"                             '[[ $(tomlq "[s[\"name\"] for s in c[\"mcp_servers\"]]") == "[\"codebase-memory-mcp\"]" ]]'
run A2; rc=$?
chk "second run: succeeds and changes nothing"                                '[[ $rc -eq 0 ]] && grep -q "changed=0" "$W/out.A2"'
chk "... still one provider and two models"                                   '[[ $(tomlq "[len(c[\"providers\"]), len(c[\"models\"])]") == "[1, 2]" ]]'
chk "the user's own ~/.vibe/config.toml was not changed"                      '[[ $(sha256sum < "$H/.vibe/config.toml") == "$before" ]]'

echo "== B. node-2: the normal config already has models and providers (inline lists)"
setup "$BASE_NODE2"; before=$(sha256sum < "$H/.vibe/config.toml"); run B; rc=$?
chk "the Plum tasks succeed"                                                  '[[ $rc -eq 0 ]]'
chk "one provider (no second one added)"                                      '[[ $(tomlq "len(c[\"providers\"])") == 1 ]]'
chk "the small model from the user's config and the Plum model are there"     '[[ $(tomlq "sorted(m[\"alias\"] for m in c[\"models\"])") == "[\"mistral-large\", \"mistral-small-4\"]" ]]'
chk "Plum uses the large model and starts in the chat agent"                  '[[ $(tomlq "[c[\"active_model\"], c[\"default_agent\"]]") == "[\"mistral-large\", \"lumiether-chat\"]" ]]'
run B2; rc=$?
chk "second run: succeeds and changes nothing"                                '[[ $rc -eq 0 ]] && grep -q "changed=0" "$W/out.B2"'
chk "the user's own ~/.vibe/config.toml was not changed"                      '[[ $(sha256sum < "$H/.vibe/config.toml") == "$before" ]]'

echo "== D. a shape this play cannot extend: providers but no models"
setup "$BASE_PARTIAL"; run D >/dev/null 2>&1; rc=$?
chk "fails"                                                                   '[[ $rc -ne 0 ]]'
chk "... with a message that names providers and models"                      'grep -i "providers" "$W/out.D" | grep -qi "models"'

echo; echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
