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

Goal: [the goal]
Codebase context: [any known info about the codebase]"
```

## Output

Update `tasks.md` with the task list. Each task must follow this format:

```markdown
### T001 - <short title>
- Status: [ ] TODO
- Priority: P1
- Outcome: <one line describing expected result>
- Context:
  - `path/to/relevant/file.ts`
- Checks:
  - `npm run typecheck`
  - `npm test`
- Notes:
  - (written by worker after completion)
```

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

Set `- Status: IMPLEMENTING` so Ralph can start executing tasks.
