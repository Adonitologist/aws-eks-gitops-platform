# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Pure Terraform repo (no app code, no test suite). There is no root module: the two stacks `stacks/infra` (stage 1) and `stacks/cluster` (stage 2) are run separately. CI (`.github/workflows/ci.yml`) uses Terraform 1.15.6 and, for each stack, runs:

```bash
terraform -chdir=stacks/<stack> init -backend=false   # validate job, both stacks, no AWS credentials
terraform -chdir=stacks/<stack> validate
tflint --init && tflint -f compact --recursive        # v0.50.0, config in .tflint.hcl; covers stacks and modules
tfsec .                                               # security scan, whole repo
# plan job, stage 1 only (stacks/infra), with a real backend:
terraform init && terraform plan -var="environment=production" -out=tfplan
```

CI never plans, applies or inits stage 2 with a backend. The plan job uses GitHub OIDC with a role ARN hardcoded in `ci.yml`. There is no apply job: `terraform apply` is run by hand, infra first, then cluster (stage 2 runs on the SSM-only runner EC2 that stage 1 creates, see `docs/adr/0002-stage2-access-path.md`). Before `terraform destroy`, follow the teardown order in README "Safe Teardown Protocol" (delete the ArgoCD root app, wait for the ALBs to disappear, delete Karpenter NodePools/EC2NodeClasses, destroy `stacks/cluster`, then `stacks/infra`) or Spot instances and VPC dependencies get orphaned. Design rationale: `docs/adr/0001-private-eks-endpoint.md` and `docs/adr/0002-stage2-access-path.md`.

## Architecture

Two stacks, separate S3 state in the same bucket (`terraform.tfstate` for infra, `cluster.tfstate` for cluster). `stacks/infra/main.tf` wires `vpc` -> `eks_cluster` -> `eks_addons` and `stage2_runner` via `depends_on`; `cluster_name` is `eks-gitops-${environment}` (local in that file). `stacks/cluster` reads cluster name, endpoint, CA, LB controller role ARN and Karpenter queue name from infra outputs via `terraform_remote_state`, and configures the `helm` and `kubernetes` providers from them (`aws eks get-token`). It checks the Pod Identity agent exists with `data "aws_eks_addon"` (existence only, not readiness) because a cross-stack `depends_on` is not possible.

- `modules/eks_cluster`: wraps `terraform-aws-modules/eks/aws ~> 20.0`. Private-only API endpoint, IRSA on, `API_AND_CONFIG_MAP` auth, one managed node group `system_components` (default m7i-flex.large, x86_64 only and Free Tier plan eligible; min 2 / desired 2 / max 3, via `system_node_*` variables; 29 allocatable pods per node (reported by the operator from the live run of 2026-10-04; raw output not retained in the repo; only system node group nodes were measured, Karpenter launched no node); the system pods are 13 pods plus 3 DaemonSet pods per node, and Karpenter needs 2 nodes). Exposes the OIDC ARN/URL consumed by `eks_addons`.
- `modules/eks_addons` (stage 1): IRSA role for AWS Load Balancer Controller, Karpenter IAM/SQS/Pod Identity (`terraform-aws-modules/eks//modules/karpenter`), the EKS managed add-ons `vpc-cni`, `coredns`, `kube-proxy` and `eks-pod-identity-agent` with pinned versions (`*_version` variables, defaults match EKS 1.35). Outputs `lb_role_arn` and `karpenter_queue_name`.
- `modules/stage2_runner` (stage 1): operator-run EC2 (t3.small, Free Tier eligible, AL2023) in a private subnet, no inbound rules, egress TCP 443, reached only through SSM Session Manager; role with S3 state access scoped to `eks-gitops-platform/*`, `eks:DescribeAddon` and `eks:DescribeCluster`; EKS access entry with `AmazonEKSClusterAdminPolicy`; ingress rule on the cluster security group (`cluster_security_group_id` output of `eks_cluster`); Terraform and kubectl pinned in `user_data` with SHA256 checks; session logs in CloudWatch through a runner-only Session document (sessions must use `--document-name`, which the `ssm_session_command` output includes); an example operator IAM policy is rendered by the `stage2_runner_operator_policy_example` output (not applied). Anyone who can start a session on the runner has cluster-admin in practice. Stage 2 is run on it (start, `aws ssm start-session`, tmux, stop), see ADR 0002.
- `modules/eks_addons_helm` (stage 2): Helm releases for the LB controller (chart 3.5.0, appVersion v3.5.0; CRDs only on first install, later bumps need a manual `kubectl apply` of the chart crds, see the ADR) and Karpenter (`oci://public.ecr.aws/karpenter`, v1.14.1).
- `modules/gitops_argocd` (stage 2): `argocd` namespace plus Helm release of Argo CD (chart 10.9.6, appVersion v3.5.3), ClusterIP service with `--insecure` and an ALB ingress (TLS terminates at the ALB). Chart 10.x creates NetworkPolicies by default (kept; inert while VPC CNI `enableNetworkPolicy` is off).
- `kubernetes/`: not managed by Terraform. `argocd-apps/root-app.yaml` is the App-of-Apps root (auto-sync, prune, selfHeal) pointing at `kubernetes/workloads` on `main` of the GitHub repo; Karpenter v1 NodePool/EC2NodeClass manifests live there (role and discovery tag are fixed strings that must match Terraform, see ADR). The NodePool is restricted to m7i-flex.large and c7i-flex.large, on-demand only, limits cpu 8 / memory 32Gi (Free Tier plan, see the ADR 0001 row "AWS Free Tier plan"). Pushing manifests changes the live cluster.

