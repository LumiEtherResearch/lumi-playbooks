#!/bin/bash
# Capture and restore the UNCOMMITTED work in the developers' git checkouts. Shared by backup.sh and restore.sh. Source it;
# do not run it.
#
# Where the checkouts really are: developers work in their HOME (/home/<dev>/<repo>); lumiether-expose-repos.timer then
# bind-mounts those repos READ-ONLY into /srv/lumiether/workspaces/<dev>/. So capture from the canonical places (the homes and
# the shared checkouts directly under /srv/lumiether/workspaces), never through the mounts (they are read-only, and a manual
# fstab mount can even show a different directory than the developer's own).
#
#   A SOURCE is "DIR:DEPTH": every git repository found up to DEPTH levels below DIR (e.g. "/home/abhi:2" finds the top-level
#   repositories of that home). The same repository is only ever captured once (deduplicated by inode, first source wins).
#
#   wip_summary SOURCE...            read-only counts per repository (used by backup.sh --check)
#   wip_capture DEST SOURCE...       for every repository write, under DEST/<absolute path without the leading slash>/:
#                                      wip.patch        changes to tracked files against HEAD (staged and unstaged together)
#                                      untracked.tar    untracked files that are NOT ignored by .gitignore
#                                      unpushed.bundle  commits that are on no remote (only when there are any)
#                                    plus DEST/INDEX.tsv (one line per repository) and DEST/SKIPPED.txt (anything not saved).
#   wip_restore SRC ROOT             put it back onto existing checkouts: ROOT/<saved path> ("/" on the real server).
#
# Deliberately NOT captured: files ignored by .gitignore (build output, usually .env), git stashes (counted and listed in
# SKIPPED.txt), anything inside .git other than the unpushed commits.
# wip_restore never touches a checkout that already has local changes (unless FORCE=1), never overwrites a file, never rewrites
# history (commits are only fast-forwarded to the recorded commit; recovered branches go to refs/recovered/*). The staged /
# unstaged distinction is not kept: everything comes back as working-tree changes.
#
# Git runs with GIT_OPTIONAL_LOCKS=0, and every `git diff` runs on a temporary copy of the index (see _wip_diff), so that even
# as root this code never rewrites a developer's .git/index.
# WIP_SUDO is the command prefix used to read and write the repositories: unset = "sudo -n"; set to an empty string to run as
# yourself (tests). WIP_MAX_UNTRACKED_MB caps the untracked files saved per repository (default 100).

_wip_prefix() { if [[ -v WIP_SUDO ]]; then printf '%s' "$WIP_SUDO"; else printf 'sudo -n'; fi; }

_wip_git() { # _wip_git REPO git-args...
  local repo=$1 p; shift
  p=$(_wip_prefix)
  # shellcheck disable=SC2086  # $p is a command prefix, empty or "sudo -n"
  $p env GIT_OPTIONAL_LOCKS=0 git -c safe.directory='*' -C "$repo" "$@"
}

