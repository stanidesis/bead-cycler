#!/usr/bin/env bash
# Unit tests for write_beads_redirect in scripts/bead-cycle.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/bead-cycle"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok: %s\n' "$*"
}

[[ -f "$SCRIPT" ]] || fail "missing $SCRIPT"
bash -n "$SCRIPT" || fail "bash -n scripts/bead-cycle"

# Extract feat_ref_matches_id, worktree_matches_id, and the redirect
# helpers. worktree_matches_id is between feat_ref_matches_id and
# matching_feat_branches; turn it on by name so a later reorder cannot
# drop it from this range.
funcs=$(awk '
  /^feat_ref_matches_id\(\)/ { p=1 }
  /^worktree_matches_id\(\)/ { p=1 }
  /^matching_feat_branches\(\)/ { p=0 }
  /^worktree_for_id\(\)/ { p=0 }
  /# --- beads redirect \(begin\)/ { p=1 }
  p
  /# --- beads redirect \(end\)/ { p=0 }
' "$SCRIPT")
[[ -n "$funcs" ]] || fail "could not extract beads redirect helpers"
eval "$funcs"
declare -F feat_ref_matches_id >/dev/null || fail "feat_ref_matches_id not extracted"
declare -F worktree_matches_id >/dev/null || fail "worktree_matches_id not extracted"
declare -F write_beads_redirect >/dev/null || fail "write_beads_redirect not extracted"
declare -F resolve_beads_redirect >/dev/null || fail "resolve_beads_redirect not extracted"
declare -F ensure_beads_redirect_ignored >/dev/null || fail "ensure_beads_redirect_ignored not extracted"
BRANCH_PREFIX=feat/

TMP=$(mktemp -d "${TMPDIR:-/tmp}/bead-redirect-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

HOST_ROOT="$TMP/host"
HOST_BEADS="$HOST_ROOT/.beads"
FORK="$TMP/fork"
mkdir -p "$HOST_BEADS" "$FORK/.beads"
printf 'dummy\n' >"$HOST_BEADS/metadata.json"
printf 'empty-db\n' >"$FORK/.beads/embeddeddolt-placeholder"
mkdir -p "$FORK/.beads/embeddeddolt"

host_abs=$(cd "$HOST_BEADS" && pwd -P)
host_root_abs=$(cd "$HOST_ROOT" && pwd -P)
REPO_ROOT=$HOST_ROOT

# Host checkout must not get a redirect file.
out=$(write_beads_redirect "$HOST_ROOT" "$HOST_BEADS" || true)
[[ -z "${out:-}" ]] || fail "host write printed: $out"
[[ ! -e "$HOST_BEADS/redirect" ]] || fail "host .beads/redirect was created"

# Logical symlink to the host checkout must not write host .beads/redirect.
HOST_LINK="$TMP/host-link"
ln -s "$HOST_ROOT" "$HOST_LINK"
out=$(write_beads_redirect "$HOST_LINK" "$HOST_BEADS" || true)
[[ -z "${out:-}" ]] || fail "host-link write printed: $out"
[[ ! -e "$HOST_BEADS/redirect" ]] || fail "host-link wrote host .beads/redirect"

# Fork gets an absolute redirect; local empty dolt dir is left alone.
out=$(write_beads_redirect "$FORK" "$HOST_BEADS")
[[ -n "$out" ]] || fail "fork write printed nothing"
fork_abs=$(cd "$FORK" && pwd -P)
[[ "$out" == "$fork_abs/.beads/redirect" ]] || fail "unexpected redirect path: $out"
got=$(tr -d '\r\n' < "$FORK/.beads/redirect")
[[ "$got" == "$host_abs" ]] || fail "redirect contents: $got (want $host_abs)"
[[ "$got" == /* ]] || fail "redirect is not absolute: $got"
[[ -d "$FORK/.beads/embeddeddolt" ]] || fail "deleted fork embeddeddolt"
[[ -f "$FORK/.beads/embeddeddolt-placeholder" ]] || fail "deleted fork placeholder"

# End-to-end: read the redirect with BEADS_DIR unset (bd FollowRedirect).
# Absolute target is required so resolution does not depend on relative-base
# bugs (GH#1098 / GH#1266 / GH#1749).
follow_redirect() {
  local dest=$1
  local beads="$dest/.beads"
  local target
  [[ -f "$beads/redirect" && ! -L "$beads/redirect" ]] || return 1
  target=$(tr -d '\r\n' < "$beads/redirect")
  [[ -n "$target" ]] || return 1
  if [[ "$target" != /* ]]; then
    target="$dest/$target"
  fi
  canonical_dir "$target"
}
printf 'host-store\n' >"$HOST_BEADS/e2e-sentinel"
unset BEADS_DIR
unset BEAD_CYCLE_BEADS_DIR
followed=$(follow_redirect "$FORK") || fail "follow_redirect failed with BEADS_DIR unset"
[[ "$followed" == "$host_abs" ]] || fail "follow_redirect: $followed (want $host_abs)"
got=$(tr -d '\r\n' < "$followed/e2e-sentinel")
[[ "$got" == "host-store" ]] || fail "did not follow redirect to host store: $got"
# CI must invoke this suite; do not leave it as a local-only script.
grep -q 'bead-cycle-redirect.test.sh' "$ROOT/.github/workflows/ci.yml" \
  || fail "CI workflow does not run bead-cycle-redirect.test.sh"

# Second write is a no-op (stdout empty, same contents).
out=$(write_beads_redirect "$FORK" "$HOST_BEADS")
[[ -z "${out:-}" ]] || fail "second write printed: $out"
got=$(tr -d '\r\n' < "$FORK/.beads/redirect")
[[ "$got" == "$host_abs" ]] || fail "second write changed contents"

# Wrong existing redirect is replaced.
printf '/wrong/path\n' >"$FORK/.beads/redirect"
out=$(write_beads_redirect "$FORK" "$HOST_BEADS")
[[ -n "$out" ]] || fail "replace write printed nothing"
got=$(tr -d '\r\n' < "$FORK/.beads/redirect")
[[ "$got" == "$host_abs" ]] || fail "replace contents: $got"

# Directory .beads/redirect is replaced with a file (mv must not nest).
rm -f "$FORK/.beads/redirect"
mkdir -p "$FORK/.beads/redirect/nested"
printf 'stale\n' >"$FORK/.beads/redirect/nested/x"
out=$(write_beads_redirect "$FORK" "$HOST_BEADS")
[[ -n "$out" ]] || fail "directory dest printed nothing"
[[ -f "$FORK/.beads/redirect" ]] || fail "directory dest left a non-file"
[[ ! -d "$FORK/.beads/redirect" ]] || fail "directory dest still a directory"
got=$(tr -d '\r\n' < "$FORK/.beads/redirect")
[[ "$got" == "$host_abs" ]] || fail "directory dest contents: $got"

# Symlink-to-directory .beads/redirect is unlinked, not followed.
REDIR_TARGET="$TMP/redirect-target"
mkdir -p "$REDIR_TARGET/keep"
rm -f "$FORK/.beads/redirect"
ln -s "$REDIR_TARGET" "$FORK/.beads/redirect"
out=$(write_beads_redirect "$FORK" "$HOST_BEADS")
[[ -n "$out" ]] || fail "symlink-dir dest printed nothing"
[[ -f "$FORK/.beads/redirect" ]] || fail "symlink-dir dest left a non-file"
[[ ! -L "$FORK/.beads/redirect" ]] || fail "symlink-dir dest left a symlink"
[[ -d "$REDIR_TARGET/keep" ]] || fail "followed symlink-dir and deleted target"
got=$(tr -d '\r\n' < "$FORK/.beads/redirect")
[[ "$got" == "$host_abs" ]] || fail "symlink-dir dest contents: $got"

# Missing dest is skipped.
out=$(write_beads_redirect "$TMP/no-such-checkout" "$HOST_BEADS" || true)
[[ -z "${out:-}" ]] || fail "missing dest printed: $out"

# Missing host beads fails.
if write_beads_redirect "$FORK" "$TMP/no-such-beads" >/dev/null; then
  fail "missing host beads should fail"
fi

# Symlinked dest .beads must not follow the link and write host redirect.
LINK_FORK="$TMP/link-fork"
mkdir -p "$LINK_FORK"
ln -s "$HOST_BEADS" "$LINK_FORK/.beads"
out=$(write_beads_redirect "$LINK_FORK" "$HOST_BEADS" || true)
[[ -z "${out:-}" ]] || fail "symlink .beads write printed: $out"
[[ ! -e "$HOST_BEADS/redirect" ]] || fail "symlink .beads wrote host redirect"
[[ -L "$LINK_FORK/.beads" ]] || fail "replaced symlink .beads"

# host_beads_dir preserves a valid caller BEADS_DIR.
CUSTOM="$TMP/custom-beads"
mkdir -p "$CUSTOM"
BEADS_DIR=$CUSTOM
got=$(host_beads_dir) || fail "host_beads_dir with BEADS_DIR failed"
custom_abs=$(cd "$CUSTOM" && pwd -P)
[[ "$got" == "$custom_abs" ]] || fail "host_beads_dir ignored BEADS_DIR: $got"
unset BEADS_DIR
got=$(host_beads_dir) || fail "host_beads_dir fallback failed"
[[ "$got" == "$host_abs" ]] || fail "host_beads_dir fallback: $got (want $host_abs)"

# apply_host_beads_dir: invalid inherited BEADS_DIR falls back and exports.
BEADS_DIR="$TMP/not-a-dir"
apply_host_beads_dir || fail "apply_host_beads_dir should fall back from invalid BEADS_DIR"
[[ "$BEADS_DIR" == "$host_abs" ]] || fail "apply did not export fallback: $BEADS_DIR"
[[ "${BEAD_CYCLE_BEADS_DIR:-}" == "$host_abs" ]] || fail "apply did not export BEAD_CYCLE_BEADS_DIR"

# Valid custom BEADS_DIR is exported as the canonical path.
BEADS_DIR=$CUSTOM
apply_host_beads_dir || fail "apply valid custom failed"
[[ "$BEADS_DIR" == "$custom_abs" ]] || fail "apply did not export custom: $BEADS_DIR"

# Invalid BEADS_DIR with no fallback fails closed (do not leave the stale value).
saved_repo=$REPO_ROOT
unset REPO_ROOT
BEADS_DIR="$TMP/still-missing"
if apply_host_beads_dir; then
  fail "invalid BEADS_DIR without fallback should fail"
fi
REPO_ROOT=$saved_repo
unset BEADS_DIR
unset BEAD_CYCLE_BEADS_DIR

# worktree_matches_id must treat bead ids as literals, not globs.
worktree_matches_id "/tmp/bead-topic?" "" "topic?" \
  || fail "literal ? id should match bead-topic?"
worktree_matches_id "/tmp/bead-topic?-2" "" "topic?" \
  || fail "literal ? id suffix should match"
if worktree_matches_id "/tmp/bead-topicX" "" "topic?"; then
  fail "glob ? overmatched bead-topicX"
fi
if worktree_matches_id "/tmp/bead-topicX-2" "" "topic?"; then
  fail "glob ? suffix overmatched bead-topicX-2"
fi
worktree_matches_id "/tmp/bead-gitdown-6qz" "" "gitdown-6qz" \
  || fail "normal id should match"
worktree_matches_id "/tmp/bead-gitdown-6qz-1" "" "gitdown-6qz" \
  || fail "normal id suffix should match"
if worktree_matches_id "/tmp/bead-gitdown-6qy" "" "gitdown-6qz"; then
  fail "different id matched"
fi
worktree_matches_id "/tmp/unrelated" "feat/topic?" "topic?" \
  || fail "branch match failed for literal ?"
if worktree_matches_id "/tmp/unrelated" "feat/topicX" "topic?"; then
  fail "glob branch overmatched feat/topicX"
fi

# Custom BEADS_DIR must not write $REPO_ROOT/.beads/redirect.
out=$(write_beads_redirect "$HOST_ROOT" "$CUSTOM" || true)
[[ -z "${out:-}" ]] || fail "custom beads wrote host redirect: $out"
[[ ! -e "$HOST_BEADS/redirect" ]] || fail "custom BEADS_DIR created host .beads/redirect"
# Fork still gets a redirect to the custom store.
out=$(write_beads_redirect "$FORK" "$CUSTOM")
[[ -n "$out" ]] || fail "fork write to custom beads printed nothing"
got=$(tr -d '\r\n' < "$FORK/.beads/redirect")
[[ "$got" == "$custom_abs" ]] || fail "custom beads redirect: $got"

# dirname fallback when REPO_ROOT is unset still skips the host checkout.
saved_repo=$REPO_ROOT
unset REPO_ROOT
rm -f "$HOST_BEADS/redirect"
out=$(write_beads_redirect "$HOST_ROOT" "$HOST_BEADS" || true)
[[ -z "${out:-}" ]] || fail "dirname fallback wrote host redirect: $out"
[[ ! -e "$HOST_BEADS/redirect" ]] || fail "dirname fallback created host .beads/redirect"
REPO_ROOT=$saved_repo

# Legacy beads/ (no dot) is used when .beads is absent.
LEGACY_ROOT="$TMP/legacy-host"
mkdir -p "$LEGACY_ROOT/beads"
saved_repo=$REPO_ROOT
REPO_ROOT=$LEGACY_ROOT
unset BEADS_DIR
got=$(host_beads_dir) || fail "host_beads_dir beads/ fallback failed"
legacy_abs=$(cd "$LEGACY_ROOT/beads" && pwd -P)
[[ "$got" == "$legacy_abs" ]] || fail "host_beads_dir beads/ fallback: $got"
# .beads wins when both layouts exist.
mkdir -p "$LEGACY_ROOT/.beads"
got=$(host_beads_dir) || fail "host_beads_dir .beads preferred failed"
legacy_dot_abs=$(cd "$LEGACY_ROOT/.beads" && pwd -P)
[[ "$got" == "$legacy_dot_abs" ]] || fail "host_beads_dir should prefer .beads: $got"
REPO_ROOT=$saved_repo

# Redirected host checkout: follow one hop to the actual store.
REAL_STORE="$TMP/real-store"
WRAP_HOST="$TMP/wrap-host"
WRAP_FORK="$TMP/wrap-fork"
mkdir -p "$REAL_STORE" "$WRAP_HOST/.beads" "$WRAP_FORK"
printf 'real-db\n' >"$REAL_STORE/sentinel"
real_abs=$(cd "$REAL_STORE" && pwd -P)
printf '%s\n' "$real_abs" >"$WRAP_HOST/.beads/redirect"
saved_repo=$REPO_ROOT
REPO_ROOT=$WRAP_HOST
unset BEADS_DIR
unset BEAD_CYCLE_BEADS_DIR
got=$(host_beads_dir) || fail "redirected host host_beads_dir failed"
[[ "$got" == "$real_abs" ]] || fail "host_beads_dir did not follow redirect: $got (want $real_abs)"
apply_host_beads_dir || fail "apply redirected host failed"
[[ "$BEADS_DIR" == "$real_abs" ]] || fail "apply exported wrapper not store: $BEADS_DIR"
out=$(write_beads_redirect "$WRAP_FORK" "$WRAP_HOST/.beads")
[[ -n "$out" ]] || fail "wrap-fork write printed nothing"
got=$(tr -d '\r\n' < "$WRAP_FORK/.beads/redirect")
[[ "$got" == "$real_abs" ]] || fail "fork redirect chained to wrapper: $got (want $real_abs)"
# Caller BEADS_DIR that is itself a redirect wrapper.
BEADS_DIR="$WRAP_HOST/.beads"
got=$(host_beads_dir) || fail "BEADS_DIR wrapper host_beads_dir failed"
[[ "$got" == "$real_abs" ]] || fail "BEADS_DIR wrapper not followed: $got"
unset BEADS_DIR
unset BEAD_CYCLE_BEADS_DIR
# Relative redirect is resolved from the parent of the beads dir.
WRAP_REL="$TMP/wrap-rel"
mkdir -p "$WRAP_REL/.beads"
printf '../real-store\n' >"$WRAP_REL/.beads/redirect"
REPO_ROOT=$WRAP_REL
got=$(host_beads_dir) || fail "relative redirect host_beads_dir failed"
[[ "$got" == "$real_abs" ]] || fail "relative redirect: $got (want $real_abs)"
# One hop only (bd FollowRedirect does not chain).
CHAIN_A="$TMP/chain-a"
CHAIN_B="$TMP/chain-b"
CHAIN_C="$TMP/chain-c"
mkdir -p "$CHAIN_A/.beads" "$CHAIN_B/.beads" "$CHAIN_C"
printf '%s\n' "$(cd "$CHAIN_B/.beads" && pwd -P)" >"$CHAIN_A/.beads/redirect"
printf '%s\n' "$(cd "$CHAIN_C" && pwd -P)" >"$CHAIN_B/.beads/redirect"
REPO_ROOT=$CHAIN_A
got=$(host_beads_dir) || fail "chain host_beads_dir failed"
chain_b_abs=$(cd "$CHAIN_B/.beads" && pwd -P)
[[ "$got" == "$chain_b_abs" ]] || fail "should follow only one hop: $got (want $chain_b_abs)"
# Broken redirect target keeps the wrapper.
BROKEN="$TMP/broken-host"
mkdir -p "$BROKEN/.beads"
printf '/no/such/beads-store\n' >"$BROKEN/.beads/redirect"
REPO_ROOT=$BROKEN
got=$(host_beads_dir) || fail "broken redirect should keep wrapper"
broken_abs=$(cd "$BROKEN/.beads" && pwd -P)
[[ "$got" == "$broken_abs" ]] || fail "broken redirect dropped wrapper: $got"
REPO_ROOT=$saved_repo
unset BEADS_DIR
unset BEAD_CYCLE_BEADS_DIR

# CDPATH must not send a relative BEADS_DIR to a decoy store, and cd must
# not print an extra path into $(canonical_dir) / host_beads_dir.
CDPATH_WORK="$TMP/cdpath-work"
CDPATH_DECOY="$TMP/cdpath-decoy"
mkdir -p "$CDPATH_WORK/beads" "$CDPATH_DECOY/beads"
printf 'intended\n' >"$CDPATH_WORK/beads/sentinel"
printf 'decoy\n' >"$CDPATH_DECOY/beads/sentinel"
intended_beads=$(cd "$CDPATH_WORK/beads" && pwd -P)
(
  cd "$CDPATH_WORK"
  export CDPATH="$CDPATH_DECOY"
  got=$(canonical_dir beads) || exit 10
  [[ "$got" == "$intended_beads" ]] || exit 11
  BEADS_DIR=beads
  unset REPO_ROOT
  got=$(host_beads_dir) || exit 12
  [[ "$got" == "$intended_beads" ]] || exit 13
  apply_host_beads_dir || exit 14
  [[ "$BEADS_DIR" == "$intended_beads" ]] || exit 15
  [[ "$BEAD_CYCLE_BEADS_DIR" == "$intended_beads" ]] || exit 16
)
cdpath_st=$?
if [[ $cdpath_st -ne 0 ]]; then
  fail "CDPATH redirected canonical_dir/host_beads_dir (status $cdpath_st)"
fi

# checkout_belongs_to_host: same tree, grok source match/mismatch, foreign git.
checkout_belongs_to_host "$HOST_ROOT" || fail "host should belong to host"
mkdir -p "$FORK/.git"
printf '%s\n' "$HOST_ROOT" >"$FORK/.git/grok-worktree-source"
checkout_belongs_to_host "$FORK" || fail "fork with matching grok-worktree-source rejected"
printf '%s\n' "$TMP/other-repo" >"$FORK/.git/grok-worktree-source"
if checkout_belongs_to_host "$FORK"; then
  fail "fork with foreign grok-worktree-source accepted"
fi
OTHER="$TMP/other-git"
mkdir -p "$OTHER"
git -c init.defaultBranch=main init --quiet "$OTHER"
if checkout_belongs_to_host "$OTHER"; then
  fail "foreign git checkout accepted"
fi

# Creating .beads/redirect in a dest with no .beads (legacy beads/ or
# external BEADS_DIR) must add a git exclude so Grok cannot commit it.
BARE_FORK="$TMP/bare-git-fork"
mkdir -p "$BARE_FORK"
git -c init.defaultBranch=main init --quiet "$BARE_FORK"
[[ ! -e "$BARE_FORK/.beads" ]] || fail "bare fork already had .beads"
out=$(write_beads_redirect "$BARE_FORK" "$HOST_BEADS")
[[ -n "$out" ]] || fail "bare-fork write printed nothing"
[[ -f "$BARE_FORK/.beads/redirect" ]] || fail "bare fork missing redirect"
git -C "$BARE_FORK" check-ignore -q .beads/redirect \
  || fail "created .beads/redirect is not gitignored"
if git -C "$BARE_FORK" status --porcelain | grep -q '.beads'; then
  fail "created .beads/redirect appeared in git status"
fi
exclude=$(git -C "$BARE_FORK" rev-parse --git-path info/exclude)
case "$exclude" in
  /*) ;;
  *) exclude="$BARE_FORK/$exclude" ;;
esac
grep -qxF -- '.beads/redirect' "$exclude" || fail "exclude missing .beads/redirect"
# No-op rewrite must restore exclude if it was removed.
printf '# stripped\n' >"$exclude"
out=$(write_beads_redirect "$BARE_FORK" "$HOST_BEADS")
[[ -z "${out:-}" ]] || fail "noop exclude restore printed: $out"
git -C "$BARE_FORK" check-ignore -q .beads/redirect \
  || fail "noop write did not restore exclude"
# Append after a file that lacks a trailing newline must not glue.
printf '# no-nl' >"$exclude"
out=$(write_beads_redirect "$BARE_FORK" "$HOST_BEADS")
[[ -z "${out:-}" ]] || fail "no-nl exclude restore printed: $out"
grep -qxF -- '.beads/redirect' "$exclude" || fail "glued exclude line: $(cat "$exclude")"
git -C "$BARE_FORK" check-ignore -q .beads/redirect \
  || fail "no-nl exclude did not ignore redirect"

# OUT_FILE must be cleared before the cycle_cleanup EXIT trap.
if ! awk '
  $0 ~ /^OUT_FILE=""/ { cleared = 1 }
  $0 ~ /trap '\''cycle_cleanup'\'' EXIT/ {
    if (!cleared) { print "EXIT trap before OUT_FILE clear"; exit 1 }
  }
' "$SCRIPT"; then
  fail "OUT_FILE not cleared before cycle_cleanup EXIT trap"
fi

# apply_host_beads_dir must run in main before the first bd call.
if ! awk '
  $0 ~ /if ! apply_host_beads_dir/ { applied = 1 }
  $0 ~ /^resolve_scope_from_arg$/ {
    if (!applied) { print "resolve_scope_from_arg before apply_host_beads_dir"; exit 1 }
  }
' "$SCRIPT"; then
  fail "apply_host_beads_dir not called before resolve_scope_from_arg"
fi

pass "write_beads_redirect"
