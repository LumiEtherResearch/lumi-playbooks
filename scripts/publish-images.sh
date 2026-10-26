#!/bin/bash
# Publish the container images node-2 depends on to the private GHCR registry of the org.
#
# Usage: scripts/publish-images.sh [--dry-run] running|plum|vibe
#   running  tag and push the vibe-cbm image that is running right now, unchanged (safety copy)
#   plum     push the pinned third-party plum image as a mirror
#   vibe     build docker/vibe-cbm with its pinned Dockerfile, check the tool versions, push
#   --dry-run  print the docker commands, run none that change anything
#
# Registry credentials are never handled here. Log in first, in your own terminal:
#   docker login ghcr.io -u <github-user>     (Docker prompts for the token; use a PAT with write:packages)
# and `docker logout ghcr.io` afterwards. Each push prints the digest to pin in compose or OpenTofu.
set -euo pipefail

ORG=ghcr.io/lumiether-research
PLUM_LOCAL=${PLUM_LOCAL:-valentin2177/plum-code-webui@sha256:2918a8161065f1034d3233ca739c97453ae251343fe217b40ec61b8b8cdda2fd}
REPO_ROOT=$(git rev-parse --show-toplevel)
DOCKERFILE=$REPO_ROOT/docker/vibe-cbm/Dockerfile

die() { echo "publish-images.sh: $*" >&2; exit 1; }
say() { echo "== $*" >&2; }

DRY=0
if [[ ${1:-} == --dry-run ]]; then DRY=1; shift; fi
[[ $# -eq 1 ]] || die "usage: $0 [--dry-run] running|plum|vibe"
WHAT=$1

run() { # run CMD...   (printed; executed unless --dry-run)
  echo "+ $*" >&2
  if [[ $DRY -eq 0 ]]; then "$@"; fi
}

dockerfile_arg() { # dockerfile_arg NAME -> default value of ARG NAME
  sed -n "s/^ARG $1=//p" "$DOCKERFILE" | head -n 1
}

check_login() {
  [[ $DRY -eq 1 ]] && return 0
  # Only the registry names in the config are looked at, never the credentials.
  python3 -I - <<'PY' || die "not logged in to ghcr.io; run: docker login ghcr.io -u <github-user>"
import json, os, sys
try:
    cfg = json.load(open(os.path.expanduser("~/.docker/config.json")))
except OSError:
    sys.exit(1)
sys.exit(0 if "ghcr.io" in cfg.get("auths", {}) or cfg.get("credsStore") else 1)
PY
}

push_and_report() { # push_and_report REF
  run docker push "$1"
  if [[ $DRY -eq 1 ]]; then return 0; fi
  local digest
  digest=$(docker image inspect "$1" --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep -F "${1%%:*}@" | head -n 1)
  [[ -n $digest ]] || die "pushed $1 but could not read its registry digest"
  say "pin: $digest"
}

case $WHAT in
  running)
    id=$(docker inspect vibe-cbm --format '{{.Image}}')
    day=$(docker image inspect "$id" --format '{{slice .Created 0 10}}')
    ref=$ORG/vibe-cbm:running-$day
    check_login
    run docker tag "$id" "$ref"
    push_and_report "$ref"
    ;;
  plum)
    rev=$(docker image inspect "$PLUM_LOCAL" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
    day=$(docker image inspect "$PLUM_LOCAL" --format '{{slice .Created 0 10}}')
    ref=$ORG/plum-code-webui:$day-${rev:0:7}
    check_login
    run docker tag "$PLUM_LOCAL" "$ref"
    push_and_report "$ref"
    if [[ $DRY -eq 0 && $(docker image inspect "$ref" --format '{{.Id}}') != "$(docker image inspect "$PLUM_LOCAL" --format '{{.Id}}')" ]]; then
      die "mirrored image id differs from the source"
    fi
    ;;
  vibe)
    if [[ -n $(git -C "$REPO_ROOT" status --porcelain -- docker/vibe-cbm) ]]; then
      die "docker/vibe-cbm has uncommitted changes; commit first so the tag's git sha means something"
    fi
    vibe=$(dockerfile_arg VIBE_VERSION); cbm=$(dockerfile_arg CBM_VERSION); uv=$(dockerfile_arg UV_VERSION)
    [[ -n $vibe && -n $cbm && -n $uv ]] || die "could not read the version ARGs from $DOCKERFILE"
    ref=$ORG/vibe-cbm:vibe$vibe-cbm$cbm
    sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
    check_login
    run docker build -t "$ref" -t "$ref-$sha" "$REPO_ROOT/docker/vibe-cbm"
    if [[ $DRY -eq 0 ]]; then
      out=$(docker run --rm --entrypoint sh "$ref" -c 'vibe --version; uv --version; codebase-memory-mcp --version')
      for want in "$vibe" "uv $uv" "$cbm"; do
        grep -qF "$want" <<<"$out" || die "built image does not report '$want'; got: $out"
      done
      say "versions OK: $(tr '\n' ';' <<<"$out")"
    fi
    run docker push "$ref-$sha"
    push_and_report "$ref"
    ;;
  *) die "usage: $0 [--dry-run] running|plum|vibe" ;;
esac
