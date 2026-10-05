$o = @()
$o += "branch: $(git branch --show-current)"
$o += "## status"; $o += (git status --short)
$o += "## log"; $o += (git log --oneline main..HEAD)
$o += "## stat"; $o += (git diff main..HEAD --stat)
$added = git diff main..HEAD | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+' }
$o += "## checks on added lines"
$o += "non-ASCII lines: " + @($added | Where-Object { $_ -match '[^\x00-\x7F]' }).Count
$o += "12-digit ids: " + @($added | Where-Object { $_ -match '\b\d{12}\b' }).Count
$o += "## eol"; $o += (git ls-files --eol (git diff main..HEAD --name-only))
$o += "## diff"; $o += (git diff main..HEAD)
$o -join "`n" | Set-Clipboard
"review copied to clipboard ($($o.Count) lines)"
