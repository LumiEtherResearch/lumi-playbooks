#!/bin/bash
# Encrypted backup of node-2 state: a data archive and a secrets archive, each with its own passphrase.
#
# Usage: scripts/backup.sh [--check]
#   --check     preflight only: verify tools, containers, volumes and paths, print the plan, change nothing.
#   --test-awx  run only the AWX dump step (dump, copy out, checksum, validate), keep nothing.
#
# Output (BACKUP_DIR, default /var/backups/lumi):
#   lumi-data-<UTC>.tar.zst.gpg     OpenTofu state, DB dumps, Docker volumes, /srv/plum*
#   lumi-secrets-<UTC>.tar.zst.gpg  ~/.ssh, ~/.cloudflared, /etc/lumiether (incl. deploy keys)
#   <archive>.sha256                checksum to verify the copy after scp
#
# Passphrases are read from the terminal, held in shell memory and handed to gpg over a pipe
# (fd 3). They never reach a file or a command line. Copying off-host is manual (scp).
# Restore with scripts/restore.sh.
set -euo pipefail
umask 077

OUT=${BACKUP_DIR:-/var/backups/lumi}
BOOT=${INFRA_BOOTSTRAP:-$HOME/infra-bootstrap}
TS=$(date -u +%Y%m%dT%H%M%SZ)
IMG=postgres:17-alpine          # already present on the host; used for volume tars (no pull)
AWX_NS=awx
AWX_POD=awx-demo-postgres-15-0

# Plum DB containers: dumped with pg_dumpall (a raw copy of a live data dir is not consistent).
PLUM_PG=(plum-postgres plum-abhi-postgres plum-anish-postgres plum-arun-postgres)
# Volumes copied while their container runs (best effort; the container is not stopped).
HOT_VOLUMES=(vibe-cbm_cbm-data vibe-cbm_vibe-config vibe-cbm_workspaces)
# container:volume pairs copied with the container stopped, one at a time.
STOP_VOLUMES=(portainer:portainer_data spire-server:spire-server_spire_server_data)
STATE_FILES=(terraform.tfstate terraform.tfstate.backup
  awx-config/terraform.tfstate awx-config/terraform.tfstate.backup
  portainer-config/terraform.tfstate portainer-config/terraform.tfstate.backup)
# Paths for the secrets archive, relative to /.
SECRET_PATHS=("${HOME#/}/.ssh" "${HOME#/}/.cloudflared" etc/lumiether
  "${BOOT#/}/awx-config/.envrc-awx" "${BOOT#/}/portainer-config/.envrc-portainer")

die() { echo "backup.sh: $*" >&2; exit 1; }
say() { echo "== $*" >&2; }

MODE=run
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  --test-awx) MODE=test-awx ;;
  *) die "usage: $0 [--check | --test-awx]" ;;
esac

