# Operator scripts (PowerShell, run from the repo root)

Flow: review -> ship -> land. Run each one yourself; Claude Code does not push or merge.

- `review.ps1`: on a feature branch, copies to the clipboard the status, log, diff stat,
  ASCII and 12-digit id counts on added lines, line endings and the full diff against main.
- `ship.ps1 -Title <t> -BodyFile <path>`: refuses main/master or a dirty tree, pushes the branch,
  opens the PR with the body file, then watches the checks. It never merges.
- `land.ps1 -Number <n>`: requires an open PR with a non-empty body, waits for the checks and
  merges the PR (merge commit) once they are green. Then it switches to main, pulls
  (fast-forward only) and deletes the local and remote branch.

`land.ps1` merges for real, so review the PR diff and body before running it.
