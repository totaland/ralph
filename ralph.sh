#!/bin/bash
# Ralph v2 - Phase-based autonomous AI agent loop
# Usage: ./ralph.sh [max_iterations]
#        ./ralph.sh plan              # Run planning phase only (uses oracle)
#        ./ralph.sh validate          # Validate tasks.md structure
#        ./ralph.sh status            # Show progress summary
#
# Workflow:
#   1. Create tasks.md with your goal (copy from tasks.md.example)
#   2. Run: ./ralph.sh plan           # Oracle creates task breakdown
#   3. Run: ./ralph.sh validate       # Check tasks.md is valid
#   4. Run: ./ralph.sh [max]          # Workers implement tasks
#   5. Run: ./ralph.sh status         # Check progress anytime

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_FILE="$SCRIPT_DIR/tasks.md"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
LOCK_DIR="$SCRIPT_DIR/.ralph/locks"
ITERATION_LOG_DIR="$SCRIPT_DIR/.ralph/iteration-logs"

# Execution history
HISTORY_DIR="$SCRIPT_DIR/.ralph/history"
ITERATION_LOG="$HISTORY_DIR/$(date +%Y-%m-%d).jsonl"

# Capture the most recent Amp output for debugging
LAST_ITERATION_OUTPUT="$SCRIPT_DIR/.iteration-log.txt"

# Special exit code for COMPLETE signal
AMP_COMPLETE_EXIT=42

# Model configuration (override via environment)
RALPH_MODEL="${RALPH_MODEL:-}"

# Retry configuration (Phase 2)
RALPH_MAX_RETRIES="${RALPH_MAX_RETRIES:-2}"
RALPH_RETRY_DELAY="${RALPH_RETRY_DELAY:-30}"
RALPH_MAX_PARALLEL="${RALPH_MAX_PARALLEL:-0}"

# Check for command mode
case "${1:-}" in
  plan)
    PLAN_MODE=true
    MAX_ITERATIONS=1
    ;;
  validate)
    VALIDATE_MODE=true
    ;;
  status)
    STATUS_MODE=true
    ;;
  help|--help|-h)
    echo "Ralph v2 - Phase-based autonomous AI agent loop"
    echo ""
    echo "Usage:"
    echo "  ./ralph.sh              Run worker iterations (default: 10)"
    echo "  ./ralph.sh [max]        Run up to [max] iterations"
    echo "  ./ralph.sh plan         Run oracle to create task breakdown"
    echo "  ./ralph.sh validate     Validate tasks.md structure"
    echo "  ./ralph.sh status       Show progress dashboard"
    echo "  ./ralph.sh help         Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  RALPH_MODEL             Override the model (e.g., claude-sonnet)"
    echo "  RALPH_MAX_RETRIES       Max retry attempts (default: 2)"
    echo "  RALPH_RETRY_DELAY       Base delay in seconds (default: 30)"
    echo "  RALPH_MAX_PARALLEL      Cap parallel workers (0 = no cap)"
    exit 0
    ;;
  *)
    PLAN_MODE=false
    MAX_ITERATIONS=${1:-10}
    ;;
esac

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

# ============================================================================
# Logging Functions
# ============================================================================

log_iteration() {
  local task_id="$1"
  local iteration="$2"
  local duration="${3:-0}"
  local exit_code="${4:-0}"
  
  # Ensure history directory exists
  mkdir -p "$HISTORY_DIR"
  
  local timestamp branch git_head
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  branch="$(get_branch || echo "")"
  git_head="$(git rev-parse --short HEAD 2>/dev/null || echo "none")"
  
  # Append JSONL log entry
  printf '{"timestamp":"%s","iteration":%d,"task":"%s","duration_sec":%d,"exit_code":%d,"branch":"%s","git_head":"%s"}\n' \
    "$timestamp" "$iteration" "$task_id" "$duration" "$exit_code" "$branch" "$git_head" \
    >> "$ITERATION_LOG"
}

# ============================================================================
# Dependency Functions
# ============================================================================

get_task_depends() {
  local task="$1"
  # Extract Depends field from a specific task block
  awk -v task="$task" '
    $0 ~ "^### " task " " { in_task = 1; next }
    in_task && /^- Depends:/ {
      sub(/^- Depends:[[:space:]]*/, "")
      gsub(/,/, " ")
      gsub(/[[:space:]]+/, " ")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      # Normalize common "no dependency" markers
      if (tolower($0) == "(none)" || tolower($0) == "none" || $0 == "-") {
        print ""
      } else {
        print $0
      }
      exit
    }
    in_task && /^### T[0-9]+/ { exit }
  ' "$TASKS_FILE"
}

