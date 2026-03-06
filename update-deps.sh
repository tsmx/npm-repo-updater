#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------
# Option: --log <file>
# ---------------------------------------------------------
LOGFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)
      LOGFILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------
# Logging-Function
# ---------------------------------------------------------
log() {
  echo "$@"
  if [[ -n "$LOGFILE" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') $@" >> "$LOGFILE"
  fi
}

# ---------------------------------------------------------
# Load list of relative repository paths
# ---------------------------------------------------------
REPO_CONFIG="$SCRIPT_DIR/repos.conf"

if [[ ! -f "$REPO_CONFIG" ]]; then
  echo "❌ Repo config not found: $REPO_CONFIG"
  exit 1
fi

mapfile -t REPOS < <(
  grep -v '^\s*#' "$REPO_CONFIG" | grep -v '^\s*$'
)

# ---------------------------------------------------------
# Status-Tracking
# ---------------------------------------------------------
declare -A STATUS

# ---------------------------------------------------------
# Main loop
# ---------------------------------------------------------
for REL_PATH in "${REPOS[@]}"; do
  REPO_PATH="$SCRIPT_DIR/$REL_PATH"
  STATUS["$REL_PATH"]="Error"   # Default until success

  log ""
  log "========================================"
  log "→ Processing repository: $REPO_PATH"
  log "========================================"

  if [[ ! -d "$REPO_PATH" ]]; then
    log "⚠️  VPath not existing üskipping"
    STATUS["$REL_PATH"]="Error"
    continue
  fi

  cd "$REPO_PATH"

  if [[ ! -d ".git" ]]; then
    log "⚠️  KNo Git repository – üskipping"
    STATUS["$REL_PATH"]="Error"
    continue
  fi

  log "→ npm update…"
  npm update

  log "→ Checking changes in package-lock.json…"
  if git diff --quiet -- package-lock.json; then
    log "→ No changes – nothing to do."
    STATUS["$REL_PATH"]="No updates"
    continue
  fi

  log "→ Changes found. Running npm run test…"
  if ! npm run test; then
    log "❌ Tests failed – update stopped."
    STATUS["$REL_PATH"]="Error"
    continue
  fi

  log "→ Tests OK. Commit & Push…"

  git add .
  git commit -m "Dependencies updated"

  # Rebase + Push
  git pull --rebase
  git push

  log "✔️ Repo $REL_PATH esuccessfully updated"
  STATUS["$REL_PATH"]="Dependencies updated"
done

log ""
log "========================================"
log "        Summary for all Repos"
log "========================================"

printf "\n%-40s | %s\n" "Repository" "Status"
printf "%-40s-+-%s\n" "----------------------------------------" "-------------------------"

for REL_PATH in "${REPOS[@]}"; do
  printf "%-40s | %s\n" "$REL_PATH" "${STATUS[$REL_PATH]}"
done

printf "\n✨ Done.\n"
