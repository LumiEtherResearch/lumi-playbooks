#!/bin/bash
# Restore from archives made by scripts/backup.sh.
#
# Usage:
#   restore.sh verify  ARCHIVE.gpg                 decrypt and read the whole archive; writes nothing
#   restore.sh extract ARCHIVE.gpg NEWDIR          decrypt into a new directory and check its checksums
#   restore.sh apply   DIR COMPONENT...            put extracted content back on this host
#
# Components for a data archive:  tofu-state plum-pg awx-pg portainer spire cbm srv-plum
# Component for a secrets archive: secrets
#
# Nothing is overwritten without typing the component name. Existing files are renamed
# *.pre-restore-<UTC> where possible. Extracted directories hold plaintext secrets: delete them
# when done. The passphrase is read from the terminal and never stored.
set -euo pipefail
umask 077

BOOT=${INFRA_BOOTSTRAP:-$HOME/infra-bootstrap}
TS=$(date -u +%Y%m%dT%H%M%SZ)
IMG=postgres:17-alpine
AWX_NS=awx
AWX_POD=awx-demo-postgres-15-0

die() { echo "restore.sh: $*" >&2; exit 1; }
say() { echo "== $*" >&2; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[[ $EUID -ne 0 ]] || die "run as the normal user (uses sudo where needed), not root"
sudo -n true 2>/dev/null || die "need passwordless sudo"

ask_pass() { # ask_pass VAR
  local a
  read -rsp "Archive passphrase: " a </dev/tty; echo >&2
  printf -v "$1" '%s' "$a"
}

decrypt() { # decrypt PASSVAR FILE
  local -n pw=$1
  gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --decrypt "$2" 3< <(printf '%s' "$pw")
}

confirm() { # confirm WORD DESCRIPTION
  local ans
  printf '\n%s\n' "$2" >&2
  read -rp "Type '$1' to proceed: " ans </dev/tty
  [[ $ans == "$1" ]] || die "aborted at $1"
}

cmd_verify() {
  local f=$1 PW
  [[ -f $f ]] || die "no such file: $f"
  ask_pass PW
  say "reading archive"
  decrypt PW "$f" | zstd -dcq | tar -tf - >/dev/null
  say "archive decrypts and reads cleanly"
  if [[ $f == *lumi-data-* ]]; then
    decrypt PW "$f" | zstd -dcq | tar -xOf - ./META.txt
  else
    decrypt PW "$f" | zstd -dcq | tar -tf - | head -n 20
  fi
}

cmd_extract() {
  local f=$1 dir=$2 PW sums
  [[ -f $f ]] || die "no such file: $f"
  if [[ -e $dir ]]; then [[ -d $dir && -z $(ls -A "$dir") ]] || die "$dir exists and is not empty"; fi
  install -d -m 700 "$dir"
  ask_pass PW
  say "extracting into $dir (as root, to keep ownership)"
  decrypt PW "$f" | zstd -dcq | sudo tar --numeric-owner -C "$dir" -xpf -
  if [[ -f $dir/MANIFEST.sha256 ]]; then sums=MANIFEST.sha256
  elif sudo test -f "$dir/SECRETS.sha256"; then sums=SECRETS.sha256
  else die "no checksum manifest in the archive"; fi
  (cd "$dir" && sudo sha256sum -c --quiet "$sums") || die "checksum mismatch"
  say "checksums OK. Next: $0 apply $dir <component>..."
}

# ---------- apply ----------
DIR=
pg_tables_in() { # pg_tables_in EXEC...  -> number of user tables across all databases
  local dbs db n=0 c
  local Q1='select datname from pg_database where not datistemplate'
  local Q2='select count(*) from pg_tables where schemaname not in ($$pg_catalog$$,$$information_schema$$)'
  dbs=$("$@" sh -c 'psql -U "$POSTGRES_USER" -d postgres -Atc "$1"' _ "$Q1" </dev/null)
  for db in $dbs; do
    c=$("$@" sh -c 'psql -U "$POSTGRES_USER" -d "$1" -Atc "$2"' _ "$db" "$Q2" </dev/null)
    n=$((n + c))
  done
  echo "$n"
}

load_pg() { # load_pg DUMP EXEC...  (EXEC must include -i)
  local dump=$1 n; shift
  [[ -f $dump ]] || die "missing $dump"
  n=$(pg_tables_in "$@")
  if [[ $n -gt 0 && ${FORCE:-0} != 1 ]]; then
    die "target already has $n user tables; drop its databases first or rerun with FORCE=1"
  fi
  # Errors like "role already exists" are expected on a freshly initialised cluster.
  zstd -dcq "$dump" | "$@" sh -c 'psql -U "$POSTGRES_USER" -d postgres -q'
}

apply_tofu_state() {
  local t=$DIR/tofu/tofu-state.tar f
  [[ -f $t ]] || die "missing $t"
  confirm tofu-state "Extract OpenTofu state into $BOOT. Existing state files are renamed *.pre-restore-$TS."
  while IFS= read -r f; do
    if [[ -e $BOOT/$f ]]; then mv "$BOOT/$f" "$BOOT/$f.pre-restore-$TS"; fi
  done < <(tar -tf "$t")
  tar -C "$BOOT" -xpf "$t"
}

apply_plum_pg() {
  local f c
  confirm plum-pg "Load the four plum pg_dumpall files into the running plum*-postgres containers (they must be freshly initialised)."
  for f in "$DIR"/pg/plum*-postgres.sql.zst; do
    c=$(basename "$f" .sql.zst)
    [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]] || die "container $c is not running"
    say "loading $c"
    load_pg "$f" docker exec -i "$c"
  done
}

