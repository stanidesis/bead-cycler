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
  [[ "$(stat -c '%a' "$tmp/scripts/bead-cycle")" == 755 ]]
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

# --yes must keep a dangling cycle.conf / bead-cycle symlink; --force replaces.
test_yes_keeps_dangling_symlinks() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  mkdir -p "$tmp/.beads" "$tmp/scripts"
  ln -s "$tmp/.beads/missing.conf" "$tmp/.beads/cycle.conf"
  ln -s "$tmp/scripts/missing" "$tmp/scripts/bead-cycle"
  bash "$INIT" --yes --dir "$tmp" >/dev/null
  assert test -L "$tmp/.beads/cycle.conf"
  assert test -L "$tmp/scripts/bead-cycle"
  rm -rf "$tmp"
}

test_force_replaces_dangling_symlinks() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  mkdir -p "$tmp/.beads" "$tmp/scripts"
  ln -s "$tmp/.beads/missing.conf" "$tmp/.beads/cycle.conf"
  ln -s "$tmp/scripts/missing" "$tmp/scripts/bead-cycle"
  bash "$INIT" --yes --force --dir "$tmp" >/dev/null
  assert test ! -L "$tmp/.beads/cycle.conf"
  assert test -f "$tmp/.beads/cycle.conf"
  assert_core_conf "$tmp/.beads/cycle.conf"
  assert test ! -L "$tmp/scripts/bead-cycle"
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

# CDPATH can make `cd app` land in another tree and pollute $(cd ...).
test_cdpath_does_not_redirect_dir() {
  local tmp decoy workspace
  tmp=$(mktemp -d)
  decoy="$tmp/decoy"
  workspace="$tmp/workspace"
  mkdir -p "$decoy/app" "$workspace"
  make_repo "$decoy/app"
  make_repo "$workspace/app"
  (
    cd "$workspace"
    CDPATH="$decoy" bash "$INIT" --yes --dir app --create-beads >/dev/null
  )
  assert test -f "$workspace/app/.beads/cycle.conf"
  assert test ! -e "$decoy/app/.beads"
  rm -rf "$tmp"
}

