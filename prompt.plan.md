# Ralph Planning Instructions

Use the **oracle** tool to create a task breakdown for the goal.

## Input

Read the goal from `tasks.md` (or from user input if creating fresh).

## Call Oracle

```
oracle: "Break down this goal into 5-15 small, focused tasks.
Each task should:
- Be completable in one iteration (~15-30 min)
- Have a clear, verifiable outcome
- Include context files to read first
- Include acceptance checks (test commands)
- Specify dependencies on other tasks (if any)

Goal: [the goal]
Codebase context: [any known info about the codebase]"
```

## Output

Update `tasks.md` with the task list. Each task must follow this format:

```markdown
### T001 - <short title>
- Status: [ ] TODO
- Priority: P1
- Depends: <comma-separated task IDs, or empty if no dependencies>
- Outcome: <one line describing expected result>
- Context:
  - `path/to/relevant/file.ts`
- Checks:
  - `npm run typecheck`
  - `npm test`
- Notes:
  - (written by worker after completion)
```

## Task Dependencies

Use the `- Depends:` field to specify which tasks must complete before this one can start:

- **No dependencies**: Leave empty (e.g., `- Depends:`)
- **Single dependency**: `- Depends: T001`
- **Multiple dependencies**: `- Depends: T001, T002` (comma-separated)

Dependencies create a DAG (directed acyclic graph). Ralph will:
1. Only select tasks whose dependencies are all marked `[x]` (complete)
2. Skip tasks with pending dependencies
3. Allow parallel-safe tasks (no shared dependencies) to be candidates

### Dependency Ordering Principles

Follow this general ordering when designing task dependencies:

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: Schema/Types (no dependencies)                    │
│  ├── Database schemas, migrations                           │
│  ├── TypeScript types/interfaces                            │
│  └── API contracts, Zod schemas                             │
├─────────────────────────────────────────────────────────────┤
│  Layer 2: Backend (depends on Layer 1)                      │
│  ├── API endpoints                                          │
│  ├── Business logic                                         │
│  └── Database queries                                       │
├─────────────────────────────────────────────────────────────┤
│  Layer 3: UI Components (depends on Layer 1 or 2)           │
│  ├── Reusable components                                    │
│  ├── Form components                                        │
│  └── Display components                                     │
├─────────────────────────────────────────────────────────────┤
│  Layer 4: Integration (depends on Layer 2 and 3)            │
│  ├── Page/route integration                                 │
│  ├── End-to-end flows                                       │
│  └── Integration tests                                      │
└─────────────────────────────────────────────────────────────┘
```

### Common Dependency Patterns

✅ Good patterns:
- Schema/type tasks should be early (others depend on them)
- API tasks depend on schema tasks
- UI tasks depend on API and component tasks
- Integration/E2E tests depend on feature implementation
- `T001 → T002 → T003` - linear chain
- `T001, T002 (parallel) → T003` - fan-in (T003 depends on both)

```
Example: Feature with parallel work streams

T001 - Add priority schema          (no deps)
T002 - Create PriorityBadge         (Depends: T001)
T003 - Add priority to API          (Depends: T001)
T004 - Add priority filter          (Depends: T002, T003)
T005 - E2E tests for priority       (Depends: T004)
```

❌ Bad patterns:
- Circular: `T001 → T002 → T001` (causes infinite blocking)
- Over-constraining: Every task depends on the previous (prevents parallelism)
- Missing dependencies: Task uses types/APIs that aren't built yet

### Validation

Run `./ralph.sh validate` to check:
- All dependencies reference existing task IDs
- No circular dependencies exist
- Task format is correct

## Task Design Guidelines

✅ Good tasks (small, specific):
- "Add priority column to database schema"
- "Create PriorityBadge component"
- "Add priority filter to API endpoint"

❌ Bad tasks (too vague/large):
- "Implement priority system"
- "Build the dashboard"
- "Add authentication"

## After Planning

1. Run `./ralph.sh validate` to verify task structure
2. Review the dependency graph makes sense
3. Set `- Status: IMPLEMENTING` so Ralph can start executing tasks
