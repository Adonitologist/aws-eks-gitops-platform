# PreToolUse backstop: blocks mutating git/gh/terraform/kubectl/helm/aws commands.
# Scans the whole command text, so wrappers (bash -c, env, full paths) are covered.
# Fail-closed: any internal error exits 2 (only exit 2 blocks a PreToolUse hook).
# Not a sandbox: variable indirection, encoded payloads and aliases get past it.
$ErrorActionPreference = 'Stop'
trap { [Console]::Error.WriteLine("block-writes hook error, blocking: $_"); exit 2 }

$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
$cmd = [string]$payload.tool_input.command
if (-not $cmd) { exit 0 }

# Normalize: unify path separators, drop quotes and backticks, collapse whitespace.
# [char]92 is a backslash; do not rewrite it as '\\' (it was collapsed once by a heredoc).
$t = $cmd.Replace([string][char]92, '/') -replace '["''`]', ' ' -replace '\s+', ' '

# Program token: optional directory prefix, optional .exe, not part of a longer word.
function P($n) { "(?<![\w.-])(?:[^\s;&|()]*/)?$n(?:\.exe)?(?![\w.-])" }
$gap = '[^;&|\n]*?'   # stay inside one simple command
$w = '(?<![\w.-])'    # word start
$e = '(?![\w.-])'     # word end
$awsVerbs = 'create|delete|put|update|terminate|run|start|stop|modify|attach|detach|associate|disassociate|register|deregister|revoke|authorize|reboot|send|invoke|tag|untag|enable|disable|cancel|import|release|allocate|replace|set|remove|add|reset|restore|publish|subscribe|unsubscribe|execute|schedule|accept|reject|apply|copy|deploy|upgrade|rollback|rotate|purge|empty'

# Extend this table when a new mutating tool or verb appears.
$rules = [ordered]@{
  'git push'                       = "$(P git)$gap${w}push$e"
  'gh pr merge/create'             = "$(P gh)$gap${w}pr $gap${w}(merge|create)$e"
  'gh merge'                       = "$(P gh)$gap${w}merge$e"
  'terraform apply/destroy/import/state' = "$(P terraform)$gap${w}(apply|destroy|import|state)$e"
  'kubectl apply/delete/patch/replace'   = "$(P kubectl)$gap${w}(apply|delete|patch|replace)$e"
  'helm install/upgrade/uninstall/rollback' = "$(P helm)$gap${w}(install|upgrade|uninstall|rollback)$e"
  'aws write verb'                 = "$(P aws)$gap${w}($awsVerbs)-[a-z0-9-]+"
  'aws s3 write'                   = "$(P aws)$gap${w}s3 $gap${w}(cp|mv|rm|rb|mb|sync)$e"
  'operator scripts (push/merge)'  = "${w}(ship|land)\.ps1"
}

foreach ($name in $rules.Keys) {
  if ($t -match $rules[$name]) {
    [Console]::Error.WriteLine("Blocked by block-writes hook ($name). The operator runs this command, not Claude Code.")
    exit 2
  }
}
exit 0
