#!/bin/bash
# The tunnel values are REQUIRED variables in configure_cloudflared.yml and configure_spire_oidc.yml: the first task of each play asserts them,
# so a launch without them fails before anything on the host changes, instead of silently using production's tunnel. The values come from
# bootstrap/tunnel.yml in infra-bootstrap, through the AWX templates (awx-config bakes them in as extra vars: they outrank play vars).
#
# No ansible on the build host is needed: the assert's conditions are evaluated with jinja2 (the match test is Ansible's re.match), and the
# templated text of every task that uses the tunnel variables is rendered from the OLD playbook (BASE, default ae22271) with its own
# defaults, and from the NEW playbook with those same values supplied as extra vars: the two must be identical, which is the proof that the
# old behaviour is still reachable. Identifiers only; no secrets.
# usage: tests/test-tunnel-vars.sh [REPO_ROOT]       env: TUNNEL_VARS_BASE (default ae22271)
set -u
R=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BASE=${TUNNEL_VARS_BASE:-ae22271}
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
python3 -I -c 'import yaml, jinja2' 2>/dev/null || { echo "SKIP: needs python3 with PyYAML and jinja2"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for f in configure_cloudflared.yml configure_spire_oidc.yml; do
  git -C "$R" show "$BASE:$f" > "$W/old-$f" 2>/dev/null || { echo "SKIP: the base $BASE is not in this clone ($f)"; exit 0; }
done
cat > "$W/h.py" <<'PY'
import json, re, sys, yaml, jinja2

def env():
    e = jinja2.Environment(trim_blocks=True, keep_trailing_newline=True)
    e.tests["match"] = lambda v, p: re.match(p, str(v)) is not None
    e.filters["to_json"] = lambda v: json.dumps(v)
    e.filters["regex_replace"] = lambda v, pat, rep="": re.sub(pat, rep, str(v))
    e.filters["quote"] = lambda v: "'%s'" % v
    return e

def play(path):
    return yaml.safe_load(open(path))[0]

def first_failing(that, vs):
    """index of the first condition that is false (or raises), None when all hold: what ansible.builtin.assert does"""
    e = env()
    for i, c in enumerate(that):
        try:
            if not e.compile_expression(c)(**vs):
                return i
        except Exception:
            return i
    return None

def resolve(vs):
    e = env()
    for _ in range(6):
        for k, v in list(vs.items()):
            if isinstance(v, str) and "{{" in v:
                vs[k] = e.from_string(v).render(**vs)
    return vs

def strings(o):
    if isinstance(o, str): yield o
    elif isinstance(o, dict):
        for k, v in o.items():
            if k not in ("fail_msg", "success_msg"): yield from strings(v)   # the wording of messages may change; the templated settings may not
    elif isinstance(o, list):
        for v in o: yield from strings(v)

KEYS = ("cloudflared_tunnel_id", "cloudflared_ingress", "spire_oidc_domains")

def rendered(path, vs, skip_first=False):
    p = play(path); e = env(); out = []
    for t in (p["tasks"][1:] if skip_first else p["tasks"]):      # the new play's first task is the guard (tested above), not a setting
        for s in strings(t):
            if "{{" in s and any(k in s for k in KEYS):
                out.append(e.from_string(s).render(**vs))
    return out

def base_vars(path, extra_files=()):
    p = play(path); vs = {}
    for f in extra_files: vs.update(yaml.safe_load(open(f)))
    vs.update(p.get("vars", {})); return vs

cmd = sys.argv[1]
if cmd == "firsttask":
    p = play(sys.argv[2]); t = p["tasks"][0]
    print(json.dumps({"module": [k for k in t if k.startswith("ansible.builtin.") or k in ("assert", "stat", "command", "apt")],
                      "name": t.get("name", ""), "that": t.get("ansible.builtin.assert", {}).get("that", []),
                      "fail_msg": t.get("ansible.builtin.assert", {}).get("fail_msg", ""),
                      "other_sections": [k for k in ("pre_tasks", "roles", "vars_prompt", "import_playbook") if k in p],
                      "vars": sorted(p.get("vars", {}).keys())}))
elif cmd == "assert":      # assert PLAYBOOK 'JSON vars' -> "pass" or the failing condition index
    p = play(sys.argv[2]); that = p["tasks"][0]["ansible.builtin.assert"]["that"]
    r = first_failing(that, json.loads(sys.argv[3])); print("pass" if r is None else "fail:%d" % r)
elif cmd == "same":        # same OLD NEW EXTRA_FILES... : the new playbook with the old defaults as extra vars renders what the old one did
    old, new = sys.argv[2], sys.argv[3]; extra = sys.argv[4:]
    vo = resolve(base_vars(old, extra)); keys = {k: vo[k] for k in KEYS if k in vo}
    vn = base_vars(new, extra); vn.update(keys); vn = resolve(vn)
    a, b = rendered(old, vo), rendered(new, vn, skip_first=True)
    print("same" if a == b and a else "different(%d vs %d)" % (len(a), len(b)))
PY
H() { python3 -I "$W/h.py" "$@" 2>"$W/err"; }
CF=$R/configure_cloudflared.yml; SP=$R/configure_spire_oidc.yml
jget() { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }

ID=22222222-2222-4222-8222-222222222222
GOODCF='{"cloudflared_tunnel_id":"'$ID'","cloudflared_ingress":[{"hostname":"app.example.org","service":"http://127.0.0.1:8082"}]}'
GOODSP='{"spire_oidc_domains":["app.example.org"]}'

for pbk in cloudflared spire; do
  if [[ $pbk == cloudflared ]]; then P=$CF; GOOD=$GOODCF; else P=$SP; GOOD=$GOODSP; fi
  echo "== $(basename "$P"): the assert is the first task and the variables are required"
  FT=$(H firsttask "$P"); [[ -n $FT ]] || FT='{}'
  [[ $(jget "$FT" module) == *assert* ]] && ok "the first task is ansible.builtin.assert" || bad "the first task is ansible.builtin.assert (found: $(jget "$FT" module))"
  [[ $(jget "$FT" other_sections) == "[]" ]] && ok "no pre_tasks, roles, vars_prompt or imported playbook can run before it" || bad "no pre_tasks, roles, vars_prompt or imported playbook can run before it"
  if [[ $pbk == cloudflared ]]; then
    [[ $(jget "$FT" vars) != *cloudflared_tunnel_id* && $(jget "$FT" vars) != *cloudflared_ingress* ]] && ok "the play no longer defines cloudflared_tunnel_id or cloudflared_ingress" || bad "the play no longer defines cloudflared_tunnel_id or cloudflared_ingress"
  else
    [[ $(jget "$FT" vars) != *spire_oidc_domains* ]] && ok "the play no longer defines spire_oidc_domains" || bad "the play no longer defines spire_oidc_domains"
  fi
  grep -qE '452db3bb|identity\.caymas\.in' "$P" && bad "no production tunnel ID or host name is left in the playbook (not even in a comment)" || ok "no production tunnel ID or host name is left in the playbook (not even in a comment)"
  fm=$(jget "$FT" fail_msg)
  [[ $fm == *tunnel.yml* && $fm == *awx-config* ]] && ok "the failure message names bootstrap/tunnel.yml and awx-config" || bad "the failure message names bootstrap/tunnel.yml and awx-config"
  [[ $(H assert "$P" "$GOOD") == pass ]] && ok "good values pass the assert" || bad "good values pass the assert (got: $(H assert "$P" "$GOOD"))"
  [[ $(H assert "$P" '{}') == fail* ]] && ok "no values at all: the assert fails" || bad "no values at all: the assert fails"
done

echo "== configure_cloudflared.yml: what the assert refuses"
r() { H assert "$CF" "$1"; }
no() { [[ $(r "$2") == fail* && $(r "$GOODCF") == pass ]] && ok "refused: $1" || bad "refused: $1"; }
no "tunnel ID missing"                '{"cloudflared_ingress":[{"hostname":"app.example.org","service":"http://127.0.0.1:8082"}]}'
no "tunnel ID not a UUID"             '{"cloudflared_tunnel_id":"abc","cloudflared_ingress":[{"hostname":"app.example.org","service":"http://127.0.0.1:8082"}]}'
no "tunnel ID in upper case"          '{"cloudflared_tunnel_id":"22222222-2222-4222-8222-22222222222A","cloudflared_ingress":[{"hostname":"app.example.org","service":"http://127.0.0.1:8082"}]}'
no "tunnel ID with a suffix"          '{"cloudflared_tunnel_id":"'$ID'x","cloudflared_ingress":[{"hostname":"app.example.org","service":"http://127.0.0.1:8082"}]}'
no "ingress missing"                  '{"cloudflared_tunnel_id":"'$ID'"}'
no "ingress empty"                    '{"cloudflared_tunnel_id":"'$ID'","cloudflared_ingress":[]}'
no "ingress is a string"              '{"cloudflared_tunnel_id":"'$ID'","cloudflared_ingress":"app.example.org"}'
no "a rule without a hostname"        '{"cloudflared_tunnel_id":"'$ID'","cloudflared_ingress":[{"service":"http://127.0.0.1:8082"}]}'
no "a hostname with https://"         '{"cloudflared_tunnel_id":"'$ID'","cloudflared_ingress":[{"hostname":"https://app.example.org","service":"http://127.0.0.1:8082"}]}'
no "a bare label as hostname"         '{"cloudflared_tunnel_id":"'$ID'","cloudflared_ingress":[{"hostname":"localhost","service":"http://127.0.0.1:8082"}]}'
no "a service that is not local"      '{"cloudflared_tunnel_id":"'$ID'","cloudflared_ingress":[{"hostname":"app.example.org","service":"http://10.0.0.5:8082"}]}'
no "a rule without a service"         '{"cloudflared_tunnel_id":"'$ID'","cloudflared_ingress":[{"hostname":"app.example.org"}]}'
no "one good rule and one bad rule"   '{"cloudflared_tunnel_id":"'$ID'","cloudflared_ingress":[{"hostname":"app.example.org","service":"http://127.0.0.1:8082"},{"hostname":"x","service":"y"}]}'
[[ $(r '{"cloudflared_tunnel_id":"'$ID'","cloudflared_ingress":[{"hostname":"a.example.org","service":"http://127.0.0.1:8082"},{"hostname":"b.example.org","service":"http://127.0.0.1:9000"}]}') == pass ]] && ok "two good rules pass" || bad "two good rules pass"

echo "== configure_spire_oidc.yml: what the assert refuses"
s() { H assert "$SP" "$1"; }
nos() { [[ $(s "$2") == fail* && $(s "$GOODSP") == pass ]] && ok "refused: $1" || bad "refused: $1"; }
nos "domains missing"           '{}'
nos "domains empty"             '{"spire_oidc_domains":[]}'
nos "domains is a string"       '{"spire_oidc_domains":"app.example.org"}'
nos "a domain with https://"    '{"spire_oidc_domains":["https://app.example.org"]}'
nos "a bare label as a domain"  '{"spire_oidc_domains":["localhost"]}'
nos "one good and one bad"      '{"spire_oidc_domains":["app.example.org","x_y"]}'

echo "== the old behaviour is still reachable: the same values, supplied as extra vars, give the same text"
c=$(H same "$W/old-configure_cloudflared.yml" "$CF"); [[ $c == same ]] && ok "configure_cloudflared.yml: the rendered tasks are identical to the old playbook's" || bad "configure_cloudflared.yml: the rendered tasks are identical to the old playbook's ($c; $(head -c 200 "$W/err"))"
c=$(H same "$W/old-configure_spire_oidc.yml" "$SP" "$R/vars/spire.yml"); [[ $c == same ]] && ok "configure_spire_oidc.yml: the rendered tasks are identical to the old playbook's" || bad "configure_spire_oidc.yml: the rendered tasks are identical to the old playbook's ($c; $(head -c 200 "$W/err"))"
grep -q 'tunnel.yml' "$CF" && grep -q 'tunnel.yml' "$SP" && ok "both headers say where the values come from (bootstrap/tunnel.yml)" || bad "both headers say where the values come from (bootstrap/tunnel.yml)"
echo; echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