## Gotchas

- `modules/vpc` is the single VPC (flow logs, dedicated NACLs, `azs` variable defaulted in `stacks/infra/variables.tf`). `eks_cluster` consumes `vpc_id`/`subnet_ids`; there is no inline VPC anymore. NACLs are tight: private subnets reach the internet only on TCP 443 (via NAT), so anything needing plain HTTP 80 egress fails.
- The stage 2 runner is stopped when idle; start it before use (`aws ec2 start-instances`). Teardown also runs on it (stage 2 destroyed first, then stage 1 from the workstation). Because of `depends_on` on the module call, its data sources are read at apply time, so a stage 1 plan shows its AMI and policy as known after apply. Recreate it with `-replace=module.stage2_runner.aws_instance.runner` to refresh the AMI.
- tfsec findings from upstream modules are silenced with `#tfsec:ignore:<ID>` lines directly above the `module` line (see `modules/vpc/main.tf`, `modules/eks_cluster/main.tf`); justifications go above them.
- `modules/eks_cluster` takes `cluster_version` (default "1.35", one minor behind the latest, standard support until 2027-03-27; the Argo CD and LB controller chart bumps were the last blocker, so apply only after that PR is merged; remaining are the verify-after-first-apply items in the ADR) and `system_node_*` from variables. The README Terraform badge is stale (v1.5+).
- Backend bucket is hardcoded in `stacks/infra/backend.tf` and `stacks/cluster/backend.tf` (S3 only, `use_lockfile = true`, no DynamoDB; needs Terraform >= 1.10 and CI pins 1.15.6 at `ci.yml` lines 24 and 62). The CI role needs write/delete on the `.tflock` object next to the state key. Local AWS profiles: `default` (IAM user terraform-developer) is used by the operator, whose plans use the normal state lock; `readonly` (assumed role claude-readonly, used by the cc alias and by Claude Code) is not expected to write the `.tflock` object, so plans run with it pass `-lock=false`. Changing the backend may need `terraform init -reconfigure`.
- English only: comments, variable and output descriptions, error messages, YAML comments and docs are all in English.
- `contexto_*.txt` / `estado_repositorio.txt` in the root are scratch dumps (git-ignored), not part of the project.

## Output limits
- Plans run by Claude Code (profile `readonly`) always: terraform plan -lock=false -no-color -compact-warnings 2>&1 | tail -n 40
- Operator plans (profile `default`) use the normal lock: terraform plan -no-color -compact-warnings 2>&1 | tail -n 40
- Never read full plan output or full debug logs; use tail/grep.

## Working rules
- English and ASCII only in anything code-facing (see Gotchas): files, comments, commits, PR titles and bodies.
- Never push, merge, apply or destroy; the operator does. No `terraform apply/destroy`, `kubectl apply/delete` or AWS write commands.
- A PreToolUse hook (`.claude/hooks/block-writes.ps1`) blocks mutating commands in any spelling (full paths, `bash -c`); extend its `$rules` table when adding a tool. It is a backstop, not a boundary: the read-only IAM role is the real guard.
- Label every claim VERIFIED (raw output or file:line) or NOT VERIFIED. Never say done or perfect unless output shown proves it.
- Never print the AWS account id or role ARNs; mask them in reports and diffs.
- Plans: profile `readonly` with `-lock=false`, see Output limits.
- Stage by explicit path only. Never commit `stacks/infra/tfplan` or untracked files.
- If `git diff --stat` shows a whole-file change, stop and report (`.gitattributes` enforces LF).
- One concern per PR. When `.tf` changes, report raw output and exit codes for fmt, validate, tflint and a local plan; tfsec runs in CI.
- Reports: full report to `<name>.md` and PR body to `<name>-body.md` in the operator's cc-reports folder, outside the repo (ASCII, masked); print only the paths and a 3-line summary.
- Level A PRs (docs, whitespace, README): do the work and stop before push. Level B PRs (Terraform, IAM, CI, user_data, Kubernetes manifests): read-only Step 1 report, stop for approval before editing.
- On any surprise (dirty tree, unexpected main commit, whole-file diff, failed check): stop and report.

## AWS/Terraform quality standards (mandatory)
- This is production infrastructure: correctness and security take priority over speed and brevity.
- Scope: apply to new or modified code only. Report existing violations; do not fix them unasked.
- Done means: terraform fmt, validate, tflint and tfsec pass with no new findings. If a tool is missing, say so; never claim it passed.
- No hardcoded values: typed variables with descriptions; validation blocks where input is constrained.
- Bounded version constraints (~>) for providers and modules; never unconstrained.
- IAM least privilege: no "*" in actions/resources unless justified in a comment.
- Encryption at rest and in transit by default. Do not change existing network exposure without asking.
- All taggable resources tagged (prefer provider default_tags).
- Secrets never in code; mark sensitive outputs/variables as sensitive.
- No placeholders or TODOs; follow the existing module structure.
- After plan, explicitly warn about any resource replacement or destruction.

- tfsec:ignore lines must sit directly above the module line (one ID per line); justification comments go above them, never between.

- GitHub OIDC uses immutable subject: sub = repo:Adonitologist@90419501/aws-eks-gitops-platform@1383441716:<ref|pull_request>. Trust policy must use these exact values with StringEquals, no wildcards.
- CI role github-actions-terraform-role-jeh: ReadOnlyAccess + inline terraform-state-access (state read, .tflock read/write/delete). No admin. Re-check CI plan after the first apply.
