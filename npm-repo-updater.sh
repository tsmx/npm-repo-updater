#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------
# Options: --log <file>, --check-ci
# ---------------------------------------------------------
LOGFILE=""
CHECK_CI=0
CHECK_CI_ENABLED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)
      LOGFILE="$2"
      shift 2
      ;;
    --check-ci)
      CHECK_CI=1
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Check if gh CLI is available (if CI checking requested)
if [[ "$CHECK_CI" -eq 1 ]]; then
  if ! command -v gh &>/dev/null; then
    echo "⚠️  GitHub CLI not found. Skipping CI checks."
    CHECK_CI_ENABLED=0
  else
    CHECK_CI_ENABLED=1
  fi
fi

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
# Helper functions for CI checking
# ---------------------------------------------------------

# Extract owner/repo from git remote URL
extract_github_repo() {
  local remote_url="$1"
  
  # Handle HTTPS: https://github.com/owner/repo.git or https://github.com/owner/repo
  if [[ $remote_url =~ https://github\.com/([^/]+)/(.+)$ ]]; then
    local repo="${BASH_REMATCH[2]}"
    # Remove .git suffix if present
    repo="${repo%.git}"
    echo "${BASH_REMATCH[1]}/$repo"
    return 0
  fi
  
  # Handle SSH: git@github.com:owner/repo.git or git@github.com:owner/repo
  if [[ $remote_url =~ git@github\.com:([^/]+)/(.+)$ ]]; then
    local repo="${BASH_REMATCH[2]}"
    # Remove .git suffix if present
    repo="${repo%.git}"
    echo "${BASH_REMATCH[1]}/$repo"
    return 0
  fi
  
  # Not a GitHub repo
  return 1
}

# Query GitHub Checks API for a commit
get_check_runs() {
  local owner="$1"
  local repo="$2"
  local sha="$3"
  
  if ! gh api "/repos/$owner/$repo/commits/$sha/check-runs" 2>/dev/null; then
    return 1
  fi
}

# Determine overall CI status from check runs
determine_ci_status() {
  local owner="$1"
  local repo="$2"
  local sha="$3"
  
  local response
  response=$(get_check_runs "$owner" "$repo" "$sha") || return 1
  
  local total_count
  total_count=$(echo "$response" | jq -r '.total_count // 0' 2>/dev/null)
  
  # No check runs found
  if [[ "$total_count" -eq 0 ]]; then
    echo "No CI"
    return 0
  fi
  
  # Check for any failures or timeouts
  local has_failure
  has_failure=$(echo "$response" | jq '[.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")] | length > 0' 2>/dev/null)
  
  if [[ "$has_failure" == "true" ]]; then
    echo "CI failed"
    return 0
  fi
  
  # Check if all are completed and successful
  local all_completed
  all_completed=$(echo "$response" | jq '[.check_runs[] | select(.status == "completed")] | length' 2>/dev/null)
  
  if [[ "$all_completed" -eq "$total_count" ]]; then
    echo "CI passed"
    return 0
  fi
  
  # Still in progress
  echo "CI running"
  return 0
}

# Print summary table with optional CI Status column
print_summary_table() {
  local show_ci="$1"
  local in_place="${2:-0}"  # 1 = rewriting in place (no leading newline, overwrite lines)

  if [[ "$in_place" -eq 0 ]]; then
    printf "\n"
  fi

  if [[ "$show_ci" -eq 1 ]]; then
    printf "%-40s | %-25s | %s\033[K\n" "Repository" "Dependencies" "CI Status"
    printf "%-40s-+-%-25s-+-%s\033[K\n" "----------------------------------------" "-------------------------" "---------------------"
  else
    printf "%-40s | %s\033[K\n" "Repository" "Status"
    printf "%-40s-+-%s\033[K\n" "----------------------------------------" "-------------------------"
  fi
  
  for REL_PATH in "${REPOS[@]}"; do
    local dep_status="${STATUS[$REL_PATH]}"
    local ci_status="${CI_STATUS[$REL_PATH]:-}"

    if [[ "$show_ci" -eq 1 ]]; then
      # Color code: red for Error or CI failed, normal for others
      if [[ "$dep_status" == "Error" ]] || [[ "$ci_status" == "CI failed" ]]; then
        printf "%-40s | ${RED}%-25s${NC} | ${RED}%s${NC}\033[K\n" "$REL_PATH" "$dep_status" "$ci_status"
      else
        printf "%-40s | %-25s | %s\033[K\n" "$REL_PATH" "$dep_status" "$ci_status"
      fi
    else
      # Original single column format
      if [[ "$dep_status" == "Error" ]]; then
        printf "%-40s | ${RED}%s${NC}\033[K\n" "$REL_PATH" "$dep_status"
      else
        printf "%-40s | %s\033[K\n" "$REL_PATH" "$dep_status"
      fi
    fi
  done
}

# Poll CI status for a single repo
poll_single_repo() {
  local owner="$1"
  local repo="$2"
  local sha="$3"
  local rel_path="$4"
  local start_time="$5"
  local timeout=300  # 5 minutes
  local poll_interval=10
  
  while true; do
    local current_time
    current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    
    # Check if timeout reached
    if [[ $elapsed -ge $timeout ]]; then
      # If still running, mark as "CI running"
      if [[ "${CI_STATUS[$rel_path]}" == "CI running" ]]; then
        CI_STATUS[$rel_path]="CI running"
      fi
      return
    fi
    
    # Query CI status
    local new_status
    new_status=$(determine_ci_status "$owner" "$repo" "$sha" 2>/dev/null) || new_status="No CI"
    
    # Update if changed
    if [[ "${CI_STATUS[$rel_path]}" != "$new_status" ]]; then
      CI_STATUS[$rel_path]="$new_status"
    fi
    
    # If final status (not running), exit polling for this repo
    if [[ "$new_status" != "CI running" ]]; then
      return
    fi
    
    sleep "$poll_interval"
  done
}

# Main CI polling loop with in-place table updates
poll_all_ci() {
  local start_time
  start_time=$(date +%s)
  local timeout=300  # 5 minutes
  local poll_interval=10

  while true; do
    local current_time
    current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    
    # Check if timeout reached
    if [[ $elapsed -ge $timeout ]]; then
      break
    fi
    
    # Poll each repo that needs checking
    local any_running=0
    for REL_PATH in "${!CI_TO_CHECK[@]}"; do
      owner_repo="${CI_TO_CHECK[$REL_PATH]}"
      sha="${COMMIT_SHA[$REL_PATH]}"
      
      if [[ -z "$owner_repo" ]] || [[ -z "$sha" ]]; then
        continue
      fi
      
      owner="${owner_repo%/*}"
      repo="${owner_repo#*/}"
      
      # Query CI status
      new_status=$(determine_ci_status "$owner" "$repo" "$sha" 2>/dev/null) || new_status="No CI"
      
      # Update if changed
      if [[ "${CI_STATUS[$REL_PATH]}" != "$new_status" ]]; then
        CI_STATUS[$REL_PATH]="$new_status"
      fi
      
      # If still running, keep polling
      if [[ "$new_status" == "CI running" ]]; then
        any_running=1
      fi
    done
    
    # Restore cursor to saved position (top of table), redraw rows in place,
    # then re-save position at the top of the table for the next iteration
    tput rc 2>/dev/null || true
    tput sc 2>/dev/null || true  # re-save at top of table before overwriting
    print_summary_table "$CHECK_CI_ENABLED" 1
    
    # If nothing is running, we can exit early
    if [[ $any_running -eq 0 ]]; then
      break
    fi
    
    sleep "$poll_interval"
  done
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
declare -A CI_STATUS
declare -A COMMIT_SHA
declare -A CI_TO_CHECK
CI_TO_CHECK_COUNT=0

RED=$'\033[0;31m'
NC=$'\033[0m'

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

  ORIG_HEAD=$(git rev-parse HEAD)

  log "→ npm update…"
  if ! npm update; then
    log "❌ npm update failed – reverting changes."
    git reset --hard "$ORIG_HEAD"
    STATUS["$REL_PATH"]="Error"
    continue
  fi

  log "→ Checking changes in package-lock.json…"
  if git diff --quiet -- package-lock.json; then
    log "→ No changes – nothing to do."
    STATUS["$REL_PATH"]="No updates"
    continue
  fi

  log "→ Changes found. Running npm run test…"
  if ! npm run test; then
    log "❌ Tests failed – reverting changes."
    git reset --hard "$ORIG_HEAD"
    STATUS["$REL_PATH"]="Error"
    continue
  fi

  log "→ Tests OK. Commit & Push…"

  if ! { git add . && git commit -m "Dependencies updated" && git pull --rebase && git push; }; then
    log "❌ Git commit/push failed – reverting changes."
    git reset --hard "$ORIG_HEAD"
    STATUS["$REL_PATH"]="Error"
    continue
  fi

  log "✔️ Repo $REL_PATH successfully updated"
  STATUS["$REL_PATH"]="Dependencies updated"
  
  # Track commit SHA for CI checking if enabled
  if [[ "$CHECK_CI_ENABLED" -eq 1 ]]; then
    commit_sha=$(git rev-parse HEAD)
    COMMIT_SHA["$REL_PATH"]="$commit_sha"
    
    # Extract GitHub repo from remote
    remote_url=$(git remote get-url origin 2>/dev/null) || remote_url=""
    
    if github_repo=$(extract_github_repo "$remote_url"); then
      CI_TO_CHECK["$REL_PATH"]="$github_repo"
      CI_STATUS["$REL_PATH"]="CI running"
      CI_TO_CHECK_COUNT=$((CI_TO_CHECK_COUNT + 1))
    else
      # Not a GitHub repo
      CI_STATUS["$REL_PATH"]="No CI"
    fi
  fi
done

log ""
log "========================================"
log "        Summary for all Repos"
log "========================================"

# Initialize CI statuses for repos without updates
for REL_PATH in "${REPOS[@]}"; do
  if [[ -z "${CI_STATUS[$REL_PATH]:-}" ]]; then
    CI_STATUS["$REL_PATH"]="-"
  fi
done

# Print initial summary table
if [[ "$CHECK_CI_ENABLED" -eq 0 ]]; then
  # No CI checking — print table directly (no in-place updates needed)
  print_summary_table 0
else
  # CI checking enabled
  if [[ $CI_TO_CHECK_COUNT -gt 0 ]]; then
    # Wait for GitHub to register new workflow runs before first status check
    log ""
    log "Fetching CI status, please wait..."
    sleep 7
    
    # Initial pass: fetch current CI status for all repos before printing the table.
    # This ensures the first render already shows accurate statuses (passed, No CI, etc.)
    # rather than showing "CI running" for everything.
    for REL_PATH in "${!CI_TO_CHECK[@]}"; do
      owner_repo="${CI_TO_CHECK[$REL_PATH]}"
      sha="${COMMIT_SHA[$REL_PATH]}"
      
      if [[ -z "$owner_repo" ]] || [[ -z "$sha" ]]; then
        continue
      fi
      
      owner="${owner_repo%/*}"
      repo="${owner_repo#*/}"
      
      initial_status=$(determine_ci_status "$owner" "$repo" "$sha" 2>/dev/null) || initial_status="No CI"
      CI_STATUS["$REL_PATH"]="$initial_status"
      
      # Remove from polling set if already in a final state
      if [[ "$initial_status" != "CI running" ]]; then
        unset 'CI_TO_CHECK[$REL_PATH]'
        CI_TO_CHECK_COUNT=$((CI_TO_CHECK_COUNT - 1))
      fi
    done
    
    # Print the table with accurate initial statuses
    printf "\n"  # blank line before table
    tput sc 2>/dev/null || true  # save cursor position at start of table
    print_summary_table "$CHECK_CI_ENABLED" 1
    
    # Continue polling repos still running
    if [[ $CI_TO_CHECK_COUNT -gt 0 ]]; then
      log ""
      log "Waiting for CI results (up to 5 minutes)..."
      poll_all_ci

      log ""
      log "========================================"
      log "        Final Summary with CI Status"
      log "========================================"
      print_summary_table "$CHECK_CI_ENABLED"
    fi
  else
    # No repos needed CI checking at all — print table directly
    printf "\n"
    print_summary_table "$CHECK_CI_ENABLED" 1
  fi
fi

printf "\n✨ Done.\n"
