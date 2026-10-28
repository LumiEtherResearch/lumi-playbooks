#!/bin/bash
# Regression test: a compose service must not have BOTH `build:` and an `image:` that contains a digest (@sha256:...).
# With both, compose uses `image:` as the tag of the image it builds, and a tag cannot contain a digest, so a Portainer deploy of the
# file fails with "build tag cannot contain a digest". Checks every docker/*/docker-compose*.yml (YAML only; nothing is built or pulled).
# Needs python3 with PyYAML (skips without it).
# usage: test-compose-digest-build.sh [REPO_ROOT]   (default: the checkout this test lives in)
set -u
R=${1:-$(cd "$(dirname "$0")/.." && pwd)}
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
python3 -I -c 'import yaml' 2>/dev/null || { echo "SKIP: needs python3 PyYAML"; exit 0; }

found=0
for f in "$R"/docker/*/docker-compose*.yml; do
  [[ -f $f ]] || continue
  found=1
  bad_svcs=$(python3 -I -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for name, svc in (d.get("services") or {}).items():
    if isinstance(svc, dict) and "build" in svc and "@" in str(svc.get("image", "")):
        print(name)' "$f")
  if [[ -z $bad_svcs ]]; then ok "${f#"$R"/}: no service combines build: with an image pinned by digest"
  else bad "${f#"$R"/}: build: together with a digest-pinned image: $(echo $bad_svcs)"; fi
done
[[ $found -eq 1 ]] || bad "no docker/*/docker-compose*.yml found under $R"

echo; echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
