---
description: "Level A task (docs, whitespace, README): do the work, run checks, write report and body files, stop before push"
argument-hint: "<task>"
disable-model-invocation: true
---
Follow "Working rules" in CLAUDE.md. This is a Level A task.

Task: $ARGUMENTS

1. Step 0: show git status, current branch and git log --oneline -3. If the tree is dirty or main is not what I expect, stop and report. Create a branch for the task.
2. Make the change with minimal diffs and stage by explicit path.
3. Run the relevant checks and report raw output and exit codes (git diff --stat, whole-file diff check, ASCII check on added lines; fmt, validate, tflint if any .tf changed).
4. Commit once. Write the full report and the PR body to the operator's cc-reports folder as described in Working rules (masked, ASCII).
5. Do not push, merge or open the PR. Print only the paths and a 3-line summary.
