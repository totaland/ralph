#!/bin/bash
# Ralph v2 - Phase-based autonomous AI agent loop
# Usage: ./ralph.sh [max_iterations]
#        ./ralph.sh plan              # Run planning phase only (uses oracle)
#
# Workflow:
#   1. Create tasks.md with your goal (copy from tasks.md.example)
#   2. Run: ./ralph.sh plan           # Oracle creates task breakdown
#   3. Run: ./ralph.sh [max]          # Workers implement tasks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_FILE="$SCRIPT_DIR/tasks.md"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"

# Model configuration (override via environment)
RALPH_MODEL="${RALPH_MODEL:-}"

# Check for plan mode
if [ "${1:-}" = "plan" ]; then
  PLAN_MODE=true
  MAX_ITERATIONS=1
else
  PLAN_MODE=false
  MAX_ITERATIONS=${1:-10}
fi

# ============================================================================
# Helper Functions
# ============================================================================

get_field() {
  local field="$1"
  grep -E "^- ${field}:" "$TASKS_FILE" 2>/dev/null | head -n1 | sed -E "s/^- ${field}:\s*//"
}

get_status() {
  get_field "Status"
}

get_branch() {
  get_field "Branch"
}

set_status() {
  local new="$1"
  local updated="Updated: $(date +%Y-%m-%d)"
  # Update status and timestamp
  perl -0777 -i -pe "s/^- Status:.*$/- Status: $new/m" "$TASKS_FILE"
  perl -0777 -i -pe "s/^- Updated:.*$/- $updated/m" "$TASKS_FILE"
  echo "Status → $new"
}

archive_if_branch_changed() {
  [ -f "$TASKS_FILE" ] || return 0
  
  local current_branch last_branch
  current_branch="$(get_branch || true)"
  last_branch=""
  [ -f "$LAST_BRANCH_FILE" ] && last_branch="$(cat "$LAST_BRANCH_FILE" 2>/dev/null || true)"

  if [ -n "$current_branch" ] && [ -n "$last_branch" ] && [ "$current_branch" != "$last_branch" ]; then
    local date folder_name archive_folder
    date="$(date +%Y-%m-%d)"
    folder_name="$(echo "$last_branch" | sed 's|^ralph/||')"
    archive_folder="$ARCHIVE_DIR/$date-$folder_name"
    
    echo "📦 Archiving previous run: $last_branch"
    mkdir -p "$archive_folder"
    cp "$TASKS_FILE" "$archive_folder/"
    echo "   → $archive_folder"
  fi

  if [ -n "$current_branch" ]; then
    echo "$current_branch" > "$LAST_BRANCH_FILE"
  fi
}

checkout_branch() {
  local branch
  branch="$(get_branch)"
  
  if [ -z "$branch" ]; then
    echo "⚠️  No branch specified in tasks.md"
    return 0
  fi
  
  # Check if we're already on the branch
  local current
  current="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [ "$current" = "$branch" ]; then
    return 0
  fi
  
  # Try to checkout or create the branch
  if git rev-parse --verify "$branch" >/dev/null 2>&1; then
    git checkout "$branch"
  else
    echo "🌿 Creating branch: $branch"
    git checkout -b "$branch"
  fi
}

next_task_id() {
  # Find first task with unchecked status: [ ] TODO
  awk '
    /^### T[0-9]+/ { 
      match($0, /T[0-9]+/)
      task = substr($0, RSTART, RLENGTH)
      in_task = 1
    }
    in_task && /^- Status: \[ \]/ { 
      print task
      exit 
    }
    /^### T[0-9]+/ && task != "" { 
      in_task = 0 
    }
  ' "$TASKS_FILE"
}

extract_task_block() {
  local task="$1"
  awk -v task="$task" '
    $0 ~ "^### " task " " { printing = 1 }
    printing { print }
    printing && /^### T[0-9]+/ && $0 !~ "^### " task " " { exit }
  ' "$TASKS_FILE"
}

