# ADR 0003: Operator credentials (assumed role with MFA)

- Status: Accepted
- Date: 2026-10-12

## Context

Until 2026-10-12 the workstation IAM user (`terraform-developer`) held `AdministratorAccess`
directly, with one long-lived access key in `~/.aws/credentials` (profile `default`). Anyone or
anything that could read that file had permanent administrator access to the account.

Constraints:

- Terraform in this repository creates IAM roles and policies, so the identity that runs it needs
  broad IAM permissions.
- Terraform cannot prompt for an MFA code, so a credential with MFA must be obtained before the
  run.
- The account is standalone (not in AWS Organizations) and also hosts another project.
- Stage 2 runs on the runner EC2 with its instance role (ADR 0002), so this ADR covers the
  workstation only: stage 1 plan, apply and destroy, and `scripts/teardown/check-leftovers.ps1`.
- Claude Code uses a separate read-only role (`claude-readonly`, profile `readonly`) and must not
  use the operator profiles (CLAUDE.md).

## Options considered

| Option | Verdict |
|---|---|
| 1. Keep the admin access key on the workstation | Rejected: a stolen file gives permanent admin; no MFA |
| 2. IAM Identity Center | Not chosen (see below) |
| 3. IAM user with no permissions of its own, assuming an operator role that requires MFA | Chosen |

Identity Center, per https://docs.aws.amazon.com/singlesignon/latest/userguide/identity-center-instances.html:
an account instance does not offer multi-account permissions or the AWS access portal, and an
organization instance needs AWS Organizations. This account is standalone and also hosts another
project, so an organization instance was not set up. Pricing was not checked.

## Decision

1. The IAM user has no direct permissions except an inline policy that allows `sts:AssumeRole` on
   exactly two roles: the Terraform operator role and the read-only role `claude-readonly`. It has a
   virtual MFA device.
2. The operator role has `AdministratorAccess`. Its trust policy allows only that user and requires
   `aws:MultiFactorAuthPresent = true`. Maximum session: 1 hour.
3. The access key left on the workstation (profile `default`) is only the source credential for
   assuming roles. Used alone it can do nothing (see "Verified").
4. `AdministratorAccess` on the operator role is an accepted trade-off: Terraform here creates IAM
   roles, so a least-privilege Terraform policy would be a separate project.

Placeholders below stand for real values that are never committed. The policy documents show the
shape implied by the decision; they are not exports of the live documents.

Inline policy of the user:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": [
        "arn:aws:iam::<ACCOUNT_ID>:role/<OPERATOR_ROLE_NAME>",
        "arn:aws:iam::<ACCOUNT_ID>:role/claude-readonly"
      ]
    }
  ]
}
```

Trust policy of the operator role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::<ACCOUNT_ID>:user/terraform-developer" },
      "Action": "sts:AssumeRole",
      "Condition": { "Bool": { "aws:MultiFactorAuthPresent": "true" } }
    }
  ]
}
```

Profiles in `~/.aws/config` (`readonly` is unchanged: role `claude-readonly`, `source_profile =
default`):

```ini
[profile tf-admin]
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/<OPERATOR_ROLE_NAME>
source_profile = default
mfa_serial = arn:aws:iam::<ACCOUNT_ID>:mfa/<MFA_DEVICE_NAME>
duration_seconds = 3600

[profile tf-admin-tf]
credential_process = aws configure export-credentials --profile tf-admin
```

`tf-admin-tf` exists because Terraform is reported to fail with a profile that has both `role_arn`
and `mfa_serial` (third-party article, see "Not verified"). `credential_process` hands Terraform
the already-assumed session instead.

## How to use

1. `aws sts get-caller-identity --profile tf-admin`: asks for the MFA code and caches a 1 hour
   session.
2. `$env:AWS_PROFILE = 'tf-admin-tf'` (PowerShell) or `export AWS_PROFILE=tf-admin-tf` (bash).
3. Run Terraform and `scripts/teardown/check-leftovers.ps1` as usual. Plans use the normal state
   lock.
4. After one hour, repeat step 1.

Claude Code uses `readonly` only, with `-lock=false` (CLAUDE.md, "Output limits").

## Consequences

- A stolen `~/.aws/credentials` no longer gives administrator access; assuming the operator role
  also needs a current MFA code.
- Stage 1 runs must finish inside the 1 hour session. The stage 1 apply took about 13 minutes on
  the live run of 2026-10-11 (`docs/adr/0001-private-eks-endpoint.md:132`, row "Stage 1 apply duration": "about 13 min (EKS control plane 10m21s)"), so the margin is large. A longer
  run is expected to fail when the session expires (see "Not verified").
- Stage 2 is unaffected: it runs on the runner with the instance role (ADR 0002). The only
  workstation step in the teardown that needs AWS access is the leftover check and the stage 1
  destroy, both with `tf-admin-tf`.
- Operator-side docs that referred to profile `default` for Terraform are updated (README,
  CLAUDE.md). Older ADR text is not rewritten; ADR 0002 gets a short addendum.
- The EKS cluster creator entry (`enable_cluster_creator_admin_permissions = true`) is created for
  the identity that applies stage 1. Whether that is now the operator role (instead of the IAM
  user) was not checked on a live cluster; see "Not verified".

## Verified

