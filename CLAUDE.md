# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Pure Terraform repo (no app code, no test suite). There is no root module: the two stacks `stacks/infra` (stage 1) and `stacks/cluster` (stage 2) are run separately. CI (`.github/workflows/ci.yml`) uses Terraform 1.15.6 and, for each stack, runs:

```bash
terraform -chdir=stacks/<stack> init -backend=false   # validate job, both stacks, no AWS credentials
terraform -chdir=stacks/<stack> validate
tflint --init && tflint -f compact --recursive --minimum-failure-severity=error  # v0.50.0, no .tflint.hcl; covers stacks and modules
tfsec .                                               # security scan, whole repo
# plan job, stage 1 only (stacks/infra), with a real backend:
terraform init && terraform plan -var="environment=production" -out=tfplan
```

CI never plans, applies or inits stage 2 with a backend. The plan job uses GitHub OIDC with a role ARN hardcoded in `ci.yml`. There is no apply job: `terraform apply` is run by hand, infra first, then cluster (stage 2 needs a network path to the private EKS endpoint). Before `terraform destroy`, follow the teardown order in README "Safe Teardown Protocol" (delete the ArgoCD root app, wait for the ALBs to disappear, delete Karpenter NodePools/EC2NodeClasses, destroy `stacks/cluster`, then `stacks/infra`) or Spot instances and VPC dependencies get orphaned. Design rationale: `docs/adr/0001-private-eks-endpoint.md`.

## Architecture

Two stacks, separate S3 state in the same bucket (`terraform.tfstate` for infra, `cluster.tfstate` for cluster). `stacks/infra/main.tf` wires `vpc` -> `eks_cluster` -> `eks_addons` via `depends_on`; `cluster_name` is `eks-gitops-${environment}` (local in that file). `stacks/cluster` reads cluster name, endpoint, CA, LB controller role ARN and Karpenter queue name from infra outputs via `terraform_remote_state`, and configures the `helm` and `kubernetes` providers from them (`aws eks get-token`). It checks the Pod Identity agent exists with `data "aws_eks_addon"` (existence only, not readiness) because a cross-stack `depends_on` is not possible.

- `modules/eks_cluster`: wraps `terraform-aws-modules/eks/aws ~> 20.0`. Private-only API endpoint, IRSA on, `API_AND_CONFIG_MAP` auth, one managed node group `system_components` (default t3.medium, min 2 / desired 2 / max 3, via `system_node_*` variables; the system pods need about 13 pod slots and Karpenter needs 2 nodes). Exposes the OIDC ARN/URL consumed by `eks_addons`.
- `modules/eks_addons` (stage 1): IRSA role for AWS Load Balancer Controller, Karpenter IAM/SQS/Pod Identity (`terraform-aws-modules/eks//modules/karpenter`), the `eks-pod-identity-agent` addon. Outputs `lb_role_arn` and `karpenter_queue_name`.
- `modules/eks_addons_helm` (stage 2): Helm releases for the LB controller and Karpenter (`oci://public.ecr.aws/karpenter`, v0.37.0).
- `modules/gitops_argocd` (stage 2): `argocd` namespace plus Helm release of Argo CD, ClusterIP service with `--insecure` and an ALB ingress (TLS terminates at the ALB).
- `kubernetes/`: not managed by Terraform. `argocd-apps/root-app.yaml` is the App-of-Apps root (auto-sync, prune, selfHeal) pointing at `kubernetes/workloads` on `main` of the GitHub repo; Karpenter NodePool/EC2NodeClass manifests live there. Pushing manifests changes the live cluster.

## Gotchas

- `modules/vpc` is the single VPC (flow logs, dedicated NACLs, `azs` variable defaulted in `stacks/infra/variables.tf`). `eks_cluster` consumes `vpc_id`/`subnet_ids`; there is no inline VPC anymore. NACLs are tight: private subnets reach the internet only on TCP 443 (via NAT), so anything needing plain HTTP 80 egress fails.
- tfsec findings from upstream modules are silenced with `#tfsec:ignore:<ID>` lines directly above the `module` line (see `modules/vpc/main.tf`, `modules/eks_cluster/main.tf`); justifications go above them.
- `modules/eks_cluster` takes `cluster_version` (default "1.35", one minor behind the latest, standard support until 2027-03-27; not to be applied before the Karpenter, managed add-ons, Argo CD and LB controller PRs are merged, see the ADR) and `system_node_*` from variables. The README Terraform badge is stale (v1.5+).
- Backend bucket is hardcoded in `stacks/infra/backend.tf` and `stacks/cluster/backend.tf` (S3 only, `use_lockfile = true`, no DynamoDB; needs Terraform >= 1.10 and CI pins 1.15.6 at `ci.yml` lines 24 and 62). The CI role needs write/delete on the `.tflock` object next to the state key. Local plans use a read-only profile, so they must pass `-lock=false`. Changing the backend may need `terraform init -reconfigure`.
- Comments and variable descriptions are a mix of Spanish and English; global rule is English for new code.
- `contexto_*.txt` / `estado_repositorio.txt` in the root are scratch dumps (git-ignored), not part of the project.

## Output limits
- Always run plan as: terraform plan -lock=false -no-color -compact-warnings 2>&1 | tail -n 40
- Never read full plan output or full debug logs; use tail/grep.

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
