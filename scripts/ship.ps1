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

# Fail closed: GitHub may not have registered the workflow yet, and "no checks" is never success.
$waitSeconds = 90
$pollSeconds = 5
# Count checks from stdout only: gh may exit non-zero while checks are pending, so the exit code is ignored.
$getCount = {
  $raw = gh pr checks $n --json name 2>$null
  if (-not $raw) { return 0 }
  try { return @($raw | ConvertFrom-Json -ErrorAction Stop).Count } catch { return 0 }
}
$deadline = (Get-Date).AddSeconds($waitSeconds)
$count = 0
while ((Get-Date) -lt $deadline) {
  $count = & $getCount
  if ($count -gt 0) {
    # Re-read once so jobs registered a few seconds apart are not missed.
    Start-Sleep -Seconds $pollSeconds
    $again = & $getCount
    if ($again -gt $count) { $count = $again }
    break
  }
  Start-Sleep -Seconds $pollSeconds
}
if ($count -lt 1) { throw "No checks registered after $waitSeconds s: do NOT merge" }
Write-Host "$count check(s) registered. Watching..."
gh pr checks $n --watch
$code = $LASTEXITCODE
"exit=$code"
if ($code -ne 0) { throw "Checks failed: do NOT merge" }

Write-Host "Checks OK. Review the diff and body, then land it with:"
Write-Host "  .\scripts\land.ps1 -Number $n"

