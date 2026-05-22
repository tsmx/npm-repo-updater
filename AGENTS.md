# AGENTS.md

## What this repo is

A single Bash script (`npm-repo-updater.sh`) that runs `npm update`, tests, commits, and pushes across multiple repos listed in `repos.conf`. No build system, no packages, no tests for the script itself.

## The only file that matters

`npm-repo-updater.sh` — all logic lives here. `repos.conf` is required at runtime but is not committed (it's user-local).

## Running the script

```bash
./npm-repo-updater.sh
./npm-repo-updater.sh --log /path/to/file.log
./npm-repo-updater.sh --check-ci          # requires gh CLI authenticated
./npm-repo-updater.sh --log <file> --check-ci
```

## Terminal output / cursor control

The summary table is redrawn in-place using ANSI escape sequences during CI polling. Key areas to understand before editing that section:

- `poll_all_ci()` (around line 265) moves the cursor up with `\033[%dA` to redraw the table.
- On the first redraw it jumps `table_lines + 2` lines to also clear the blank line and "Waiting for CI results..." message printed before polling started.
- After polling completes, "✨ Done." is printed using `\033[2B\r\033[K` to move down and overwrite the "Waiting for CI results..." line in place — do not add an extra `printf "\n✨ Done.\n"` elsewhere or the lines will overlap.

## repos.conf

- Must be in the same directory as the script.
- Paths are relative to the script's directory.
- Lines starting with `#` and blank lines are ignored.
- Trailing whitespace on a path line will break resolution — avoid it.

## Error handling convention

On any failure per repo: `git reset --hard <ORIG_HEAD>` is run to restore state, the repo is marked `Error`, and the script continues. `set -euo pipefail` is active — unguarded new commands that can fail will abort the script unexpectedly.

## gh CLI dependency

`--check-ci` uses `gh api` and `gh run`. If `gh` is not found, CI checks are silently skipped. The script extracts `owner/repo` from the git remote URL (supports both HTTPS and SSH GitHub URLs).
