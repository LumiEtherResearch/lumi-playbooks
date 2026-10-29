#!/bin/bash
# Test for restore.sh apply plum-pg. On a new server the Plum apps create their schema when portainer-stacks starts them, so the target
# databases are NEVER empty when data-restore runs, and the old code stopped with "target already has 41 user tables ... FORCE=1".
# (FORCE=1 only skipped that check and piped the pg_dumpall file over the existing tables: CREATE TABLE fails, COPY into a table that
# already holds the seeded rows fails as a whole, and psql still exits 0 -- a half-loaded database.) Now, with REPLACE=1, for each of
# the four instances: the app container is stopped, the databases (not postgres/templates) are dropped, the dump is loaded, any
# unexpected SQL error is fatal, and the app is started again only if it was running. Without REPLACE=1 nothing is touched.
# The functions come from restore.sh itself (sed); docker is a stub that models running state, databases and table counts, so this
# checks the FLOW and the guards, not the SQL (that is proven by the rehearsal in the test VM). Needs zstd; skips without it.
# usage: test-plum-pg-restore.sh [REPO_ROOT]   (default: the checkout this test lives in)
set -u
R=${1:-$(cd "$(dirname "$0")/.." && pwd)}
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
chk() { if eval "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }
command -v zstd >/dev/null || { echo "SKIP: needs zstd"; exit 0; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
S=$W/state; mkdir -p "$S" "$W/bin" "$W/dir/pg"
PAIRS="plum-postgres:plum plum-abhi-postgres:plum-abhi plum-anish-postgres:plum-anish plum-arun-postgres:plum-arun"
for p in $PAIRS; do echo "-- dump of ${p%%:*}" | zstd -q -o "$W/dir/pg/${p%%:*}.sql.zst"; done

cat > "$W/bin/docker" <<'STUB'
#!/bin/bash
# stub docker: containers run/stop/start; each postgres container has databases and a table count (files in $STUB_STATE)
S=$STUB_STATE; cmd=$1; shift
case $cmd in
  inspect) n=${!#}; [[ -f $S/run.$n ]] || exit 1; cat "$S/run.$n" ;;
  stop)    [[ ${1:-} == -t ]] && shift 2; for n; do echo false > "$S/run.$n"; echo "STOP $n" >> "$S/events"; done ;;
  start)   for n; do echo true > "$S/run.$n"; echo "START $n" >> "$S/events"; done ;;
  exec)
    [[ $1 == -i ]] && shift; c=$1; shift; script=$3; shift 4     # c  sh -c SCRIPT _ ARGS...
    case $script in
      *"-d postgres -Atc"*)
        case $1 in
          *"datistemplate"*) if [[ $1 == *"datname <>"* ]]; then grep -vx postgres "$S/dbs.$c"; else cat "$S/dbs.$c"; fi ;;
          *"DROP DATABASE"*) db=${1#DROP DATABASE \"}; db=${db%%\"*}; echo "DROP $c $db" >> "$S/events"
                             grep -vx -- "$db" "$S/dbs.$c" > "$S/dbs.$c.new"; mv "$S/dbs.$c.new" "$S/dbs.$c"; echo 0 > "$S/tables.$c" ;;
        esac ;;
      *"-Atc \"\$2\""*) [[ $1 == plumcode ]] && cat "$S/tables.$c" || echo 0 ;;      # tables of one database
      *"-d postgres -q"*)
        bytes=$(wc -c); echo "LOAD $c $([[ $bytes -gt 0 ]] && echo data || echo empty)" >> "$S/events"
        grep -qx plumcode "$S/dbs.$c" || echo plumcode >> "$S/dbs.$c"; echo 41 > "$S/tables.$c"
        [[ -f $S/loaderr.$c ]] && cat "$S/loaderr.$c" >&2; exit 0 ;;
    esac ;;
esac
STUB
chmod +x "$W/bin/docker"
{ echo 'die() { echo "restore.sh: $*" >&2; exit 1; }; say() { echo "== $*" >&2; }; confirm() { echo "CONFIRM $1" >> "$STUB_STATE/events"; }'
  for f in pg_tables_in drop_databases load_pg apply_plum_pg; do sed -n "/^$f()/,/^}/p" "$R/scripts/restore.sh"; done
} > "$W/harness.sh"

