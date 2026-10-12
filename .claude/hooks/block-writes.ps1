# PreToolUse backstop: blocks mutating git/gh/terraform/kubectl/helm/aws commands.
# Also a credential guard: Claude Code may use only the "readonly" AWS profile. It blocks
# --profile / AWS_PROFILE with any other value, "aws configure export-credentials|get|set|...",
# any command text naming the ~/.aws directory (credentials, config, cli/cache, sso), and
# aws/terraform commands when the inherited AWS_PROFILE is not "readonly".
# Scans the whole command text, so wrappers (bash -c, env, full paths) are covered.
# Fail-closed: any internal error exits 2 (only exit 2 blocks a PreToolUse hook).
# Not a sandbox: variable indirection, encoded payloads, scripts that read files themselves,
# env dumps and aliases get past it; the Read/Edit deny rules in settings.json cover the file tools.
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
  'operator scripts (teardown)'    = "(?:(?:^|[;&|(]) ?(?:\w+=\S* )*|$(P '(?:ba|z|da|k)?sh')$gap|$(P source)$gap)(?:[^\s;&|()]*/)?teardown-stage2\.sh$e"
  # Credential guard: only the readonly profile; never operator profiles or credential files.
  'aws profile other than readonly' = "${w}--profile(?:=|\s+)(?!readonly$e)\S"
  'AWS_PROFILE not readonly'       = "AWS_(?:DEFAULT_)?PROFILE$e(?!\s*[=,]?\s*readonly$e)"
  'aws configure secrets'          = "$(P aws)$gap${w}configure $gap${w}(export-credentials|get|set|import|sso)$e"
  # Single quotes on purpose: the literal $ is the regex end anchor, not a PowerShell variable.
  'aws credentials directory'      = '(?<![\w.-])\.aws(?:/|$|[\s;&|)])|AWS_SHARED_CREDENTIALS_FILE|AWS_CONFIG_FILE'
}

# Inherited environment: Claude Code started with a non-readonly profile exported. The command
# text shows nothing in that case, so check this process environment (a child of Claude Code).
if ($env:AWS_PROFILE -and $env:AWS_PROFILE -ne 'readonly' -and $t -match "$(P aws)|$(P terraform)") {
  [Console]::Error.WriteLine("Blocked by block-writes hook (inherited AWS_PROFILE is not readonly). The operator runs this command, not Claude Code.")
  exit 2
}

foreach ($name in $rules.Keys) {
  if ($t -match $rules[$name]) {
    [Console]::Error.WriteLine("Blocked by block-writes hook ($name). The operator runs this command, not Claude Code.")
    exit 2
  }
}
exit 0
