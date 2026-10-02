# ADR 0001: Private EKS endpoint and two-stage Terraform split

- Status: Accepted
- Date: 2026-10-01

## Context

- The EKS API endpoint is private-only (`modules/eks_cluster/main.tf`:
  `cluster_endpoint_public_access = false`, `cluster_endpoint_private_access = true`).
- The `helm` and `kubernetes` Terraform providers must reach that endpoint, so they can only
  work from inside the VPC or over a network path into it.
- Before this change a single root module held everything (`vpc` -> `eks_cluster` -> `eks_addons`
  -> `gitops_argocd`), so one `terraform apply` needed AWS API access and cluster API access at
  once.
- The repository is public and CI runs on `pull_request`.
- Options considered for reaching the endpoint (reasons as stated by the repository owner):
  - The VPN used for access has a shared exit IP, so allow-listing it on a public endpoint would
    admit other users of that VPN.
  - GitHub-hosted runner IPs cannot be allow-listed in practice.

## Decision

1. Keep the API endpoint private-only. Do not enable the public endpoint.
2. Do not use self-hosted runners: the repository is public and runs workflows on
   `pull_request`, so untrusted code could execute on a runner inside the VPC.
3. Split Terraform into two stacks with separate state in the same S3 bucket
   (`eks-gitops-tfstate-154932391641`, `us-east-1`, `use_lockfile = true` in both):

   | Stack | Contents | State key |
   |---|---|---|
   | `stacks/infra` (stage 1) | `vpc`, `eks_cluster`, `eks_addons` (IAM, SQS, Pod Identity, `eks-pod-identity-agent` addon) | `eks-gitops-platform/terraform.tfstate` |
   | `stacks/cluster` (stage 2) | `eks_addons_helm` (AWS Load Balancer Controller, Karpenter), `gitops_argocd`, `helm` and `kubernetes` providers | `eks-gitops-platform/cluster.tfstate` |

   Stage 2 reads cluster name, endpoint, CA, the load balancer controller role ARN and the
   Karpenter queue name from stage-1 outputs through `terraform_remote_state`.
4. CI validates both stacks (`init -backend=false`, `validate`, `tflint`, `tfsec`) and plans
   stage 1 only. CI never plans or applies stage 2 and never initializes it with a backend.
5. The Karpenter release needs the Pod Identity agent, which stage 1 creates. A cross-stack
   `depends_on` does not exist, so stage 2 uses `data "aws_eks_addon"` to fail the plan when the
   addon is absent, and the README documents the apply order.

## Consequences

- Stage 1 needs only AWS API access and is the only stack planned in CI.
- Stage 2 is applied from a host with a network path to the private endpoint. Known constraint:
  applying stage 2 from a laptop is not possible until that access path exists; the access path is
  planned in PR B and is not decided here.
- The state was empty when the split was made, so no `terraform state mv` or `removed` blocks were
  needed.
- The `aws_eks_addon` data source checks that the addon exists. It does not check readiness: the
  data source exposes no status attribute (verified from the AWS provider 5.x schema), so an addon
  that exists but is not yet active passes the check.
- Temporary CI setting: `tflint` runs with `--recursive --minimum-failure-severity=error`
  because 12 module warnings predate the split. The flag is to be removed in the cleanup PR once
  warnings reach zero.
- Apply order is infra, then cluster. Teardown is the reverse (see README).

## Alternatives considered

- Public endpoint restricted by CIDR: rejected (shared VPN exit IP; GitHub-hosted runner IPs not
  allow-listable).
- Self-hosted runners in the VPC: rejected (public repository with `pull_request` workflows).
- Keep a single root module: rejected, because one apply would need both AWS API access and
  access to the private cluster endpoint, and a stage-1-only plan in CI needs only the former.

## Known issues to fix before the first apply