ask_pass() { # ask_pass VAR LABEL  (prompt twice, store in VAR)
  local a b
  while :; do
    read -rsp "Passphrase for the $2 archive (min 12 chars): " a </dev/tty; echo >&2
    read -rsp "Repeat passphrase: " b </dev/tty; echo >&2
    if [[ ${#a} -ge 12 && $a == "$b" ]]; then break; fi
    echo "Too short or mismatched, try again." >&2
  done
  printf -v "$1" '%s' "$a"
}

encrypt() { # encrypt PASSVAR OUTFILE  (plaintext on stdin)
  local -n pw=$1
  gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 \
    --symmetric --cipher-algo AES256 --s2k-digest-algo SHA512 --s2k-count 65011712 \
    --compress-algo none -o "$2" 3< <(printf '%s' "$pw")
}

decrypt() { # decrypt PASSVAR FILE  (plaintext on stdout)
  local -n pw=$1
  gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --decrypt "$2" 3< <(printf '%s' "$pw")
}

preflight() {
  local c v f p
  [[ $EUID -ne 0 ]] || die "run as the normal user (uses sudo where needed), not root"
  [[ $OUT == /* ]] || die "BACKUP_DIR must be an absolute path"
  for c in docker gpg zstd tar sha256sum sudo find xargs; do command -v "$c" >/dev/null || die "missing command: $c"; done
  sudo -n true 2>/dev/null || die "need passwordless sudo"
  docker image inspect "$IMG" >/dev/null 2>&1 || die "image $IMG not present locally"
  for c in "${PLUM_PG[@]}" portainer spire-server; do
    [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]] || die "container $c is not running"
  done
  for v in "${HOT_VOLUMES[@]}" "${STOP_VOLUMES[@]#*:}"; do
    docker volume inspect "$v" >/dev/null 2>&1 || die "volume $v not found"
  done
  sudo timeout 30 k3s kubectl -n "$AWX_NS" get pod "$AWX_POD" >/dev/null 2>&1 || die "AWX pod $AWX_POD not found"
  for f in "${STATE_FILES[@]}"; do [[ -f $BOOT/$f ]] || die "missing state file $BOOT/$f"; done
  for p in "${SECRET_PATHS[@]}"; do sudo test -e "/$p" || die "missing /$p"; done
  [[ -n $(sudo find /srv -maxdepth 1 -type d -name 'plum*' -print -quit) ]] || die "no /srv/plum* directories"
  local avail
  avail=$(df --output=avail -B1 "$(dirname "$OUT")" | tail -n 1)
  (( avail > 2 * 1024 ** 3 )) || die "less than 2 GiB free under $(dirname "$OUT")"
}

print_plan() {
  cat >&2 <<EOF
Plan ($TS), output in $OUT:
  data archive    lumi-data-$TS.tar.zst.gpg
    - OpenTofu state: ${#STATE_FILES[@]} files under $BOOT
    - pg_dumpall: ${PLUM_PG[*]}
    - pg_dump -Fc of the AWX database ($AWX_NS/$AWX_POD; the db user is not a superuser)
    - volumes, hot copy (containers keep running): ${HOT_VOLUMES[*]}
    - volumes, container stopped briefly (asks for Enter first): ${STOP_VOLUMES[*]}
    - /srv/plum* directories (hot copy)
  secrets archive lumi-secrets-$TS.tar.zst.gpg
    - /${SECRET_PATHS[0]}  /${SECRET_PATHS[1]}  /${SECRET_PATHS[2]}
    - /${SECRET_PATHS[3]}  /${SECRET_PATHS[4]}
  Not included: ~/lumians, the plum postgres raw volumes (dumps are used instead).
EOF
}

STAGE=
STOPPED=()
AWX_REMOTE=

# Every kubectl exec runs under timeout and never reads the terminal: `kubectl exec -i` can wait
# forever on stdin when the remote command stops reading it (e.g. pg_restore -l).
# KC_TIMEOUT (seconds) can be overridden per call.
kc() { sudo timeout "${KC_TIMEOUT:-120}" k3s kubectl -n "$AWX_NS" exec "$AWX_POD" -c postgres -- "$@" </dev/null; }

dump_awx() { # dump_awx DEST  (the awx database only, custom format; user and db name come from the pod's own env)
  local dest=$1 want got toc
  AWX_REMOTE=/tmp/awx-backup-$TS.dump
  KC_TIMEOUT=330 kc sh -c 'umask 077; timeout 300 pg_dump -w -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f "$1"' _ "$AWX_REMOTE" \
    || die "pg_dump in the AWX pod failed or timed out"
  want=$(kc sha256sum "$AWX_REMOTE") || die "could not checksum the dump in the pod"
  want=${want%% *}
  kc cat "$AWX_REMOTE" > "$dest" || die "could not copy the AWX dump out of the pod"
  got=$(sha256sum < "$dest"); got=${got%% *}
  [[ -n $want && $got == "$want" ]] || die "AWX dump checksum differs between pod and host"
  kc rm -f "$AWX_REMOTE" && AWX_REMOTE=
  # Validate on the host side in a scratch container (pg_restore reads the whole archive TOC).
  toc=$(timeout 60 docker run --rm -i --pull never --network none "$IMG" pg_restore -l < "$dest") \
    || die "AWX dump failed pg_restore -l"
  [[ $toc == *"TABLE DATA"* ]] || die "AWX dump has no table data"
  say "AWX dump OK: $(stat -c %s "$dest") bytes, sha256 ${got:0:12}, $(grep -c 'TABLE DATA' <<<"$toc") tables"
}

cleanup() {
  local rc=$? c
  for c in "${STOPPED[@]}"; do
    if docker start "$c" >/dev/null 2>&1; then echo "restarted $c" >&2
    else echo "WARNING: could not restart $c; run: docker start $c" >&2; fi
  done
  if [[ -n $AWX_REMOTE ]]; then kc rm -f "$AWX_REMOTE" >/dev/null 2>&1 || echo "WARNING: remove $AWX_REMOTE in pod $AWX_POD by hand" >&2; fi
  if [[ -n $STAGE ]]; then sudo rm -rf "$STAGE"; fi
  find "$OUT" -maxdepth 1 -name '*.partial' -delete
  exit "$rc"
}

setup_stage() {
  sudo install -d -m 700 -o "$(id -u)" -g "$(id -g)" "$OUT"
  STAGE=$(mktemp -d "$OUT/.stage-$TS.XXXXXX")
  trap cleanup EXIT
  trap 'exit 130' INT TERM
}

preflight
if [[ $MODE == test-awx ]]; then
  setup_stage
  mkdir "$STAGE/pg"
  dump_awx "$STAGE/pg/awx.dump"
  say "AWX step passed; test only, nothing kept"
  exit 0
fi
print_plan
if [[ $MODE == check ]]; then say "preflight OK; nothing changed"; exit 0; fi

ask_pass DATA_PW data
ask_pass SEC_PW secrets
[[ $DATA_PW != "$SEC_PW" ]] || die "the two passphrases must differ"
setup_stage

verify_archive() { # verify_archive PASSVAR FILE  (decrypt and read the whole archive)
  say "verifying $(basename "$2")"
  decrypt "$1" "$2" | zstd -dcq | tar -tf - >/dev/null
}

finish_archive() { # finish_archive FILE  (rename .partial, write checksum)
  mv "$1.partial" "$1"
  (cd "$OUT" && sha256sum "$(basename "$1")" > "$(basename "$1").sha256")
}

# ---------- data archive ----------
mkdir "$STAGE"/{tofu,pg,volumes,srv}

say "OpenTofu state"
tar -C "$BOOT" -cf "$STAGE/tofu/tofu-state.tar" "${STATE_FILES[@]}"

dump_pg() { # dump_pg NAME CMD...  (CMD writes a pg_dumpall to stdout)
  local name=$1 tail; shift
  "$@" | zstd -q -3 -o "$STAGE/pg/$name.sql.zst"
  tail=$(zstd -dcq "$STAGE/pg/$name.sql.zst" | tail -n 5)
  [[ $tail == *"cluster dump complete"* ]] || die "dump of $name looks incomplete"
}
for c in "${PLUM_PG[@]}"; do
  say "pg_dumpall $c"
  dump_pg "$c" docker exec "$c" sh -c 'pg_dumpall -U "$POSTGRES_USER"'
done
# The AWX db user is not a superuser, so pg_dumpall (roles) is not possible: dump the awx database only.
say "pg_dump AWX database"
dump_awx "$STAGE/pg/awx.dump"

vol_tar() { # vol_tar VOLUME  (read-only mount, tar written to the staging dir)
  docker run --rm --pull never --network none -v "$1":/v:ro -v "$STAGE/volumes":/out \
    --entrypoint tar "$IMG" -C /v -cf "/out/$1.tar" .
}
for v in "${HOT_VOLUMES[@]}"; do say "volume $v (hot copy)"; vol_tar "$v"; done

cat >&2 <<EOF

WARNING: portainer and spire-server will be stopped, one at a time, for a consistent copy of
their volumes (a few seconds each).
  - portainer: UI and API unavailable; running stacks keep running.
  - spire-server: no new SVIDs; vibe-token refresh and the WIF adapter may fail until it is back.
Both are restarted automatically, also if this script fails or is interrupted.
EOF
read -rp "Press Enter to stop them, Ctrl-C to abort: " </dev/tty

for pair in "${STOP_VOLUMES[@]}"; do
  c=${pair%%:*}; v=${pair#*:}
  say "stopping $c, copying $v"
  docker stop -t 30 "$c" >/dev/null
  STOPPED+=("$c")
  vol_tar "$v"
  docker start "$c" >/dev/null
  unset 'STOPPED[-1]'
  sleep 3
  [[ $(docker inspect -f '{{.State.Running}}' "$c") == true ]] || die "$c did not come back up; check docker logs $c"
  say "$c is running again"
done

say "/srv/plum*"
mapfile -d '' -t PLUM_DIRS < <(sudo find /srv -maxdepth 1 -type d -name 'plum*' -printf '%f\0' | sort -z)
sudo tar --numeric-owner -C /srv -cf "$STAGE/srv/srv-plum.tar" "${PLUM_DIRS[@]}"

sudo chown -R "$(id -u):$(id -g)" "$STAGE"
cat > "$STAGE/META.txt" <<EOF
created_utc=$TS
host=$(hostname)
script_commit=$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null || echo unknown)
tofu_state_root=$BOOT
pg_dumps=${PLUM_PG[*]} awx(pg_dump -Fc)
volumes_hot=${HOT_VOLUMES[*]}
volumes_stopped=${STOP_VOLUMES[*]#*:}
srv_dirs=${PLUM_DIRS[*]}
EOF
(cd "$STAGE" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256)

DATA_OUT=$OUT/lumi-data-$TS.tar.zst.gpg
say "encrypting data archive"
tar -C "$STAGE" --numeric-owner -cf - . | zstd -q -T0 -10 | encrypt DATA_PW "$DATA_OUT.partial"
verify_archive DATA_PW "$DATA_OUT.partial"
finish_archive "$DATA_OUT"

# Drop the plaintext staging data (tfstate holds generated secrets) before the next phase.
sudo find "$STAGE" -mindepth 1 -delete

# ---------- secrets archive ----------
say "secrets archive"
mkdir "$STAGE/secrets"
(cd / && sudo find "${SECRET_PATHS[@]}" -type f -print0 | sort -z | sudo xargs -0 sha256sum) > "$STAGE/secrets/SECRETS.sha256"
SEC_OUT=$OUT/lumi-secrets-$TS.tar.zst.gpg
sudo tar --numeric-owner -C "$STAGE/secrets" -cf - SECRETS.sha256 -C / "${SECRET_PATHS[@]}" \
  | zstd -q -T0 -10 | encrypt SEC_PW "$SEC_OUT.partial"
verify_archive SEC_PW "$SEC_OUT.partial"
finish_archive "$SEC_OUT"

say "done"
ls -l "$DATA_OUT" "$SEC_OUT" >&2
cat >&2 <<EOF

Copy off-host from your laptop (adjust the host name), then verify:
  mkdir -p ~/lumi-backup && scp "$(hostname):$OUT/*-$TS.tar.zst.gpg*" ~/lumi-backup/
  cd ~/lumi-backup && sha256sum -c lumi-data-$TS.tar.zst.gpg.sha256 lumi-secrets-$TS.tar.zst.gpg.sha256

The passphrases are stored nowhere; lose them and the archives are unrecoverable.
Until copied off-host these archives share this machine's fate. Delete them from $OUT after the copy.
EOF
