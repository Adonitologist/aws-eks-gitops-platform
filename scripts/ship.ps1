param(
  [Parameter(Mandatory)][string]$Title,
  [Parameter(Mandatory)][string]$BodyFile
)
$ErrorActionPreference = 'Stop'
$branch = git branch --show-current
if ($branch -in @('main','master')) { throw "You are on $branch" }
if (git status --short --untracked-files=no) { throw "Dirty working tree" }

git push -u origin $branch
if ($LASTEXITCODE -ne 0) { throw "push failed" }

$url = gh pr create --base main --head $branch --title $Title --body-file $BodyFile
if ($LASTEXITCODE -ne 0) { throw "pr create failed" }
$n = ($url | Select-Object -Last 1) -replace '.*/pull/', ''
Write-Host "PR #$n created. Waiting for checks..."
Start-Sleep -Seconds 20
gh pr checks $n --watch
$code = $LASTEXITCODE
"exit=$code"
if ($code -ne 0) { throw "Checks failed: do NOT merge" }

Write-Host "Checks OK. Review the diff and body, then merge yourself with:"
Write-Host "  gh pr merge $n --merge"