| Issue | Status | Detail |
|---|---|---|
| `t3.micro` pod limit | to verify (max pods) | Sizing changed to `t3.medium`, min 2 / desired 2 / max 3 (variables `system_node_*` in `modules/eks_cluster`). Verified with `describe-instance-types`: `t3.micro` 2 ENIs x 2 IPv4, `t3.small` 3 x 4, `t3.medium` 3 x 6; the VPC CNI formula gives 4, 11 and 17 max pods. Verified from `helm template`: the system pods need 13 pod slots (Argo CD 7, LB controller 2, Karpenter 2, CoreDNS 2) and Karpenter has hard per-host anti-affinity (needs 2 nodes). To verify on a live node: the actual max pods (`kubectl get node -o jsonpath='{..allocatable.pods}'`), DaemonSet slot use (`aws-node`, `kube-proxy`, Pod Identity agent assumed to take 3 per node), and real memory use (the charts set no resource requests). |
| EKS `cluster_version = "1.35"` | verified | `aws eks describe-cluster-versions --region us-east-1` (2026-10-02): 1.35 is `STANDARD_SUPPORT`, standard support ends 2027-03-27, extended support ends 2028-03-27; 1.36 is the latest (standard support ends 2027-08-02). Policy: one minor behind the latest. Previous default 1.31 is in `EXTENDED_SUPPORT` (extended support ends 2026-11-26). Extended support pricing is not recorded here (see the AWS EKS pricing page). |
| `karpenter-nodepool.yaml`: name mismatch | fixed, not applied | The `EC2NodeClass` was named `entorno-juan-eslava` while the `NodePool` `nodeClassRef.name` was `default`. Both are now `default`. |
| `karpenter-nodepool.yaml`: `amiFamily: AL2` | fixed, not applied | The system node group uses `AL2023_x86_64_STANDARD`, so the two disagree. Per AWS (https://docs.aws.amazon.com/eks/latest/userguide/al2023.html) EKS stopped publishing EKS-optimized AL2 AMIs on 2025-11-26 and AL2023 and Bottlerocket AMIs are available for Kubernetes 1.33 and higher, so AL2 nodes cannot be launched on 1.35. Replaced by `amiSelectorTerms` with alias `al2023@v20260930`, pinned. Verified (2026-10-02, us-east-1): SSM parameter `/aws/service/eks/optimized-ami/1.35/amazon-linux-2023/x86_64/standard/amazon-eks-node-al2023-x86_64-standard-1.35-v20260930/image_id` exists, and Karpenter v1.14.1 `pkg/providers/amifamily/al2023.go` resolves pinned aliases through that path. The pin must be bumped on purpose; the alias is resolved against the cluster Kubernetes version. |
| Apply order for EKS 1.35 | verified (decision) | No aplicar hasta fusionar los PRs de Karpenter (chart >= 1.9, probable 1.14.1, manifiestos v1, AL2023), add-ons gestionados, Argo CD y AWS Load Balancer Controller. The Karpenter compatibility table (`kubernetes-sigs`/`aws` repo, `upgrading/compatibility.md`) requires Karpenter >= 1.9 for Kubernetes 1.35; the pinned chart 0.37.0 and the `v1beta1` manifests do not meet it. |
| Open risk: Argo CD chart 7.3.11 | not verified | appVersion v2.11.7; the upstream tested-versions table lists Kubernetes 1.25 to 1.29 only. The chart `kubeVersion` is `>=1.23.0-0`, so Helm will not block it, but compatibility with 1.35 is untested. |
| Open risk: AWS Load Balancer Controller chart 1.8.1 | not verified | appVersion v2.8.1; the docs state only "v2.5.0+ requires Kubernetes 1.22+" with no upper bound, and there is no statement for 1.34 to 1.36. |
| Hardcoded Karpenter node role name | partly fixed | `karpenter-nodepool.yaml` sets `role: "karpenter-node-eks-gitops-production"`. The module created the role with a random suffix (`node_iam_role_use_name_prefix` defaults to true), so the name never matched; it is now `false` and the role is exactly `karpenter-node-${cluster_name}` (output `karpenter_node_role_name`). The manifest still matches only when `environment = production` (the default); the discovery tags use the same hardcoded cluster name. Follow-up: Kustomize overlay or patch to avoid fixed strings (Argo CD supports it natively); not done to keep the plain-YAML layout. |
| Karpenter chart 1.14.1 and IAM | fixed, not applied | Chart `1.14.1` with `settings.clusterName` and `settings.interruptionQueue` (unchanged keys). `enable_v1_permissions = true` plus four actions from the v1.14.1 `cloudformation.yaml` that module 20.37.2 lacks (`ec2:DescribeCapacityReservations`, `ec2:DescribeInstanceStatus`, `ec2:DescribePlacementGroups`, `iam:ListInstanceProfiles`). CRDs ship in the chart `crds/` directory (installed on first install only, never upgraded by Helm); the `karpenter-crd` chart 1.14.1 exists and is the follow-up for upgrades. Not verified: the rendered controller policy size against the 6144-character managed policy limit (unknown at plan time). |
| `aws_eks_addon` data source checks existence, not readiness | verified | See Consequences. |