is_task_ready() {
  local task="$1"
  local depends
  depends="$(get_task_depends "$task")"
  
  # No dependencies = ready
  [ -z "$depends" ] && return 0
  
  # Check each dependency is complete
  for dep in $depends; do
    local dep_status
    dep_status=$(awk -v task="$dep" '
      $0 ~ "^### " task " " { in_task = 1; next }
      in_task && /^- Status: \[x\]/ { print "done"; exit }
      in_task && /^- Status: \[ \]/ { print "pending"; exit }
      in_task && /^### T[0-9]+/ { exit }
    ' "$TASKS_FILE")
    
    # If dependency is missing, treat as not ready.
    if [ "$dep_status" != "done" ]; then
      return 1  # Dependency not complete
    fi
  done
  
  return 0  # All dependencies satisfied
}

next_task_id() {
  # Find the first TODO task whose dependencies are satisfied.
  # If TODO tasks exist but none are ready, echo BLOCKED.
  local had_todos=false
  local todos
  todos=$(awk '
    /^### T[0-9]+/ {
      match($0, /T[0-9]+/)
      task = substr($0, RSTART, RLENGTH)
      in_task = 1
      next
    }
    in_task && /^- Status: \[ \]/ {
      print task
      next
    }
    /^### T[0-9]+/ { in_task = 0 }
  ' "$TASKS_FILE")

  if [ -n "$todos" ]; then
    had_todos=true
  fi

  while IFS= read -r task; do
    [ -n "$task" ] || continue
    if is_task_ready "$task"; then
      echo "$task"
      return 0
    fi
  done <<< "$todos"

  if [ "$had_todos" = true ]; then
    echo "BLOCKED"
    return 0
  fi

  echo ""
  return 0
}

list_todo_tasks() {
  awk '
    /^### T[0-9]+/ {
      match($0, /T[0-9]+/)
      task = substr($0, RSTART, RLENGTH)
      in_task = 1
      next
    }
    in_task && /^- Status: \[ \]/ {
      print task
      in_task = 0
      next
    }
    /^### T[0-9]+/ { in_task = 0 }
  ' "$TASKS_FILE"
}

list_ready_tasks() {
  local todos
  todos="$(list_todo_tasks)"

  while IFS= read -r task; do
    [ -z "$task" ] && continue
    if is_task_ready "$task"; then
      echo "$task"
    fi
  done <<< "$todos"
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
  local count
  count=$(grep -c "^### T[0-9]" "$TASKS_FILE" 2>/dev/null) || true
  echo "${count:-0}"
}

count_done() {
  local count
  count=$(grep -c "^- Status: \[x\]" "$TASKS_FILE" 2>/dev/null) || true
  echo "${count:-0}"
}

# ============================================================================
# Validation Functions (T006)
# ============================================================================

get_all_task_ids() {
  grep -oE "^### T[0-9]+" "$TASKS_FILE" 2>/dev/null | sed 's/^### //' | sort -u
}

