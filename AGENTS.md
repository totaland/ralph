# Ralph Agent Instructions

## Overview

Ralph v2 is a phase-based autonomous AI agent loop that runs Amp repeatedly until all tasks are complete. Each iteration is a fresh Amp instance with clean context.

## Architecture

Three-phase system:
1. **Librarian** - Discovers codebase structure, writes Codebase Map
2. **Oracle** - Breaks goal into small tasks with context pointers
3. **Worker** - Implements one task per iteration, writes notes for next

## Commands

```bash
# Plan tasks (run oracle to break down goal)
./ralph.sh plan

# Run workers (implement tasks one at a time)
./ralph.sh [max_iterations]

# Run the flowchart dev server
cd flowchart && npm run dev

# Build the flowchart
cd flowchart && npm run build
```

## Key Files

- `ralph.sh` - Phase-based bash loop
- `tasks.md` - Single source of truth (goal, map, tasks, notes)
- `tasks.md.example` - Template to copy
- `prompt.md` - Worker prompt (uses librarian for context)
- `prompt.plan.md` - Planning prompt (uses oracle)
- `flowchart/` - Interactive React Flow diagram

## Status Flow

```
PLANNING_PENDING → IMPLEMENTING → COMPLETE
   (oracle)         (worker)
```

## Model Configuration

Override via environment:
```bash
export RALPH_MODEL="claude-sonnet"
```

## Patterns

- Single prompt uses Amp's built-in `librarian` and `oracle` tools
- Each iteration spawns a fresh Amp instance with clean context
- Memory persists via git history and `tasks.md`
- Tasks should be small enough to complete in one context window
- Workers write findings/context for next iteration in task Notes
- Context pointers in each task reduce token usage
