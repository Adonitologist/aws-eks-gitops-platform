param([Parameter(Mandatory)][int]$Number)
$ErrorActionPreference = 'Stop'
$info = gh pr view $Number --json headRefName,state,body | ConvertFrom-Json
if ($info.state -ne 'OPEN') { throw "PR $Number is not open" }
if ([string]::IsNullOrWhiteSpace($info.body)) { throw "PR $Number has an empty body" }

gh pr checks $Number --watch
if ($LASTEXITCODE -ne 0) { throw "Checks not green: NOT merging" }

gh pr merge $Number --merge
if ($LASTEXITCODE -ne 0) { throw "merge failed" }

git switch main
git pull --ff-only
git branch -d $info.headRefName
git push origin --delete $info.headRefName
git log --oneline -3
