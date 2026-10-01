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
| EKS `cluster_version = "1.31"` | verified | `aws eks describe-cluster-versions` (2026-10-01): 1.31 is in `EXTENDED_SUPPORT` (standard support ended 2025-11-26, extended support ends 2026-11-26). Standard support: 1.34 to 1.36. The version is unchanged pending a decision; extended support pricing is not recorded here (see the AWS EKS pricing page). |
| `karpenter-nodepool.yaml`: name mismatch | verified | The `EC2NodeClass` is named `entorno-juan-eslava` but the `NodePool` `nodeClassRef.name` is `default`, so the reference does not resolve. |
| `karpenter-nodepool.yaml`: `amiFamily: AL2` | partly verified | Verified: the system node group uses `AL2023_x86_64_STANDARD`, so the two disagree. To verify: whether AL2 AMIs are still available for the cluster version (`1.31`) and supported by Karpenter v0.37.0. |
| Hardcoded Karpenter node role name | verified | `karpenter-nodepool.yaml` sets `role: "karpenter-node-eks-gitops-production"`. The Terraform role is `karpenter-node-${cluster_name}` with `cluster_name = eks-gitops-${environment}`. They match only when `environment = production` (the default); the discovery tags use the same hardcoded cluster name. |
| `aws_eks_addon` data source checks existence, not readiness | verified | See Consequences. |
