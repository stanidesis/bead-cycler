#!/usr/bin/env bash
# Smoke tests for scripts/init. No extra framework.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INIT="$ROOT/scripts/init"

# Init's --yes path treats these as pre-fills. Unset so default assertions
# are stable; tests that need a value prefix it on the init command.
unset \
  BEAD_CYCLE_REVIEWER \
  BEAD_CYCLE_BRANCH_PREFIX \
  BEAD_CYCLE_MERGE_METHODS \
  BEAD_CYCLE_MAX_ROUNDS \
  BEAD_CYCLE_MAX_TURNS \
  BEAD_CYCLE_POLL_SECONDS \
  BEAD_CYCLE_REVIEW_TIMEOUT \
  BEAD_CYCLE_CI_TIMEOUT \
  BEAD_CYCLE_MAX_BEADS \
  BEAD_CYCLE_DRAIN_ID_MAP \
  BEAD_CYCLE_DRAIN_ID_MAP_EPIC_KEY \
  BEAD_CYCLE_DRAIN_ID_MAP_CLOSE_KEY \
  BEAD_CYCLE_DRAIN_WRITEUP_GLOB \
  BEAD_CYCLE_DRAIN_WRITEUP_HEADINGS \
  BEAD_CYCLE_DRAIN_WRITEUP_N_MIN \
  BEAD_CYCLE_DRAIN_WRITEUP_N_MAX \
  BEAD_CYCLE_DRAIN_CHANGESET_GLOB

TESTS_RUN=0
TESTS_FAIL=0
CURRENT=""

fail() {
  printf 'not ok %s %s: %s\n' "$TESTS_RUN" "$CURRENT" "$*"
  TESTS_FAIL=$((TESTS_FAIL + 1))
}

pass() {
  printf 'ok %s %s\n' "$TESTS_RUN" "$CURRENT"
}

run_test() {
  local st
  CURRENT=$1
  TESTS_RUN=$((TESTS_RUN + 1))
  # set -e is ignored for the test command of `if`; run the case as a
  # standalone subshell so grep/assert/cmp failures actually fail.
  set +e
  ( set -euo pipefail; "$1" )
  st=$?
  set -e
  if [[ "$st" -eq 0 ]]; then
    pass
  else
    printf 'not ok %s %s\n' "$TESTS_RUN" "$CURRENT"
    TESTS_FAIL=$((TESTS_FAIL + 1))
  fi
}

assert() {
  if ! "$@"; then
    printf 'assertion failed: %s\n' "$*" >&2
    return 1
  fi
}

make_repo() {
  local d=$1
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
}

assert_core_conf() {
  local conf=$1
  grep -q '^BEAD_CYCLE_REVIEWER=copilot-pull-request-reviewer\[bot\]$' "$conf"
  grep -q '^BEAD_CYCLE_BRANCH_PREFIX=feat/$' "$conf"
  grep -q '^BEAD_CYCLE_MERGE_METHODS=squash,merge$' "$conf"
  grep -q '^BEAD_CYCLE_MAX_ROUNDS=5$' "$conf"
  grep -q '^BEAD_CYCLE_MAX_TURNS=80$' "$conf"
  grep -q '^BEAD_CYCLE_POLL_SECONDS=15$' "$conf"
  grep -q '^BEAD_CYCLE_REVIEW_TIMEOUT=600$' "$conf"
  grep -q '^BEAD_CYCLE_CI_TIMEOUT=1200$' "$conf"
  grep -q '^BEAD_CYCLE_MAX_BEADS=40$' "$conf"
  if grep -E '^BEAD_CYCLE_DRAIN_' "$conf"; then
    printf 'unexpected uncommented drain key in %s\n' "$conf" >&2
    return 1
  fi
}

test_help() {
  bash "$INIT" --help >/dev/null
}

test_unknown_flag() {
  if bash "$INIT" --nope >/dev/null 2>&1; then
    printf 'expected unknown flag to fail\n' >&2
    return 1
  fi
}

test_create_beads_and_bd_init_exclusive() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  if bash "$INIT" --yes --dir "$tmp" --create-beads --bd-init >/dev/null 2>&1; then
    rm -rf "$tmp"
    printf 'expected mutually exclusive flags to fail\n' >&2
    return 1
  fi
  rm -rf "$tmp"
}

test_yes_with_scripts_dir() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  mkdir -p "$tmp/scripts"
  bash "$INIT" --yes --dir "$tmp" --create-beads >/dev/null
  assert test -f "$tmp/.beads/cycle.conf"
  assert_core_conf "$tmp/.beads/cycle.conf"
  assert test -x "$tmp/scripts/bead-cycle"
  assert test ! -L "$tmp/scripts/bead-cycle"
  cmp -s "$ROOT/scripts/bead-cycle" "$tmp/scripts/bead-cycle"
  rm -rf "$tmp"
}

test_yes_creates_scripts_dir() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  bash "$INIT" --yes --dir "$tmp" --create-beads >/dev/null
  assert test -x "$tmp/scripts/bead-cycle"
  rm -rf "$tmp"
}

test_yes_keeps_existing_conf() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  mkdir -p "$tmp/.beads" "$tmp/scripts"
  printf 'BEAD_CYCLE_REVIEWER=keep-me\n' >"$tmp/.beads/cycle.conf"
  bash "$INIT" --yes --dir "$tmp" --create-beads >/dev/null
  grep -q '^BEAD_CYCLE_REVIEWER=keep-me$' "$tmp/.beads/cycle.conf"
  assert test -x "$tmp/scripts/bead-cycle"
  rm -rf "$tmp"
}