count_tasks() {
  grep -c "^### T[0-9]" "$TASKS_FILE" 2>/dev/null || echo "0"
}

count_done() {
  grep -c "^- Status: \[x\]" "$TASKS_FILE" 2>/dev/null || echo "0"
}

run_amp() {
  local prompt_file="${1:-$SCRIPT_DIR/prompt.md}"
  local model_arg=""
  
  # Use model if specified
  if [ -n "${RALPH_MODEL:-}" ]; then
    model_arg="--model $RALPH_MODEL"
  fi
  
  # shellcheck disable=SC2086
  local output
  output=$(cat "$prompt_file" | amp --dangerously-allow-all $model_arg 2>&1 | tee /dev/stderr) || true
  
  # Check for completion signal
  if echo "$output" | grep -q "<promise>COMPLETE</promise>"; then
    return 42  # Special exit code for complete
  fi
  
  return 0
}

print_header() {
  local phase="$1"
  local iteration="$2"
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Ralph v2 │ Phase: $phase │ Iteration $iteration/$MAX_ITERATIONS"
  echo "═══════════════════════════════════════════════════════════════"
}

# ============================================================================
# Main Loop
# ============================================================================

# Preflight checks
if [ ! -f "$TASKS_FILE" ]; then
  echo "❌ Missing tasks.md"
  echo ""
  echo "Create tasks.md with:"
  echo "  - Goal: <your goal>"
  echo "  - Branch: ralph/<feature>"
  echo "  - Status: DISCOVERY_PENDING"
  echo ""
  echo "Or copy from tasks.md.example"
  exit 1
fi

archive_if_branch_changed
checkout_branch

# Plan mode - run oracle once and exit
if [ "$PLAN_MODE" = true ]; then
  echo ""
  echo "🤖 Ralph Planning Mode"
  echo "   Using oracle to create task breakdown..."
  echo ""
  print_header "PLANNING (oracle)" "1"
  run_amp "$SCRIPT_DIR/prompt.plan.md"
  echo ""
  echo "✅ Planning complete. Review tasks.md, then run: ./ralph.sh"
  exit 0
fi

echo ""
echo "🤖 Starting Ralph v2"
echo "   Max iterations: $MAX_ITERATIONS"
echo "   Tasks file: $TASKS_FILE"
echo ""

for i in $(seq 1 "$MAX_ITERATIONS"); do
  status="$(get_status)"
  
  # Check status
  case "$status" in
    PLANNING_PENDING)
      echo "⚠️  Tasks not planned yet. Run: ./ralph.sh plan"
      exit 1
      ;;
    IMPLEMENTING)
      task="$(next_task_id || true)"
      if [ -z "${task:-}" ]; then
        set_status "COMPLETE"
        echo ""
        echo "✅ All tasks complete!"
        echo "<promise>COMPLETE</promise>"
        exit 0
      fi
      total="$(count_tasks)"
      done_count="$(count_done)"
      phase_label="WORKER ($task) [$done_count/$total done]"
      ;;
    COMPLETE)
      echo "✅ Already complete. Nothing to do."
      exit 0
      ;;
    *)
      echo "❌ Unknown status: $status"
      echo "   Expected: IMPLEMENTING or COMPLETE"
      echo "   Run: ./ralph.sh plan"
      exit 1
      ;;
  esac
  
  print_header "$phase_label" "$i"
  
  if run_amp; then
    : # Normal completion, continue loop
  else
    exit_code=$?
    if [ "$exit_code" -eq 42 ]; then
      echo ""
      echo "✅ Ralph completed all tasks!"
      exit 0
    fi
  fi
done

echo ""
echo "⚠️  Reached max iterations ($MAX_ITERATIONS) without completing all tasks."
total="$(count_tasks)"
done="$(count_done)"
echo "   Progress: $done/$total tasks complete"
echo "   Check $TASKS_FILE for status."
exit 1