apply_awx_pg() {
  confirm awx-pg "Load the AWX pg_dumpall into $AWX_NS/$AWX_POD. Scale AWX web/task to 0 first (sudo k3s kubectl -n $AWX_NS scale deploy awx-demo-web awx-demo-task --replicas=0) and back to 1 afterwards."
  load_pg "$DIR/pg/awx-postgres.sql.zst" sudo k3s kubectl -n "$AWX_NS" exec -i "$AWX_POD" -c postgres --
}

restore_volume() { # restore_volume VOLUME CONTAINER...  (containers using it; stopped during the restore)
  local v=$1 c; shift
  local stopped=()
  [[ -f $DIR/volumes/$v.tar ]] || die "missing $DIR/volumes/$v.tar"
  docker volume inspect "$v" >/dev/null 2>&1 || docker volume create "$v" >/dev/null
  confirm "$v" "Wipe Docker volume $v and replace it with the backup. Stops while restoring: $*"
  for c in "$@"; do
    if [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]]; then
      docker stop -t 30 "$c" >/dev/null; stopped+=("$c")
    fi
  done
  docker run --rm --pull never --network none -v "$v":/v -v "$DIR/volumes":/in:ro \
    --entrypoint sh "$IMG" -c 'find /v -mindepth 1 -delete && tar -C /v -xpf "/in/$1.tar"' _ "$v"
  for c in "${stopped[@]}"; do docker start "$c" >/dev/null; done
}

apply_srv_plum() {
  local t=$DIR/srv/srv-plum.tar d running
  [[ -f $t ]] || die "missing $t"
  running=$(docker ps --format '{{.Names}}' | grep -E '^plum(-|$)' || true)
  [[ -z $running ]] || die "stop the plum stacks first; still running: $(echo "$running" | tr '\n' ' ')"
  confirm srv-plum "Restore /srv/plum* from the backup. Existing directories are renamed *.pre-restore-$TS."
  while IFS= read -r d; do
    if sudo test -e "/srv/$d"; then sudo mv "/srv/$d" "/srv/$d.pre-restore-$TS"; fi
  done < <(tar -tf "$t" | cut -d/ -f1 | sort -u)
  sudo tar --numeric-owner -C /srv -xpf "$t"
}

apply_secrets() {
  local p
  sudo test -f "$DIR/SECRETS.sha256" || die "$DIR is not an extracted secrets archive"
  confirm secrets "Restore ~/.ssh, ~/.cloudflared and /etc/lumiether from the backup. Existing ones are renamed *.pre-restore-$TS."
  while IFS= read -r p; do
    if sudo test -e "/${p#"$DIR"/}"; then sudo mv "/${p#"$DIR"/}" "/${p#"$DIR"/}.pre-restore-$TS"; fi
    sudo cp -a "$p" "/${p#"$DIR"/}"
  done < <(sudo find "$DIR/home" -mindepth 2 -maxdepth 2 \( -name .ssh -o -name .cloudflared \) -print; \
           sudo find "$DIR/etc" -mindepth 1 -maxdepth 1 -name lumiether -print)
}

cmd_apply() {
  DIR=$(realpath "$1"); shift
  local c
  [[ -d $DIR ]] || die "no such directory: $DIR"
  (( $# > 0 )) || usage
  for c in "$@"; do
    case $c in
      tofu-state) apply_tofu_state ;;
      plum-pg)    apply_plum_pg ;;
      awx-pg)     apply_awx_pg ;;
      portainer)  restore_volume portainer_data portainer ;;
      spire)      restore_volume spire-server_spire_server_data spire-server ;;
      cbm)        for v in vibe-cbm_cbm-data vibe-cbm_vibe-config vibe-cbm_workspaces; do restore_volume "$v" vibe-cbm; done ;;
      srv-plum)   apply_srv_plum ;;
      secrets)    apply_secrets ;;
      *) die "unknown component: $c" ;;
    esac
    say "$c restored"
  done
}

case "${1:-}" in
  verify)  [[ $# -eq 2 ]] || usage; cmd_verify "$2" ;;
  extract) [[ $# -eq 3 ]] || usage; cmd_extract "$2" "$3" ;;
  apply)   [[ $# -ge 3 ]] || usage; shift; cmd_apply "$@" ;;
  *) usage ;;
esac