# `git diff` against the working tree refreshes the index and REWRITES it when its stat data is stale, even with
# GIT_OPTIONAL_LOCKS=0 (git 2.53; only `git status` and the plumbing commands honor it). Run as root that leaves a developer's
# .git/index owned by root and breaks their git. So diffs always run against a throwaway COPY of the index: the refresh lands
# in the copy, the real index is never opened for writing.
# The copy lives in a PRIVATE directory (mktemp -d): git, running as root, replaces the copy with a new root-owned file, and
# a loose root-owned file in the sticky /tmp could not be removed by the caller ("Operation not permitted"; under `set -e` that
# aborted backup.sh half way). In a directory the caller owns it can. The cleanup can never change the result: `|| true`.
_wip_diff() { # _wip_diff REPO diff-args...
  local repo=$1 idx dir tmp rc p; shift
  idx=$(_wip_git "$repo" rev-parse --git-path index 2>/dev/null) || return 1
  [[ $idx == /* ]] || idx=$repo/$idx
  dir=$(mktemp -d) || return 1
  tmp=$dir/index
  if ! _wip_sudo cat "$idx" > "$tmp" 2>/dev/null || [[ ! -s $tmp ]]; then rm -rf "$dir" || true; return 1; fi
  p=$(_wip_prefix)
  # shellcheck disable=SC2086
  $p env GIT_OPTIONAL_LOCKS=0 GIT_INDEX_FILE="$tmp" git -c safe.directory='*' -C "$repo" diff "$@"
  rc=$?
  rm -rf "$dir" || true
  return $rc
}

_wip_sudo() { # _wip_sudo cmd...   (run a non-git command with the same privilege)
  local p; p=$(_wip_prefix)
  # shellcheck disable=SC2086
  $p "$@"
}

# NUL-separated repository directories for the given SOURCEs, each repository once.
_wip_repos() {
  local s dir depth g id
  local -A seen=()
  for s in "$@"; do
    dir=${s%:*}; depth=${s##*:}
    [[ $depth =~ ^[0-9]+$ && $dir != "$s" ]] || { echo "wip: bad source '$s' (want DIR:DEPTH)" >&2; return 1; }
    while IFS= read -r -d '' g; do
      id=$(_wip_sudo stat -c %d:%i "$g" 2>/dev/null) || continue
      [[ -n ${seen[$id]:-} ]] && continue
      seen[$id]=1
      printf '%s\0' "$(dirname "$g")"
    done < <(_wip_sudo find "$dir" -maxdepth "$depth" -name .git -prune -print0 2>/dev/null | sort -z)
  done
}

_wip_count_lines() { wc -l | tr -d '[:space:]'; }

# One repository's facts, tab-separated: head branch dirty untracked unpushed stash remote
_wip_facts() {
  local repo=$1 head branch remote dirty untracked unpushed stash
  head=$(_wip_git "$repo" rev-parse -q --verify HEAD 2>/dev/null) || head=none
  branch=$(_wip_git "$repo" symbolic-ref -q --short HEAD 2>/dev/null) || branch=detached
  remote=$(_wip_git "$repo" config --get remote.origin.url 2>/dev/null | sed -E 's#(https?://)[^@/]*@#\1#') || remote=none
  dirty=$(_wip_diff "$repo" HEAD --name-only 2>/dev/null | _wip_count_lines) || dirty=0
  untracked=$(_wip_git "$repo" ls-files --others --exclude-standard 2>/dev/null | _wip_count_lines) || untracked=0
  unpushed=$(_wip_git "$repo" log --branches --not --remotes --oneline 2>/dev/null | _wip_count_lines) || unpushed=0
  stash=$(_wip_git "$repo" stash list 2>/dev/null | _wip_count_lines) || stash=0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$head" "$branch" "${dirty:-0}" "${untracked:-0}" "${unpushed:-0}" "${stash:-0}" "${remote:-none}"
}

wip_summary() { # wip_summary SOURCE...
  local repo facts head branch dirty untracked unpushed stash remote n=0 files=0 unt=0 unp=0
  printf '  %-44s %-8s %-10s %-9s %s\n' repository changed untracked unpushed branch >&2
  while IFS= read -r -d '' repo; do
    facts=$(_wip_facts "$repo")
    IFS=$'\t' read -r head branch dirty untracked unpushed stash remote <<<"$facts"
    if (( dirty + untracked + unpushed > 0 )); then
      printf '  %-44s %-8s %-10s %-9s %s\n' "$repo" "$dirty" "$untracked" "$unpushed" "$branch" >&2
      n=$((n + 1)); files=$((files + dirty)); unt=$((unt + untracked)); unp=$((unp + unpushed))
    fi
  done < <(_wip_repos "$@")
  echo "  -> $n repositories with uncommitted work: $files changed tracked files, $unt untracked files, $unp unpushed commits" >&2
}

wip_capture() { # wip_capture DEST SOURCE...
  local dest=$1; shift
  local cap=${WIP_MAX_UNTRACKED_MB:-100}
  local repo rel out facts head branch dirty untracked unpushed stash remote status list listdir size captured=0 clean=0 skipped=0
  mkdir -p "$dest"
  : > "$dest/INDEX.tsv"
  : > "$dest/SKIPPED.txt"
  while IFS= read -r -d '' repo; do
    rel=${repo#/}; out=$dest/$rel
    facts=$(_wip_facts "$repo")
    IFS=$'\t' read -r head branch dirty untracked unpushed stash remote <<<"$facts"
    status=clean
    if (( dirty + untracked + unpushed > 0 )); then
      mkdir -p "$out"; status=captured
      if (( dirty > 0 )) && [[ $head != none ]]; then
        _wip_diff "$repo" HEAD --binary > "$out/wip.patch"
      fi
      if (( untracked > 0 )); then
        listdir=$(mktemp -d); list=$listdir/untracked.list
        _wip_git "$repo" ls-files --others --exclude-standard -z > "$list"
        _wip_sudo tar -C "$repo" --null -T "$list" -cf - > "$out/untracked.tar" 2>/dev/null || true
        rm -rf "$listdir" || true
        size=$(stat -c %s "$out/untracked.tar")
        if (( size > cap * 1024 * 1024 )); then
          rm -f "$out/untracked.tar"
          echo "$repo: $untracked untracked files ($((size / 1024 / 1024)) MB) NOT saved: over the ${cap} MB cap (WIP_MAX_UNTRACKED_MB)" >> "$dest/SKIPPED.txt"
          status=captured-partial; skipped=$((skipped + 1))
        fi
      fi
      if (( unpushed > 0 )); then
        _wip_git "$repo" bundle create - --branches --not --remotes > "$out/unpushed.bundle" 2>/dev/null || {
          rm -f "$out/unpushed.bundle"
          echo "$repo: $unpushed unpushed commits could NOT be bundled" >> "$dest/SKIPPED.txt"; skipped=$((skipped + 1))
        }
      fi
      captured=$((captured + 1))
    else
      clean=$((clean + 1))
    fi
    if (( stash > 0 )); then
      echo "$repo: $stash git stash entries are NOT saved (stashes are not captured)" >> "$dest/SKIPPED.txt"; skipped=$((skipped + 1))
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$head" "$branch" "$dirty" "$untracked" "$unpushed" "$stash" "$status" "$remote" >> "$dest/INDEX.tsv"
  done < <(_wip_repos "$@")
  echo "workspace changes: $captured repositories captured, $clean clean, $skipped items not saved (see SKIPPED.txt)" >&2
  if [[ -s $dest/SKIPPED.txt ]]; then sed 's/^/  NOT SAVED: /' "$dest/SKIPPED.txt" >&2; fi
}

wip_restore() { # wip_restore SRC ROOT
  local src=$1 root=${2%/}
  local rel head branch dirty untracked unpushed stash status remote repo in owner cur now_dirty applied=0 skipped=0
  [[ -f $src/INDEX.tsv ]] || { echo "wip_restore: no INDEX.tsv in $src" >&2; return 1; }
  while IFS=$'\t' read -r rel head branch dirty untracked unpushed stash status remote; do
    [[ $status == captured* ]] || continue
    repo=$root/$rel; in=$src/$rel
    if ! _wip_sudo test -e "$repo/.git"; then
      echo "  SKIP /$rel: not cloned yet (run configure_workspace_clone.yml first)"; skipped=$((skipped + 1)); continue
    fi
    now_dirty=$(_wip_git "$repo" status --porcelain=v1 | _wip_count_lines)
    if (( now_dirty > 0 )) && [[ ${FORCE:-0} != 1 ]]; then
      echo "  SKIP /$rel: the checkout already has $now_dirty local change(s) (FORCE=1 to apply anyway)"; skipped=$((skipped + 1)); continue
    fi
    # 1. commits that were on no remote: keep them as refs/recovered/*, then fast-forward if the checkout is simply behind
    if [[ -f $in/unpushed.bundle ]]; then
      if _wip_git "$repo" fetch -q "$in/unpushed.bundle" 'refs/heads/*:refs/recovered/*'; then
        echo "  /$rel: unpushed commits recovered as refs/recovered/* (inspect with: git log refs/recovered/$branch)"
      else
        echo "  PROBLEM /$rel: could not read the unpushed-commits bundle $in/unpushed.bundle" >&2
      fi
      cur=$(_wip_git "$repo" symbolic-ref -q --short HEAD 2>/dev/null || echo detached)
      if [[ $head != none && $cur == "$branch" ]] \
         && [[ $(_wip_git "$repo" rev-parse HEAD) != "$head" ]] \
         && _wip_git "$repo" cat-file -e "$head^{commit}" 2>/dev/null \
         && _wip_git "$repo" merge-base --is-ancestor HEAD "$head" 2>/dev/null; then
        _wip_git "$repo" merge -q --ff-only "$head" && echo "  /$rel: branch $branch fast-forwarded to the recorded commit"
      fi
    fi
    # 2. changes to tracked files
    if [[ -f $in/wip.patch ]]; then
      if _wip_git "$repo" apply --check "$in/wip.patch" 2>/dev/null; then
        _wip_git "$repo" apply --binary "$in/wip.patch" && echo "  /$rel: tracked changes applied"
      else
        echo "  CONFLICT /$rel: the saved changes do not apply cleanly (checkout is at $(_wip_git "$repo" rev-parse --short HEAD), they were made on ${head:0:7}). Patch kept at $in/wip.patch" >&2
        skipped=$((skipped + 1))
      fi
    fi
    # 3. untracked files: existing files are never overwritten
    if [[ -f $in/untracked.tar ]]; then
      _wip_sudo tar -C "$repo" --skip-old-files -xpf "$in/untracked.tar" && echo "  /$rel: $untracked untracked file(s) restored (existing files kept)"
    fi
    # files written as root must belong to the checkout's owner again
    if [[ $(_wip_prefix) == *sudo* ]]; then
      owner=$(_wip_sudo stat -c %U "$repo"); _wip_sudo chown -R "$owner:$(id -gn "$owner")" "$repo"
    fi
    applied=$((applied + 1))
  done < "$src/INDEX.tsv"
  echo "workspace changes: $applied repositories restored, $skipped skipped or needing attention"
}
