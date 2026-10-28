#!/bin/bash
# Helpers to read the listing of a backup archive (names only, never contents). Shared by backup.sh and restore.sh. Source it;
# do not run it.
#
#   archive_missing PATH...   reads a `tar -t` listing on stdin; prints every PATH that has no entry equal to it or below it
#                             (PATH/...), one per line, and returns 1 if any is missing. PATHs are tar member names as stored:
#                             relative, no leading slash. "a/b" does NOT match "a/bc/x".
#   archive_show_listing      reads a `tar -t` listing on stdin and prints the entry count, then every name (no truncation:
#                             a listing cut off after N lines hides the entries that come last).

archive_missing() {
  REQ=$(printf '%s\n' "$@") awk '
    BEGIN { n = split(ENVIRON["REQ"], r, "\n") }
    { for (i = 1; i <= n; i++) if (r[i] != "" && !(i in seen) && ($0 == r[i] || index($0, r[i] "/") == 1)) seen[i] = 1 }
    END { rc = 0; for (i = 1; i <= n; i++) if (r[i] != "" && !(i in seen)) { print r[i]; rc = 1 } exit rc }'
}

archive_show_listing() {
  local names
  names=$(cat)
  printf '%s entries:\n' "$(printf '%s' "$names" | grep -c '')"
  [[ -z $names ]] || printf '%s\n' "$names"
}
