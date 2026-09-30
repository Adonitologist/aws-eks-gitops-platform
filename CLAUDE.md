# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Pure Terraform repo (no app code, no test suite). CI (`.github/workflows/ci.yml`) runs these in order, using Terraform 1.9.0:

```bash
terraform init                      # remote S3 backend; CI also passes -upgrade
terraform validate
tflint --init && tflint -f compact  # tflint v0.50.0, no .tflint.hcl in repo
tfsec .                             # security scan
terraform plan -var="environment=production" -out=tfplan
```

Needs AWS credentials (CI uses GitHub OIDC; role ARN from repo variable `AWS_OIDC_ROLE_ARN` in the validate job, hardcoded in the plan job). There is no apply job: `terraform apply` is run by hand. Before `terraform destroy`, follow the drain order in README "Safe Teardown Protocol" (delete the ArgoCD root app, then Karpenter NodePools/EC2NodeClasses) or Spot instances and VPC dependencies get orphaned.

## Architecture

Root module (`main.tf`) wires four modules in a strict chain via `depends_on`: `vpc` -> `eks_cluster` -> `eks_addons` -> `gitops_argocd`. `cluster_name` is `eks-gitops-${environment}` (local in `main.tf`). `providers.tf` configures the `helm` and `kubernetes` providers from `module.eks_cluster` outputs (endpoint + CA + `aws eks get-token`), so those providers only work after the cluster exists.

- `modules/eks_cluster`: wraps `terraform-aws-modules/eks/aws ~> 20.0`. Private-only API endpoint, IRSA on, `API_AND_CONFIG_MAP` auth, one managed node group `system_components` (t3.micro, 3-5 nodes). Exposes the OIDC ARN/URL consumed by `eks_addons`.
- `modules/eks_addons`: IRSA role for AWS Load Balancer Controller, Karpenter IAM/SQS/Pod Identity (`terraform-aws-modules/eks//modules/karpenter`), the `eks-pod-identity-agent` addon, and Helm releases for the LB controller and Karpenter (`oci://public.ecr.aws/karpenter`, v0.37.0).
- `modules/gitops_argocd`: `argocd` namespace plus Helm release of Argo CD, ClusterIP service with `--insecure` and an ALB ingress (TLS terminates at the ALB).
- `kubernetes/`: not managed by Terraform. `argocd-apps/root-app.yaml` is the App-of-Apps root (auto-sync, prune, selfHeal) pointing at `kubernetes/workloads` on `main` of the GitHub repo; Karpenter NodePool/EC2NodeClass manifests live there. Pushing manifests changes the live cluster.

## Gotchas

- `modules/vpc` is the single VPC (flow logs, dedicated NACLs, `azs` variable defaulted in the root). `eks_cluster` consumes `vpc_id`/`subnet_ids`; there is no inline VPC anymore. NACLs are tight: private subnets reach the internet only on TCP 443 (via NAT), so anything needing plain HTTP 80 egress fails.
- tfsec findings from upstream modules are silenced with `#tfsec:ignore:<ID>` lines directly above the `module` line (see `modules/vpc/main.tf`, `modules/eks_cluster/main.tf`); justifications go above them.
- `modules/eks_cluster/main.tf` still hardcodes `cluster_version = "1.31"` and `instance_types = ["t3.micro"]`; the `cluster_version` / `system_node_instance_types` variables exist but are unused. README badges are stale (Kubernetes v1.30, Terraform v1.5+).
- Backend bucket is hardcoded in `backend.tf` (S3 only; no state locking: no DynamoDB table, no `use_lockfile`). `use_lockfile = true` needs Terraform >= 1.10, but CI pins 1.9.0 (`ci.yml` lines 24 and 68) and `init` would fail on it. To enable it: bump both CI versions first, then add it to `backend.tf`; the CI role also needs write/delete on the lock object next to the state key. Local plans use a read-only profile, so once locking is on they must pass `-lock=false`. Changing the backend may need `terraform init -reconfigure`.
- Comments and variable descriptions are a mix of Spanish and English; global rule is English for new code.
- `contexto_*.txt` / `estado_repositorio.txt` in the root are scratch dumps (git-ignored), not part of the project.

## Output limits
- Always run plan as: terraform plan -no-color -compact-warnings 2>&1 | tail -n 40
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