reset() { # reset TABLES APPS_RUNNING(yes|no)  : all four instances in the same state
  rm -f "$S"/*; for p in $PAIRS; do c=${p%%:*}; a=${p##*:}
    echo true > "$S/run.$c"; echo $([[ $2 == yes ]] && echo true || echo false) > "$S/run.$a"
    printf 'postgres\n%s\n' $([[ $1 -gt 0 ]] && echo plumcode) | sed '/^$/d' > "$S/dbs.$c"; echo "$1" > "$S/tables.$c"; done
}
apply() { # apply NAME [VAR=VALUE...]  -> output in $W/out.NAME
  local n=$1; shift
  ( . "$W/harness.sh"; set -euo pipefail; DIR=$W/dir; export PATH=$W/bin:$PATH STUB_STATE=$S; env "$@" true; for kv in "$@"; do export "$kv"; done; apply_plum_pg ) >"$W/out.$n" 2>&1
}
ev() { cat "$S/events" 2>/dev/null; }
declare -F >/dev/null; grep -q '^drop_databases()' "$R/scripts/restore.sh" && HAVE_DROP=1 || HAVE_DROP=0

echo "== 1. the apps already created their schema (41 tables) and are running"
reset 41 yes; apply plain; rc=$?
chk "without REPLACE=1 it refuses"                                       '[[ $rc -ne 0 ]]'
chk "... and the message names REPLACE=1"                                'grep -q "REPLACE=1" "$W/out.plain"'
chk "... before stopping, dropping or loading anything"                  '! ev | grep -qE "^(STOP|DROP|LOAD)"'
reset 41 yes; apply forceonly FORCE=1; rc=$?
chk "FORCE=1 alone does not load over the existing tables any more"      '[[ $rc -ne 0 ]] && ! ev | grep -q "^LOAD"'

reset 41 yes; apply replace REPLACE=1; rc=$?
chk "with REPLACE=1 it succeeds"                                         '[[ $rc -eq 0 ]]'
chk "all four dumps were loaded"                                         '[[ $(ev | grep -c "^LOAD .* data") -eq 4 ]]'
chk "every app was stopped before its databases were dropped and loaded" '(for p in $PAIRS; do c=${p%%:*}; a=${p##*:}; e=$(ev | grep -E " ($c|$a)( |$)" | tr "\n" ";"); [[ $e == "STOP $a;DROP $c plumcode;LOAD $c data;START $a;" ]] || exit 1; done)'
chk "the postgres database and the templates were not dropped"           '! ev | grep -qE "^DROP .* (postgres|template[01])$"'
chk "all four apps are running again"                                    '(for p in $PAIRS; do [[ $(cat $S/run.${p##*:}) == true ]] || exit 1; done)'
chk "all four databases hold the restored tables"                        '(for p in $PAIRS; do [[ $(cat $S/tables.${p%%:*}) -gt 0 ]] || exit 1; done)'

echo "== 2. it can be repeated"
apply again REPLACE=1; rc=$?
chk "a second run (tables exist again) works the same"                   '[[ $rc -eq 0 && $(ev | grep -c "^LOAD") -eq 8 ]]'

echo "== 3. app containers that were not running stay stopped"
reset 41 no; apply stopped REPLACE=1; rc=$?
chk "succeeds"                                                           '[[ $rc -eq 0 ]]'
chk "no app was stopped or started by the script"                        '! ev | grep -qE "^(STOP|START)"'

echo "== 4. a really fresh cluster (no tables yet)"
reset 0 yes; apply fresh; rc=$?
chk "loads without REPLACE=1, nothing is dropped"                        '[[ $rc -eq 0 ]] && ! ev | grep -q "^DROP" && [[ $(ev | grep -c "^LOAD") -eq 4 ]]'

echo "== 5. SQL errors in the load"
reset 41 yes; for p in $PAIRS; do printf 'ERROR:  role "plumcode" already exists\nERROR:  database "postgres" already exists\n' > "$S/loaderr.${p%%:*}"; done
apply expected REPLACE=1; rc=$?
chk "the expected 'already exists' errors are tolerated"                 '[[ $rc -eq 0 ]]'
reset 41 yes; printf 'ERROR:  relation "users" already exists\n' > "$S/loaderr.plum-abhi-postgres"
apply unexpected REPLACE=1; rc=$?
chk "any other SQL error is fatal"                                       '[[ $rc -ne 0 ]] && grep -q "relation \"users\"" "$W/out.unexpected"'
chk "... the app of that instance is left stopped, not started on a bad load"  '[[ $(cat $S/run.plum-abhi) == false ]]'
chk "... and the instances after it were not touched"                    '! ev | grep -qE "^(STOP|DROP|LOAD) plum-(anish|arun)"'

echo "== 6. the guard looks at all four instances before changing any"
reset 0 yes; echo 7 > "$S/tables.plum-arun-postgres"; echo plumcode >> "$S/dbs.plum-arun-postgres"
apply late; rc=$?
chk "refused although only the LAST instance has tables"                 '[[ $rc -ne 0 ]] && ! ev | grep -qE "^(STOP|DROP|LOAD)"'

echo; echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