validate_tasks() {
  local errors=()
  local warnings=()
  
  echo "🔍 Validating tasks.md..."
  echo ""
  
  # Check 1: File exists
  if [ ! -f "$TASKS_FILE" ]; then
    echo "❌ Validation failed: tasks.md not found"
    echo "   Expected at: $TASKS_FILE"
    return 1
  fi
  echo "✓ File exists"
  
  # Check 2: Get all task IDs
  local all_ids
  all_ids="$(get_all_task_ids)"
  
  if [ -z "$all_ids" ]; then
    echo "⚠️  No tasks found in tasks.md"
    echo "   Run: ./ralph.sh plan"
    return 0
  fi
  
  local task_count
  task_count=$(echo "$all_ids" | wc -l | tr -d ' ')
  echo "✓ Found $task_count tasks"
  
  # Check 3: Validate task ID uniqueness
  local duplicate_ids
  duplicate_ids=$(grep -oE "^### T[0-9]+" "$TASKS_FILE" 2>/dev/null | sed 's/^### //' | sort | uniq -d)
  
  if [ -n "$duplicate_ids" ]; then
    echo ""
    echo "❌ Duplicate task IDs found:"
    while IFS= read -r dup_id; do
      [ -n "$dup_id" ] && echo "   - $dup_id"
    done <<< "$duplicate_ids"
    errors+=("Duplicate task IDs")
  else
    echo "✓ All task IDs are unique"
  fi
  
  # Check 4: Validate each task has required fields
  local missing_fields=false
  while IFS= read -r task_id; do
    [ -z "$task_id" ] && continue
    
    local task_block
    task_block="$(extract_task_block "$task_id")"
    
    # Check for Status field
    if ! echo "$task_block" | grep -qE "^- Status:"; then
      errors+=("$task_id: Missing '- Status:' field")
      missing_fields=true
    elif ! echo "$task_block" | grep -qE "^- Status: \[(x| )\]"; then
      errors+=("$task_id: Status must be '[ ]' or '[x]'")
      missing_fields=true
    fi
    
    # Check for Depends field (required but can be empty)
    if ! echo "$task_block" | grep -qE "^- Depends:"; then
      warnings+=("$task_id: Missing '- Depends:' field")
    fi
  done <<< "$all_ids"
  
  if [ "$missing_fields" = false ]; then
    echo "✓ Required fields present in all tasks"
  fi
  
  # Check 5: Validate dependency references exist
  local invalid_deps=false
  while IFS= read -r task_id; do
    [ -z "$task_id" ] && continue
    
    local deps
    deps="$(get_task_depends "$task_id")"
    
    for dep in $deps; do
      [ -z "$dep" ] && continue
      
      # Check if referenced task exists
      if ! echo "$all_ids" | grep -qx "$dep"; then
        errors+=("$task_id: Depends on '$dep' which does not exist")
        invalid_deps=true
      fi
      
      # Check for self-dependency
      if [ "$dep" = "$task_id" ]; then
        errors+=("$task_id: Cannot depend on itself")
        invalid_deps=true
      fi
    done
  done <<< "$all_ids"
  
  if [ "$invalid_deps" = false ]; then
    echo "✓ All dependency references are valid"
  fi
  
  # Check 6: Detect circular dependencies using DFS (bash 3.2 compatible)
  local visited=""
  local rec_stack=""
  local cycle_found=false
  local cycle_path=""
  
  has_cycle() {
    local node="$1"
    local path="$2"
    
    # Check if node is in current recursion stack (cycle detected)
    if echo " $rec_stack " | grep -qw "$node"; then
      cycle_path="$path -> $node (cycle back)"
      return 0  # Has cycle
    fi
    
    # Check if already fully visited
    if echo " $visited " | grep -qw "$node"; then
      return 1  # No cycle through this node
    fi
    
    # Add to recursion stack
    rec_stack="$rec_stack $node"
    
    # Visit all dependencies
    local deps
    deps="$(get_task_depends "$node")"
    for dep in $deps; do
      [ -z "$dep" ] && continue
      # Skip non-existent deps
      if ! echo "$all_ids" | grep -qx "$dep"; then
        continue
      fi
      if has_cycle "$dep" "$path -> $node"; then
        return 0  # Cycle found
      fi
    done
    
    # Remove from recursion stack, add to visited
    rec_stack=$(echo "$rec_stack" | sed "s/ $node//")
    visited="$visited $node"
    
    return 1  # No cycle
  }
  
  while IFS= read -r task_id; do
    [ -z "$task_id" ] && continue
    if ! echo " $visited " | grep -qw "$task_id"; then
      if has_cycle "$task_id" ""; then
        cycle_found=true
        break
      fi
    fi
  done <<< "$all_ids"
  
  if [ "$cycle_found" = true ]; then
    errors+=("Circular dependency detected: $cycle_path")
  else
    echo "✓ No circular dependencies"
  fi
  
  # Report warnings
  if [ ${#warnings[@]} -gt 0 ]; then
    echo ""
    echo "⚠️  Warnings:"
    for warn in "${warnings[@]}"; do
      echo "   $warn"
    done
  fi
  
  # Report errors
  if [ ${#errors[@]} -gt 0 ]; then
    echo ""
    echo "❌ Validation failed with ${#errors[@]} error(s):"
    for err in "${errors[@]}"; do
      echo "   • $err"
    done
    echo ""
    return 1
  fi
  
  echo ""
  echo "✅ Validation passed: $task_count tasks verified"
  return 0
}

# ============================================================================
# Status Functions (T007)
# ============================================================================

count_ready() {
  local ready_count
  ready_count=$(list_ready_tasks | wc -l | tr -d ' ')
  echo "${ready_count:-0}"
}

count_blocked() {
  local blocked_count=0
  local todos
  todos=$(awk '
    /^### T[0-9]+/ {
      match($0, /T[0-9]+/)
      task = substr($0, RSTART, RLENGTH)
      in_task = 1
      next
    }
    in_task && /^- Status: \[ \]/ {
      print task
      in_task = 0
      next
    }
    /^### T[0-9]+/ { in_task = 0 }
  ' "$TASKS_FILE")
  
  while IFS= read -r task; do
    [ -z "$task" ] && continue
    if ! is_task_ready "$task"; then
      blocked_count=$((blocked_count + 1))
    fi
  done <<< "$todos"
  
  echo "$blocked_count"
}

get_task_title() {
  local task="$1"
  awk -v task="$task" '
    $0 ~ "^### " task " - " {
      sub(/^### T[0-9]+ - /, "")
      print
      exit
    }
  ' "$TASKS_FILE"
}

progress_bar() {
  local done="$1"
  local total="$2"
  local width="${3:-20}"
  
  if [ "$total" -eq 0 ]; then
    printf '%*s' "$width" '' | tr ' ' '░'
    return
  fi
  
  local filled=$((done * width / total))
  local empty=$((width - filled))
  
  printf '%*s' "$filled" '' | tr ' ' '█'
  printf '%*s' "$empty" '' | tr ' ' '░'
}

show_status() {
  # Check file exists
  if [ ! -f "$TASKS_FILE" ]; then
    echo "❌ tasks.md not found"
    echo "   Create one or copy from tasks.md.example"
    return 1
  fi
  
  # Get overall project status
  local project_status
  project_status="$(get_status)"
  
  # Get counts
  local total done_count ready_count blocked_count
  total="$(count_tasks)"
  done_count="$(count_done)"
  ready_count="$(count_ready)"
  blocked_count="$(count_blocked)"
  
  # Calculate percentage
  local pct=0
  if [ "$total" -gt 0 ]; then
    pct=$((done_count * 100 / total))
  fi
  
  # Get next task info
  local next_task next_title
  next_task="$(next_task_id)"
  if [ -n "$next_task" ] && [ "$next_task" != "BLOCKED" ]; then
    next_title="$(get_task_title "$next_task")"
  fi
  
  # Get branch info
  local branch
  branch="$(get_branch || echo "none")"
  
  # Print header
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Ralph Status"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
  
  # Project info
  echo "📁 Branch: $branch"
  echo "📋 Status: $project_status"
  echo ""
  
  # Progress bar
  echo "📊 Progress: $done_count/$total tasks ($pct%)"
  printf "  "
  progress_bar "$done_count" "$total" 20
  echo ""
  echo ""
  
  # Counts with icons
  echo "✅ Completed: $done_count"
  echo "⏳ Ready:     $ready_count"
  echo "🚫 Blocked:   $blocked_count"
  echo ""
  
  # Next task
  if [ "$project_status" = "COMPLETE" ]; then
    echo "🎉 All tasks complete!"
  elif [ "$project_status" = "PLANNING_PENDING" ]; then
    echo "📝 Run: ./ralph.sh plan"
  elif [ "$next_task" = "BLOCKED" ]; then
    echo "⛔️  All remaining tasks are blocked"
    echo "   Check dependencies and ensure prerequisite tasks are marked [x]"
  elif [ -n "$next_task" ]; then
    echo "▶️  Next task: $next_task - $next_title"
  else
    echo "✨ No pending tasks"
  fi
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
  
  return 0
}

run_amp() {
  local prompt_file="${1:-$SCRIPT_DIR/prompt.md}"
  local output_file="${2:-$LAST_ITERATION_OUTPUT}"
  local model_args=()

  # Use model if specified
  if [ -n "${RALPH_MODEL:-}" ]; then
    model_args=(--model "$RALPH_MODEL")
  fi

  : > "$output_file"

  set +e
  amp --dangerously-allow-all "${model_args[@]}" < "$prompt_file" 2>&1 | tee "$output_file"
  local amp_exit="${PIPESTATUS[0]:-1}"
  set -e

  # Check for completion signal
  if grep -q "<promise>COMPLETE</promise>" "$output_file"; then
    return "$AMP_COMPLETE_EXIT"
  fi

  return "$amp_exit"
}

run_with_retry() {
  local prompt_file="${1:-$SCRIPT_DIR/prompt.md}"
  local task_id="${2:-planning}"
  local iteration="${3:-0}"
  local output_file="${4:-$LAST_ITERATION_OUTPUT}"

  local max_retries="$RALPH_MAX_RETRIES"
  local base_delay="$RALPH_RETRY_DELAY"

  if ! [[ "$max_retries" =~ ^[0-9]+$ ]]; then
    echo "⚠️  Invalid RALPH_MAX_RETRIES='$max_retries', using default 2"
    max_retries=2
  fi
  if ! [[ "$base_delay" =~ ^[0-9]+$ ]]; then
    echo "⚠️  Invalid RALPH_RETRY_DELAY='$base_delay', using default 30"
    base_delay=30
  fi

  local attempt=1
  local max_attempts=$((max_retries + 1))
  local exit_code=0

  while [ "$attempt" -le "$max_attempts" ]; do
    local start_time end_time duration
    start_time=$(date +%s)

    set +e
    run_amp "$prompt_file" "$output_file"
    exit_code=$?
    set -e

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    local log_task_id="$task_id"
    if [ "$attempt" -gt 1 ]; then
      log_task_id="${task_id}_retry_$((attempt - 1))"
    fi
    log_iteration "$log_task_id" "$iteration" "$duration" "$exit_code"

    if [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq "$AMP_COMPLETE_EXIT" ]; then
      return "$exit_code"
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      echo ""
      echo "❌ Max retries ($max_retries) exhausted"
      echo "   Last exit code: $exit_code"
      echo "   See: $output_file"
      return "$exit_code"
    fi

    local exp=$((attempt - 1))
    local delay=$((base_delay * (1 << exp)))

    echo ""
    echo "🔁 Attempt $attempt failed (exit $exit_code)."
    echo "   Retrying in ${delay}s... (attempt $((attempt + 1))/$max_attempts)"
    sleep "$delay"

    attempt=$((attempt + 1))
  done

  return "$exit_code"
}

make_worker_prompt() {
  local task_id="$1"
  local prompt_file
  prompt_file="$(mktemp "$SCRIPT_DIR/.ralph/prompt.${task_id}.XXXXXX")"
  cat "$SCRIPT_DIR/prompt.md" > "$prompt_file"
  {
    echo ""
    echo "Assigned Task: $task_id"
  } >> "$prompt_file"
  echo "$prompt_file"
}

run_worker_task() {
  local task_id="$1"
  local iteration="$2"
  local prompt_file
  local output_file
  local exit_code=0

  prompt_file="$(make_worker_prompt "$task_id")"
  output_file="$ITERATION_LOG_DIR/${task_id}_iter_${iteration}.log"

  set +e
  run_with_retry "$prompt_file" "$task_id" "$iteration" "$output_file"
  exit_code=$?
  set -e

  rm -f "$prompt_file"
  rm -f "$LOCK_DIR/$task_id"

  return "$exit_code"
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

# Validate mode - check tasks.md structure and exit (before preflight)
if [ "${VALIDATE_MODE:-}" = true ]; then
  validate_tasks
  exit $?
fi

# Status mode - show progress summary and exit (before preflight)
if [ "${STATUS_MODE:-}" = true ]; then
  show_status
  exit $?
fi

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

# Ensure execution history directory exists (T001)
mkdir -p "$HISTORY_DIR"
mkdir -p "$LOCK_DIR"
mkdir -p "$ITERATION_LOG_DIR"

archive_if_branch_changed
checkout_branch

# Plan mode - run oracle once and exit
if [ "${PLAN_MODE:-}" = true ]; then
  echo ""
  echo "🤖 Ralph Planning Mode"
  echo "   Using oracle to create task breakdown..."
  echo ""
  print_header "PLANNING (oracle)" "1"

  set +e
  run_with_retry "$SCRIPT_DIR/prompt.plan.md" "planning" "1"
  exit_code=$?
  set -e

  if [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq "$AMP_COMPLETE_EXIT" ]; then
    echo ""
    echo "✅ Planning complete. Review tasks.md, then run: ./ralph.sh"
    exit 0
  fi

  echo ""
  echo "❌ Planning failed after retries (exit_code=$exit_code)."
  echo "   See: $LAST_ITERATION_OUTPUT"
  exit 1
fi

echo ""
echo "🤖 Starting Ralph v2"
echo "   Max iterations: $MAX_ITERATIONS"
echo "   Tasks file: $TASKS_FILE"
echo "   Retry config: max=$RALPH_MAX_RETRIES, base_delay=${RALPH_RETRY_DELAY}s"
echo "   Parallel cap: ${RALPH_MAX_PARALLEL:-0}"
echo ""

iteration=0
while [ "$iteration" -lt "$MAX_ITERATIONS" ]; do
  status="$(get_status)"
  
  # Check status
  case "$status" in
    PLANNING_PENDING)
      echo "⚠️  Tasks not planned yet. Run: ./ralph.sh plan"
      exit 1
      ;;
    IMPLEMENTING)
      ready_tasks="$(list_ready_tasks || true)"
      todos="$(list_todo_tasks || true)"
      if [ -n "$todos" ] && [ -z "$ready_tasks" ]; then
        echo ""
        echo "⛔️  BLOCKED: TODO tasks exist but dependencies are not satisfied."
        echo "   Check the '- Depends:' fields and ensure prerequisite tasks are marked [x]."
        log_iteration "BLOCKED" "$iteration" 0 1
        exit 1
      fi
      if [ -z "${todos:-}" ]; then
        set_status "COMPLETE"
        echo ""
        echo "✅ All tasks complete!"
        echo "<promise>COMPLETE</promise>"
        exit 0
      fi
      total="$(count_tasks)"
      done_count="$(count_done)"
      phase_label="WORKER (batch) [$done_count/$total done]"
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
  
  print_header "$phase_label" "$((iteration + 1))"

  mapfile -t ready_array <<< "$ready_tasks"
  available=$((MAX_ITERATIONS - iteration))
  parallel_cap="$RALPH_MAX_PARALLEL"
  if ! [[ "$parallel_cap" =~ ^[0-9]+$ ]]; then
    echo "⚠️  Invalid RALPH_MAX_PARALLEL='$parallel_cap', using 0 (no cap)"
    parallel_cap=0
  fi
  if [ "$parallel_cap" -gt 0 ] && [ "$parallel_cap" -lt "$available" ]; then
    available="$parallel_cap"
  fi

  batch_tasks=()
  for task in "${ready_array[@]}"; do
    [ -n "$task" ] || continue
    if [ "$available" -le 0 ]; then
      break
    fi
    if [ ! -f "$LOCK_DIR/$task" ]; then
      : > "$LOCK_DIR/$task"
      batch_tasks+=("$task")
      available=$((available - 1))
    fi
  done

  if [ "${#batch_tasks[@]}" -eq 0 ]; then
    echo ""
    echo "⚠️  No available tasks to run (all ready tasks are locked)."
    exit 1
  fi

  echo "🚀 Running batch: ${batch_tasks[*]}"

  pids=()
  task_ids=()
  task_iters=()
  exit_codes=()
  complete_signal=false
  failed=false

  for task in "${batch_tasks[@]}"; do
    iteration=$((iteration + 1))
    run_worker_task "$task" "$iteration" &
    pids+=("$!")
    task_ids+=("$task")
    task_iters+=("$iteration")
  done

  for index in "${!pids[@]}"; do
    pid="${pids[$index]}"
    task_id="${task_ids[$index]}"
    task_iter="${task_iters[$index]}"
    set +e
    wait "$pid"
    exit_code=$?
    set -e
    exit_codes+=("$exit_code")

    if [ "$exit_code" -eq "$AMP_COMPLETE_EXIT" ]; then
      complete_signal=true
    elif [ "$exit_code" -ne 0 ]; then
      failed=true
      echo ""
      echo "❌ Amp run failed for $task_id (exit_code=$exit_code)."
      echo "   See: $ITERATION_LOG_DIR/${task_id}_iter_${task_iter}.log"
    fi
  done

  if [ "$failed" = true ]; then
    exit 1
  fi

  if [ "$complete_signal" = true ]; then
    echo ""
    echo "✅ Ralph completed all tasks!"
    exit 0
  fi
done

echo ""
echo "⚠️  Reached max iterations ($MAX_ITERATIONS) without completing all tasks."
total="$(count_tasks)"
done="$(count_done)"
echo "   Progress: $done/$total tasks complete"
echo "   Check $TASKS_FILE for status."
exit 1