test_force_overwrites_conf() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  mkdir -p "$tmp/.beads" "$tmp/scripts"
  printf 'BEAD_CYCLE_REVIEWER=old\n' >"$tmp/.beads/cycle.conf"
  printf 'old\n' >"$tmp/scripts/bead-cycle"
  bash "$INIT" --yes --force --dir "$tmp" >/dev/null
  grep -q '^BEAD_CYCLE_REVIEWER=copilot-pull-request-reviewer\[bot\]$' "$tmp/.beads/cycle.conf"
  cmp -s "$ROOT/scripts/bead-cycle" "$tmp/scripts/bead-cycle"
  rm -rf "$tmp"
}

test_missing_beads_without_flags() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  if bash "$INIT" --yes --dir "$tmp" >/dev/null 2>&1; then
    rm -rf "$tmp"
    printf 'expected missing beads dir to fail without flags\n' >&2
    return 1
  fi
  assert test ! -e "$tmp/.beads"
  assert test ! -e "$tmp/scripts"
  rm -rf "$tmp"
}

test_refuses_cycler_root() {
  if bash "$INIT" --yes --dir "$ROOT" --create-beads >/dev/null 2>&1; then
    printf 'expected self-init without --force to fail\n' >&2
    return 1
  fi
}

test_dry_run_creates_nothing() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  bash "$INIT" --yes --dry-run --dir "$tmp" --create-beads >/dev/null
  assert test ! -e "$tmp/.beads"
  assert test ! -e "$tmp/scripts"
  rm -rf "$tmp"
}

test_dir_subdirectory_uses_toplevel() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  mkdir -p "$tmp/sub/nested"
  bash "$INIT" --yes --dir "$tmp/sub/nested" --create-beads >/dev/null
  assert test -f "$tmp/.beads/cycle.conf"
  assert test -x "$tmp/scripts/bead-cycle"
  assert test ! -e "$tmp/sub/nested/.beads"
  rm -rf "$tmp"
}

test_bad_max_rounds_env_no_writes() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  if BEAD_CYCLE_MAX_ROUNDS=nope bash "$INIT" --yes --dir "$tmp" --create-beads >/dev/null 2>&1; then
    rm -rf "$tmp"
    printf 'expected invalid MAX_ROUNDS to fail\n' >&2
    return 1
  fi
  assert test ! -e "$tmp/.beads"
  assert test ! -e "$tmp/scripts"
  rm -rf "$tmp"
}

test_bad_merge_methods_env_no_writes() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  if BEAD_CYCLE_MERGE_METHODS=rebase,ff bash "$INIT" --yes --dir "$tmp" --create-beads >/dev/null 2>&1; then
    rm -rf "$tmp"
    printf 'expected invalid MERGE_METHODS to fail\n' >&2
    return 1
  fi
  assert test ! -e "$tmp/.beads"
  assert test ! -e "$tmp/scripts"
  rm -rf "$tmp"
}

test_legacy_beads_dir() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  mkdir -p "$tmp/beads" "$tmp/scripts"
  bash "$INIT" --yes --dir "$tmp" >/dev/null
  assert test -f "$tmp/beads/cycle.conf"
  assert test ! -e "$tmp/.beads/cycle.conf"
  assert_core_conf "$tmp/beads/cycle.conf"
  rm -rf "$tmp"
}

test_script_dir_flag() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  bash "$INIT" --yes --dir "$tmp" --create-beads --script-dir bin >/dev/null
  assert test -x "$tmp/bin/bead-cycle"
  assert test ! -e "$tmp/scripts/bead-cycle"
  rm -rf "$tmp"
}

test_env_prefill_yes() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  BEAD_CYCLE_REVIEWER=some-bot BEAD_CYCLE_BRANCH_PREFIX=topic \
    bash "$INIT" --yes --dir "$tmp" --create-beads >/dev/null
  grep -q '^BEAD_CYCLE_REVIEWER=some-bot$' "$tmp/.beads/cycle.conf"
  grep -q '^BEAD_CYCLE_BRANCH_PREFIX=topic/$' "$tmp/.beads/cycle.conf"
  rm -rf "$tmp"
}

test_unquotable_value_no_writes() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  if BEAD_CYCLE_REVIEWER='foo "bar" baz' bash "$INIT" --yes --dir "$tmp" --create-beads >/dev/null 2>&1; then
    rm -rf "$tmp"
    printf 'expected unquotable REVIEWER to fail\n' >&2
    return 1
  fi
  assert test ! -e "$tmp/.beads"
  assert test ! -e "$tmp/scripts"
  rm -rf "$tmp"
}

run_test test_help
run_test test_unknown_flag
run_test test_create_beads_and_bd_init_exclusive
run_test test_yes_with_scripts_dir
run_test test_yes_creates_scripts_dir
run_test test_yes_keeps_existing_conf
run_test test_force_overwrites_conf
run_test test_missing_beads_without_flags
run_test test_refuses_cycler_root
run_test test_dry_run_creates_nothing
run_test test_dir_subdirectory_uses_toplevel
run_test test_bad_max_rounds_env_no_writes
run_test test_bad_merge_methods_env_no_writes
run_test test_legacy_beads_dir
run_test test_script_dir_flag
run_test test_env_prefill_yes
run_test test_unquotable_value_no_writes

printf '\n%s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[[ "$TESTS_FAIL" -eq 0 ]]
