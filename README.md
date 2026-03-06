# npm-repo-updater

A Bash script that automates `npm` dependency updates across multiple local Git repositories — including test verification, safe rollback on failure, and a color-coded summary.

## How it works

`npm-repo-updater.sh` iterates over a list of local repository paths defined in `repos.conf`. For each repository it:

1. Records the current Git `HEAD` as a restore point.
2. Runs `npm update` to update all dependencies within the allowed semver ranges.
3. Checks whether `package-lock.json` was actually modified. If not, the repo is skipped (no unnecessary commits).
4. Runs `npm run test` to verify that the updated dependencies don't break anything.
5. Commits the changes with the message `"Dependencies updated"`, rebases against the remote, and pushes.
6. Reverts the working tree to the recorded `HEAD` at any point of failure (step 2, 4, or 5) so no partial or broken state is left behind.

After all repositories have been processed, a summary table is printed showing each repo's outcome.

## Requirements

- Bash 4.0+
- Git
- Node.js / npm
- Each repository must have a `test` script defined in its `package.json`

> **No tests in a repo?** The script requires `npm run test` to exit with code `0`. If a repository has no test suite, add a no-op test script to its `package.json` so the update pipeline can still run safely:
>
> ```json
> "scripts": {
>   "test": "node -e \"process.exit(0)\""
> }
> ```
>
> This uses Node.js — already present in any npm project — and works identically on Linux, macOS, and Windows regardless of the shell npm uses internally.

## Configuration

Create a `repos.conf` file **in the same directory as the script**. The file is read line by line via `mapfile`; each non-blank, non-comment line is treated as a repository path **relative to the script's location**.

```
# repos.conf — paths are relative to the directory containing npm-repo-updater.sh

# Sibling directories
../my-api
../frontend-app

# Subdirectories
projects/shared-utils

# Deeper nesting is supported
../../workspace/legacy-service
```

Tips:
- Lines starting with `#` are treated as comments and ignored.
- Blank lines are ignored.
- Paths may use `..` to traverse above the script's directory.
- Trailing whitespace on a line is preserved by `mapfile` — avoid it to prevent path resolution failures.

## Usage

```bash
# Basic run
./npm-repo-updater.sh

# With logging to a file
./npm-repo-updater.sh --log /var/log/npm-repo-updater.log
```

### Options

| Option | Description |
|---|---|
| `--log <file>` | Append a timestamped log of all output to the given file. |

## Error handling

Every failure mode is handled explicitly. If an error occurs, the script:

- Logs a clear `❌` error message describing what failed.
- Runs `git reset --hard <ORIG_HEAD>` to restore the repository to the exact state it was in before the update started — this covers partially modified files (`npm update`), staged changes (`git add`), and even local commits that were made before a push failure.
- Marks the repository as `Error` in the summary and moves on to the next one.

The script **never aborts the entire run** due to a single repo failing; all repos in `repos.conf` are always attempted.

Possible status values per repository:

| Status | Meaning |
|---|---|
| `Dependencies updated` | `npm update` produced changes, tests passed, and changes were pushed successfully. |
| `No updates` | `npm update` ran successfully but `package-lock.json` was unchanged — nothing to commit. |
| `Error` | A failure occurred (npm, tests, or git). Changes were reverted. |

## Logging

Without `--log`, all output goes to stdout only.

With `--log <file>`, **every log line is also appended** to the specified file with a timestamp prefix:

```
2026-03-06 14:32:01 → Processing repository: /home/user/repos/my-api
2026-03-06 14:32:04 → npm update…
2026-03-06 14:32:09 → Changes found. Running npm run test…
2026-03-06 14:32:21 → Tests OK. Commit & Push…
2026-03-06 14:32:23 ✔️ Repo ../my-api successfully updated
```

The log file is plain text (no ANSI color codes), making it safe to use with log aggregators or `grep`.

## Summary

At the end of each run, a table is printed to stdout:

```
Repository                               | Status
-----------------------------------------+--------------------------
../my-api                                | Dependencies updated
../frontend-app                          | No updates
../shared-utils                          | Error
```

Repositories with status `Error` are highlighted in red in the terminal output.

## License

MIT