Reported by the operator from commands run on 2026-10-12; raw terminal output is not stored in
the repo.

- `aws iam list-attached-user-policies` for the user returned an empty list.
- `aws iam list-user-policies` returned exactly one inline policy, named `assume-roles-only`.
- `aws iam get-role` on the operator role returned `MaxSessionDuration` 3600.
- The trust policy shown in the create-role output matches the one in this ADR.
- After clearing the CLI session cache, `aws sts get-caller-identity --profile tf-admin` asked for
  the MFA code and returned a new session of the operator role, and
  `aws sts get-caller-identity --profile readonly` still returned the read-only role (so the inline
  policy allows both assumptions).
- An `ec2:DescribeVpcs` call with the remaining access key alone returned `UnauthorizedOperation`.
- `aws sts get-caller-identity --profile tf-admin` prompted for the MFA code and cached a session.
- `tf-admin-tf` returned the same session without prompting.
- `terraform plan` in `stacks/infra` ran with `AWS_PROFILE=tf-admin-tf`.

## Not verified

- That a Terraform run longer than the 1 hour session fails mid-run (Terraform cannot prompt for
  MFA). Not tested.
- That Terraform fails with a profile that has both `role_arn` and `mfa_serial`. Reported by a
  third-party article (https://dev.classmethod.jp/articles/terraform-mfa-assumerole-export-credentials/),
  not reproduced here.
- Whether `aws configure export-credentials` prompts for MFA when no session is cached: the AWS
  documentation page for the command does not say. The workflow above avoids it by running the
  `tf-admin` call first.
- Identity Center pricing.
- That the EKS cluster creator access entry is created for the operator role on the next cluster
  creation, and that nothing else (for example the CI role or the runner) is affected.

## Follow-ups

- Least-privilege policy for the operator role (separate project).
- Revisit Identity Center if the account joins an organization.

## Addendum 2026-10-12: enforcement

The rule "Claude Code uses only the `readonly` profile" (CLAUDE.md) was a convention. It is now enforced in two layers:

- `.claude/hooks/block-writes.ps1` (PreToolUse, Bash and PowerShell) blocks: `--profile` with any value other than `readonly`; `AWS_PROFILE` or `AWS_DEFAULT_PROFILE` set to anything other than `readonly`; `aws configure export-credentials|get|set|import|sso`; any command text naming the `.aws` directory (or `AWS_SHARED_CREDENTIALS_FILE`, `AWS_CONFIG_FILE`); and `aws` or `terraform` commands when the inherited `AWS_PROFILE` of Claude Code is not `readonly`.
- `.claude/settings.json` deny rules `Read(~/.aws/**)` and `Edit(~/.aws/**)` for the built-in file tools.

### Verified

- The operator's `cc` command (checked with `(Get-Command cc).Definition`, 2026-10-12) sets `AWS_PROFILE` to `readonly` for the Claude Code process and removes the variable when Claude Code exits. This is why the inherited-profile check passes for normal sessions.
- A test script kept outside the repo (`hook-guard-test.ps1`) pipes sample PreToolUse JSON into the hook and checks the exit code: 43 cases, all as expected (existing rules still block; each new rule blocks its samples; `readonly` calls, `terraform plan -lock=false`, `git status` and `ls .aws-sam` pass). This verifies the hook text matching only. It runs no AWS call and does not show what Claude Code does at runtime.
- Runtime check on 2026-10-12, with Claude Code started through the `cc` command on the branch `ci/hook-profile-guard`, reported by Claude Code and the operator (raw output not stored):
  - `aws sts get-caller-identity --profile tf-admin` was refused by the hook before running, with the message "Blocked by block-writes hook (aws profile other than readonly)".
  - Reading `~/.aws/config` with the Read tool was refused by the deny rule ("File is in a directory that is denied by your permission settings"). For the Read tool this also shows that `~` expands to the user profile directory on this Windows machine.
  - `aws sts get-caller-identity --profile readonly` ran and returned the read-only role.

### Not verified

- That the deny rules apply to PowerShell cmdlets (`Get-Content`, `gc`, `Select-String`); the Claude Code docs name `cat`, `head`, `tail`, `sed` and `tee`. The hook rule on the `.aws` text covers cmdlets in Bash and PowerShell command lines either way.
- That the PowerShell tool passes its text in `tool_input.command` (the hook reads only that field).

### Limits (not a sandbox)

- Scripts: a script that Claude Code writes and runs, or any subprocess that opens files itself, is not seen; the hook scans command text, and the Write and Edit tools do not pass through it.
- Obfuscation: paths or profile names built from string pieces, encoded payloads and variable indirection can get past the text rules. A `--profile` value held in a variable is blocked (fail closed), a `.aws` path assembled from pieces is not.
- When Claude Code is started with the `cc` command, `AWS_PROFILE` is `readonly`, so a bare `aws` call uses `readonly`. The gap exists only if `claude` is started without `cc` and with no `AWS_PROFILE`: then a bare `aws` call uses the `default` profile, whose access key alone is unauthorized for EC2 (see "Verified" above) but is not `readonly`. Closing it would block every bare `aws` call and was left as an operator decision.
- Environment dumps (`env`, `printenv`, `Get-ChildItem Env:`) are not blocked and would show credential variables if any are exported.
- Only an OS-level sandbox enforces file access for all processes; it was not evaluated here.
