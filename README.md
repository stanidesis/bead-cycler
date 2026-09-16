# bead-cycler

Drop-in host autopilot for a [Beads](https://github.com/gastownhall/beads) repo on GitHub.

The script claims (or resumes) one implementable bead, asks [Grok](https://grok.x.ai/) to implement it and open a PR, then **bash** polls the configured reviewer (`BEAD_CYCLE_REVIEWER`, default Copilot). It starts another Grok session when there are unresolved reviewer threads, or when a "Needs a Closer Look" (or similar) overview lists suppressed comments with no threads. An overview with neither is treated as green. An APPROVED review (or unchanged unresolved threads) is not green while suppressed comments remain. The same suppressed path:line set after a Grok fix is still blocking; a suppressed-comments section that cannot be parsed is a hard failure. After the reviewer is green it waits for CI, merges if allowed, and closes the bead.

Copy `scripts/bead-cycle` into another Beads repo and run it. No other files are required. Optional `.beads/cycle.conf` (or `beads/cycle.conf`) turns on extra `--drain` close-out gates. If this repo is a sibling of the target, `scripts/init` can copy the script and write that config after a short wizard.

## Requirements

| Tool | Why |
|---|---|
| `bd` | claim / show / ready / close |
| `gh` (authenticated) | PRs, reviewer polls, merge |
| `jq` | JSON |
| `git` | branches and worktrees |
| `grok` CLI | implement + fix sessions |
| Copilot PR reviewer | default nurse (overridable) |

Bash 3.2+ (stock macOS `/usr/bin/env bash` is fine).

## Install

### Sibling checkout (`scripts/init`)

From the parent of both repos (or any cwd; `--dir` is the target):

```bash
./bead-cycler/scripts/init --dir ./my-cool-app/
```

The wizard resolves the target git toplevel, then:

1. Uses `.beads/` if present (or `beads/` for that layout). If neither exists, asks whether to create `.beads/`, run `bd init`, or abort.
2. Prompts for core `BEAD_CYCLE_*` keys (Enter = documented default; already-set env vars pre-fill). Then optionally extra `--drain` gates.
3. Writes `cycle.conf` into that Beads dir.
4. Copies `scripts/bead-cycle` into `scripts/` when that directory exists; otherwise asks where to put it.

`--yes` is non-interactive (defaults, keep existing files). `--force` overwrites. `--create-beads` or `--bd-init` is required with `--yes` when the target has no Beads dir. `--script-dir` sets the copy destination. `--dry-run` prints actions and writes nothing. `--help` lists every flag.

`init` refuses to install into this bead-cycler repo unless you pass `--force`. It does not copy itself into the target.

### Script only

```bash
mkdir -p scripts
curl -fsSL https://raw.githubusercontent.com/stanidesis/bead-cycler/main/scripts/bead-cycle \
  -o scripts/bead-cycle
chmod +x scripts/bead-cycle
```

Or copy `scripts/bead-cycle` from this repo. The script finds the git toplevel from its own path or the current directory, so it can live at `scripts/bead-cycle`, `bin/bead-cycle`, or the repo root.

## Usage

```bash
./scripts/bead-cycle                 # resume in-progress non-epic, else next ready non-epic
./scripts/bead-cycle <bead-id>       # that bead (resumes if already claimed)
./scripts/bead-cycle <epic-id>       # next ready child of that epic only
./scripts/bead-cycle --drain <epic-id>   # remaining children, then close the epic iff eligible
```

Epics and milestones are grouping only — never claimed or implemented. An epic id without `--drain` is a **scope**: one child per run. `--help` lists flags, exit codes, and every config key.

Drain one-by-one without closing the epic:

```bash
while ./scripts/bead-cycle; do :; done
# stops on QUEUE_EMPTY (3), hard failure (1), or leftover reviewer comments (2)
```

## Default `--drain` close-out

`--drain` always requires at least one child, every descendant closed, and `eligible_for_close`. With no extra config, `--drain <epic-id>` closes the epic iff:

- every descendant is closed (including nested epics/milestones)
- `bd epic status` reports `eligible_for_close` (open epics only)
- the epic has at least one child

Extra gates apply only when the corresponding keys are set in `.beads/cycle.conf` or `BEAD_CYCLE_DRAIN_*` environment variables (env wins over the file). It never calls `bd epic close-eligible` (that would close every eligible epic).

## Optional config

Search order (later wins):

1. Built-in defaults
2. `$REPO/.beads/cycle.conf` (preferred) or `$REPO/beads/cycle.conf`
3. Environment `BEAD_CYCLE_*`
4. CLI flags (`--max-rounds`, `--no-merge`, …)

The file is `KEY=VALUE` only — it is **not** sourced. `#` comments and unknown keys are ignored. See [`examples/cycle.conf`](examples/cycle.conf).

Useful keys:

```
BEAD_CYCLE_REVIEWER=copilot-pull-request-reviewer[bot]
BEAD_CYCLE_BRANCH_PREFIX=feat/
BEAD_CYCLE_MERGE_METHODS=squash,merge

# Extra drain gates (empty = skip that gate)
BEAD_CYCLE_DRAIN_ID_MAP=
BEAD_CYCLE_DRAIN_ID_MAP_EPIC_KEY=e{n}
BEAD_CYCLE_DRAIN_ID_MAP_CLOSE_KEY=e{n}-close
BEAD_CYCLE_DRAIN_WRITEUP_GLOB=
BEAD_CYCLE_DRAIN_WRITEUP_HEADINGS=
BEAD_CYCLE_DRAIN_WRITEUP_N_MIN=
BEAD_CYCLE_DRAIN_WRITEUP_N_MAX=
BEAD_CYCLE_DRAIN_CHANGESET_GLOB=
```

`{n}` is the unpadded epic number (from an `epic-N` label or `E<n>` title). `{nn}` is two-digit (`1` → `01`, `10` → `10`). Origin/`<default-branch>` is the only artifact source.

## Prompts

Grok prompts are self-contained (one claimed bead, branch prefix, configured reviewer login, `BEAD_CYCLE_RESULT=…`). Fix prompts receive parsed path:line excerpts, not the raw review body. If `AGENTS.md` or `.grok/skills/bead-cycle/SKILL.md` exists in the target repo, the prompt also points at them. They are not required.

## Crash resume

Re-running after Ctrl-C, a failed Grok session, or a killed host continues the same bead: in-progress issues, `<prefix><id>-*` branches/worktrees, and open PRs are reused. Implement is skipped when a PR is already open. A merged PR with a still-open bead is closed without another Grok session.

## Grok worktrees and the beads database

`grok --worktree` forks are standalone clones, so `bd` in the fork would otherwise open an empty local Dolt database. bead-cycle writes `.beads/redirect` in each matching fork (a canonical absolute path to this checkout's `.beads`, or `beads/` if that layout is used, or `BEADS_DIR` if set) and exports `BEADS_DIR` so `bd list` / `show` / `create` use the host tracker. `--no-worktree` skips the redirect file and still exports `BEADS_DIR`.

## Tests

```bash
bash tests/init.test.sh
bash tests/bead-cycle-redirect.test.sh
```
