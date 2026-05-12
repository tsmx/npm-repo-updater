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
  
  # Handle HTTPS: https://github.com/owner/repo.git
  if [[ $remote_url =~ https://github\.com/([^/]+)/(.+?)(?:\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
    return 0
  fi
  
  # Handle SSH: git@github.com:owner/repo.git
  if [[ $remote_url =~ git@github\.com:([^/]+)/(.+?)(?:\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
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
  
  if [[ "$show_ci" -eq 1 ]]; then
    printf "\n%-40s | %-25s | %s\n" "Repository" "Dependencies" "CI Status"
    printf "%-40s-+-%-25s-+-%s\n" "----------------------------------------" "-------------------------" "---------------------"
  else
    printf "\n%-40s | %s\n" "Repository" "Status"
    printf "%-40s-+-%s\n" "----------------------------------------" "-------------------------"
  fi
  
  for REL_PATH in "${REPOS[@]}"; do
    local dep_status="${STATUS[$REL_PATH]}"
    local ci_status="${CI_STATUS[$REL_PATH]:-}"
    
    if [[ "$show_ci" -eq 1 ]]; then
      # Color code: red for Error or CI failed, normal for others
      if [[ "$dep_status" == "Error" ]] || [[ "$ci_status" == "CI failed" ]]; then
        printf "%-40s | ${RED}%-25s${NC} | ${RED}%s${NC}\n" "$REL_PATH" "$dep_status" "$ci_status"
      else
        printf "%-40s | %-25s | %s\n" "$REL_PATH" "$dep_status" "$ci_status"
      fi
    else
      # Original single column format
      if [[ "$dep_status" == "Error" ]]; then
        printf "%-40s | ${RED}%s${NC}\n" "$REL_PATH" "$dep_status"
      else
        printf "%-40s | %s\n" "$REL_PATH" "$dep_status"
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

# Main CI polling loop (non-blocking background)
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
      local owner_repo="${CI_TO_CHECK[$REL_PATH]}"
      local sha="${COMMIT_SHA[$REL_PATH]}"
      
      if [[ -z "$owner_repo" ]] || [[ -z "$sha" ]]; then
        continue
      fi
      
      local owner="${owner_repo%/*}"
      local repo="${owner_repo#*/}"
      
      # Query CI status
      local new_status
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
    
    # Redraw table with updated statuses
    print_summary_table "$CHECK_CI_ENABLED"
    
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
print_summary_table "$CHECK_CI_ENABLED"

# If CI checking is enabled, poll for results
if [[ "$CHECK_CI_ENABLED" -eq 1 ]] && [[ ${#CI_TO_CHECK[@]} -gt 0 ]]; then
  log ""
  log "Waiting for CI results (up to 5 minutes)..."
  
  # Wait 5-10 seconds for GitHub to create workflows
  sleep 7
  
  # Initial pass: detect "No CI" immediately for repos with no workflows
  for REL_PATH in "${!CI_TO_CHECK[@]}"; do
    local owner_repo="${CI_TO_CHECK[$REL_PATH]}"
    local sha="${COMMIT_SHA[$REL_PATH]}"
    
    if [[ -z "$owner_repo" ]] || [[ -z "$sha" ]]; then
      continue
    fi
    
    local owner="${owner_repo%/*}"
    local repo="${owner_repo#*/}"
    
    # Quick check: if no workflows exist, mark immediately
    local initial_status
    initial_status=$(determine_ci_status "$owner" "$repo" "$sha" 2>/dev/null) || initial_status="No CI"
    
    if [[ "$initial_status" == "No CI" ]]; then
      CI_STATUS["$REL_PATH"]="No CI"
      unset 'CI_TO_CHECK[$REL_PATH]'
    fi
  done
  
  # Poll remaining repos
  if [[ ${#CI_TO_CHECK[@]} -gt 0 ]]; then
    poll_all_ci
  fi
  
  log ""
  log "========================================"
  log "        Final Summary with CI Status"
  log "========================================"
  print_summary_table "$CHECK_CI_ENABLED"
else
  # No CI checking, use original format
  printf "\n%-40s | %s\n" "Repository" "Status"
  printf "%-40s-+-%s\n" "----------------------------------------" "-------------------------"
  
  for REL_PATH in "${REPOS[@]}"; do
    if [[ "${STATUS[$REL_PATH]}" == "Error" ]]; then
      printf "%-40s | ${RED}%s${NC}\n" "$REL_PATH" "${STATUS[$REL_PATH]}"
    else
      printf "%-40s | %s\n" "$REL_PATH" "${STATUS[$REL_PATH]}"
    fi
  done
fi

printf "\n✨ Done.\n"
