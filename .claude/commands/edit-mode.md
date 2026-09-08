---
description: "Exit ask-only/read-only mode and restore full read-write agent capabilities."
argument-hint: "[optional: task to continue or start now that edit mode is active]"
tools:
  - GlobTool
  - GrepTool
  - FileReadTool
  - FileEditTool
  - LS
  - Bash
  - WebSearch
  - WebFetch
  - TodoWrite
  - Task
---

# Edit Mode

You are exiting **ask-only mode**. Any prior restriction to read-only tools or read-only commands from an `ask-mode` or `diagnose` session no longer applies.

## Rules

- You may create, edit, delete, rename, or move files in the working tree as needed.
- You may run commands that modify state (installs, formatters/linters with `--fix`/`--write`, `git add`/`commit`, etc.), subject to the standard operational-safety rules (confirm before destructive/hard-to-reverse actions like force-push, `git reset --hard`, or dropping data).
- Continue using the context, findings, and decisions already established earlier in this conversation — do not re-investigate from scratch unless something has changed.

## Steps

1. Confirm edit mode is active and briefly note any relevant context/decisions carried over from the prior discussion.
2. If the user provided a task in $ARGUMENTS, proceed to implement it directly using file-editing and command tools as needed.
3. If no task was provided, wait for the next request and act on it with full read-write capability.