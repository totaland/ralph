# Ralph Worker Instructions

You are an autonomous coding agent implementing tasks from `tasks.md`.

## Workflow

1. Read `tasks.md` - find the first task with `- Status: [ ] TODO`
2. Read the **Context** files listed in that task
3. Implement the **Outcome**
4. Run all **Checks** listed
5. If checks pass, commit: `feat: [TaskID] - [Title]`
6. Use **librarian** to analyze what you did and update the task's Notes section
7. Mark the task as done

## Using Librarian for Context

After implementing, call librarian to help document:

```
librarian: "I just completed [task]. Analyze what changed and help me write:
1. What files were modified and why
2. Key patterns or gotchas discovered
3. What context/files the next task should know about"
```

Then update the task's Notes section in `tasks.md`:

```markdown
- Notes:
  - Thread: $AMP_CURRENT_THREAD_ID
  - Changed: <1-2 line summary>
  - Files: `path/to/file.ts`, `path/to/other.ts`
  - Findings: <patterns, gotchas for future tasks>
  - Next context: <files/info relevant for next task>
```

## Marking Done

Change `- Status: [ ] TODO` → `- Status: [x] DONE`

## Completion Check

After marking your task DONE, check if ALL tasks are `[x] DONE`.

If ALL complete:
```
<promise>COMPLETE</promise>
```

Otherwise, end normally (next iteration picks up next task).

## Rules

- Work on ONE task per iteration
- Keep changes minimal and focused
- Follow existing code patterns
- Commit only if checks pass
- Always use librarian to write context notes

## Browser Testing

If the task requires browser verification:
1. Load the `agent-browser` skill
2. Navigate and verify the UI
3. Include result in Notes
