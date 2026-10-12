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