# bead-cycle strips matching outer quotes, so "quoted" must be wrapped.
test_double_quoted_value_round_trips() {
  local tmp line val
  tmp=$(mktemp -d)
  make_repo "$tmp"
  BEAD_CYCLE_REVIEWER='"quoted"' bash "$INIT" --yes --dir "$tmp" --create-beads >/dev/null
  line=$(grep '^BEAD_CYCLE_REVIEWER=' "$tmp/.beads/cycle.conf")
  val=${line#BEAD_CYCLE_REVIEWER=}
  if [[ "$val" == \"*\" ]]; then
    val=${val#\"}
    val=${val%\"}
  elif [[ "$val" == \'*\' ]]; then
    val=${val#\'}
    val=${val%\'}
  fi
  [[ "$val" == '"quoted"' ]]
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

test_newline_value_no_writes() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  if BEAD_CYCLE_REVIEWER=$'copilot\nbot' bash "$INIT" --yes --dir "$tmp" --create-beads >/dev/null 2>&1; then
    rm -rf "$tmp"
    printf 'expected newline REVIEWER to fail\n' >&2
    return 1
  fi
  assert test ! -e "$tmp/.beads"
  assert test ! -e "$tmp/scripts"
  rm -rf "$tmp"
}

# mv into a directory named cycle.conf would "succeed" and leave CONF_PATH
# as a directory. Reject that before any writes (same as SCRIPT_DEST).
test_conf_path_is_directory() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  mkdir -p "$tmp/.beads/cycle.conf" "$tmp/scripts"
  if bash "$INIT" --yes --force --dir "$tmp" >/dev/null 2>&1; then
    rm -rf "$tmp"
    printf 'expected directory cycle.conf to fail\n' >&2
    return 1
  fi
  assert test -d "$tmp/.beads/cycle.conf"
  assert test ! -e "$tmp/scripts/bead-cycle"
  rm -rf "$tmp"
}

# Next: copy-paste lines must remain valid when --dir / --script-dir
# contain whitespace (printf %q).
test_next_step_quotes_paths() {
  local tmp repo out
  tmp=$(mktemp -d)
  repo="$tmp/my cool app"
  make_repo "$repo"
  out=$(bash "$INIT" --yes --dir "$repo" --create-beads --script-dir "bin tools")
  printf '%s\n' "$out" | grep -Fq "cd $(printf %q "$repo")"
  printf '%s\n' "$out" | grep -Fq "$(printf %q "./bin tools/bead-cycle") --help"
  assert test -x "$repo/bin tools/bead-cycle"
  assert test -f "$repo/.beads/cycle.conf"
  rm -rf "$tmp"
}

# --bd-init is a primary advertised mode. Stub bd so we cover command
# selection, rediscovery of the dir bd created, and conf placement.
test_bd_init_discovers_beads_dir() {
  local tmp stub
  tmp=$(mktemp -d)
  stub=$(mktemp -d)
  make_repo "$tmp"
  cat >"$stub/bd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$PWD/.bd-stub-args"
[[ $# -eq 2 && "$1" == init && "$2" == --non-interactive ]] || exit 1
# Legacy layout so init must rediscover, not assume .beads/.
mkdir -p "$PWD/beads"
EOF
  chmod +x "$stub/bd"
  PATH="$stub:$PATH" bash "$INIT" --yes --dir "$tmp" --bd-init >/dev/null
  grep -q '^init --non-interactive$' "$tmp/.bd-stub-args"
  assert test -f "$tmp/beads/cycle.conf"
  assert test ! -e "$tmp/.beads/cycle.conf"
  assert_core_conf "$tmp/beads/cycle.conf"
  assert test -x "$tmp/scripts/bead-cycle"
  rm -rf "$tmp" "$stub"
}

# --yes keeps a cycle.conf that bd init created (legacy beads/ path).
test_bd_init_yes_keeps_cycle_conf() {
  local tmp stub err
  tmp=$(mktemp -d)
  stub=$(mktemp -d)
  make_repo "$tmp"
  cat >"$stub/bd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 && "$1" == init && "$2" == --non-interactive ]] || exit 1
mkdir -p "$PWD/beads"
printf 'BEAD_CYCLE_REVIEWER=from-bd\n' >"$PWD/beads/cycle.conf"
EOF
  chmod +x "$stub/bd"
  err=$(PATH="$stub:$PATH" bash "$INIT" --yes --dir "$tmp" --bd-init 2>&1)
  printf '%s\n' "$err" | grep -q 'keeping existing'
  grep -q '^BEAD_CYCLE_REVIEWER=from-bd$' "$tmp/beads/cycle.conf"
  assert test ! -e "$tmp/.beads/cycle.conf"
  assert test -x "$tmp/scripts/bead-cycle"
  rm -rf "$tmp" "$stub"
}

# --force still replaces the file bd init wrote.
test_bd_init_force_overwrites_cycle_conf() {
  local tmp stub
  tmp=$(mktemp -d)
  stub=$(mktemp -d)
  make_repo "$tmp"
  cat >"$stub/bd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 && "$1" == init && "$2" == --non-interactive ]] || exit 1
mkdir -p "$PWD/beads"
printf 'BEAD_CYCLE_REVIEWER=from-bd\n' >"$PWD/beads/cycle.conf"
EOF
  chmod +x "$stub/bd"
  PATH="$stub:$PATH" bash "$INIT" --yes --force --dir "$tmp" --bd-init >/dev/null
  grep -q '^BEAD_CYCLE_REVIEWER=copilot-pull-request-reviewer\[bot\]$' "$tmp/beads/cycle.conf"
  assert test -x "$tmp/scripts/bead-cycle"
  rm -rf "$tmp" "$stub"
}

# --script-dir bin when bin is a regular file: mkdir -p fails after conf
# would already have been written. Reject the ancestor before any writes.
test_script_dir_parent_is_file() {
  local tmp
  tmp=$(mktemp -d)
  make_repo "$tmp"
  printf 'not a dir\n' >"$tmp/bin"
  if bash "$INIT" --yes --dir "$tmp" --create-beads --script-dir bin >/dev/null 2>&1; then
    rm -rf "$tmp"
    printf 'expected file parent to fail\n' >&2
    return 1
  fi
  assert test ! -e "$tmp/.beads"
  assert test ! -e "$tmp/scripts"
  assert test -f "$tmp/bin"
  rm -rf "$tmp"
}

# cp would follow dest and overwrite the external target; mv replaces
# the symlink in the repo instead.
test_force_replaces_symlink() {
  local tmp ext
  tmp=$(mktemp -d)
  ext=$(mktemp)
  printf 'external\n' >"$ext"
  make_repo "$tmp"
  mkdir -p "$tmp/scripts" "$tmp/.beads"
  ln -s "$ext" "$tmp/scripts/bead-cycle"
  bash "$INIT" --yes --force --dir "$tmp" >/dev/null
  assert test ! -L "$tmp/scripts/bead-cycle"
  assert test -x "$tmp/scripts/bead-cycle"
  cmp -s "$ROOT/scripts/bead-cycle" "$tmp/scripts/bead-cycle"
  grep -q '^external$' "$ext"
  rm -rf "$tmp"
  rm -f "$ext"
}

# --force self-init copies scripts/bead-cycle onto itself; cp rejects that.
# Point --script-dir at the source file so we hit the same-file path without
# rewriting this checkout's cycle.conf.
test_same_file_script_copy() {
  local tmp before after err
  tmp=$(mktemp -d)
  make_repo "$tmp"
  mkdir -p "$tmp/.beads"
  before=$(cksum "$ROOT/scripts/bead-cycle")
  err=$(bash "$INIT" --yes --force --dir "$tmp" --script-dir "$ROOT/scripts/bead-cycle" 2>&1)
  after=$(cksum "$ROOT/scripts/bead-cycle")
  [[ "$before" == "$after" ]]
  printf '%s\n' "$err" | grep -q 'bead-cycle already installed'
  assert test -f "$tmp/.beads/cycle.conf"
  assert_core_conf "$tmp/.beads/cycle.conf"
  rm -rf "$tmp"
}

run_test test_help
run_test test_unknown_flag
run_test test_create_beads_and_bd_init_exclusive
run_test test_yes_with_scripts_dir
run_test test_yes_creates_scripts_dir
run_test test_yes_keeps_existing_conf
run_test test_yes_keeps_dangling_symlinks
run_test test_force_replaces_dangling_symlinks
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
run_test test_cdpath_does_not_redirect_dir
run_test test_double_quoted_value_round_trips
run_test test_unquotable_value_no_writes
run_test test_newline_value_no_writes
run_test test_conf_path_is_directory
run_test test_next_step_quotes_paths
run_test test_bd_init_discovers_beads_dir
run_test test_bd_init_yes_keeps_cycle_conf
run_test test_bd_init_force_overwrites_cycle_conf
run_test test_script_dir_parent_is_file
run_test test_force_replaces_symlink
run_test test_same_file_script_copy

printf '\n%s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[[ "$TESTS_FAIL" -eq 0 ]]
