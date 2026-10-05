---
description: "Level B Step 1: read-only investigation report, then stop for approval"
argument-hint: "<task>"
disable-model-invocation: true
---
Follow "Working rules" in CLAUDE.md. This is a Level B task, Step 1 only.

Task: $ARGUMENTS

1. Step 0: show git status, current branch and git log --oneline -3. If not clean or unexpected, stop and report. Create the working branch but do not edit tracked files.
2. Investigate read-only. Label every claim VERIFIED (raw output or file:line) or NOT VERIFIED.
3. In the report include: current state with file:line, the exact proposed edit, risks, the split into PRs, and the checks plan.
4. Write the report to the operator's cc-reports folder, print only the path and a 3-line summary, then STOP and wait for my OK. Do not edit, push, merge or apply.
