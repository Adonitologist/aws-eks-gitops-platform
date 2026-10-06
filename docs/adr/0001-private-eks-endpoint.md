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
4. CI validates both stacks (`init -backend=false`, `validate`, `tflint`, `trivy config`) and plans
   stage 1 only. CI never plans or applies stage 2 and never initializes it with a backend.
5. The Karpenter release needs the Pod Identity agent, which stage 1 creates. A cross-stack
   `depends_on` does not exist, so stage 2 uses `data "aws_eks_addon"` to fail the plan when the
   addon is absent, and the README documents the apply order.

## Consequences

- Stage 1 needs only AWS API access and is the only stack planned in CI.
- Stage 2 is applied from a host with a network path to the private endpoint. The access path is
  decided in [ADR 0002](0002-stage2-access-path.md): an operator-run, SSM-only EC2 runner created by
  stage 1. Applying stage 2 from a laptop is not possible.
- The state was empty when the split was made, so no `terraform state mv` or `removed` blocks were
  needed.
- The `aws_eks_addon` data source checks that the addon exists. It does not check readiness: the
  data source exposes no status attribute (verified from the AWS provider 5.x schema), so an addon
  that exists but is not yet active passes the check.
- Resolved: the temporary `--minimum-failure-severity=error` flag on `tflint` was removed
  (`.tflint.hcl` added, warnings now fail CI); it existed only because 12 module warnings
  predated the split.
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
| System node pod limit and sizing | partly verified | Sizing: `m7i-flex.large` (x86_64, default of `system_node_instance_types` in `modules/eks_cluster`), min 2 / desired 2 / max 3. `t3.medium` failed on 2026-10-03: the node group went to `CREATE_FAILED` with `InvalidParameterCombination - The specified instance type is not eligible for Free Tier` (see the row "AWS Free Tier plan"). Verified with `describe-instance-types` (2026-10-04, us-east-1): `m7i-flex.large` 3 ENIs x 10 IPv4, 8192 MiB; `c7i-flex.large` 3 x 10, 4096 MiB; `t3.small` 3 x 4, 2048 MiB. The formula ENIs x (IPs - 1) + 2 (AL2023 nodeadm `eni_max_pods.go:77-79`, awslabs/amazon-eks-ami `main`, not re-read and not the AMI release in use) gives 29, 29 and 11 max pods; these are computed, not measured. Verified from `helm template` (2026-10-04, charts as pinned in the repo): Argo CD 10.9.6 renders 7 pods (6 Deployments and 1 StatefulSet, 1 replica each), LB controller 3.5.0 renders 2, Karpenter 1.14.1 renders 2; none renders a DaemonSet. CoreDNS is assumed to run 2 replicas. That is 13 system pods plus 3 DaemonSet pods per node (`aws-node`, `kube-proxy`, `eks-pod-identity-agent`), so 19 pods on 2 nodes and 16 of 29 in the worst case on one node. `t3.small` (11 max pods, 16 usable slots on 2 nodes against 13 needed) was rejected: no margin if a node is lost. Karpenter has hard per-host anti-affinity (one replica per node) and a zone spread with `DoNotSchedule`, so losing one node leaves Karpenter's second replica Pending. The three charts set no resource requests or limits, so memory is not enforced by scheduling. To verify after the first apply: the CoreDNS replica count and spread (assumed 2), whether hostNetwork DaemonSet pods count toward max pods (assumed yes), the actual max pods on a live node (`kubectl get node -o jsonpath='{..allocatable.pods}'`), the kubelet memory reservation (not read) and real memory use of the system pods on 8192 MiB. |
| AWS Free Tier plan | partly verified | The account is on the Free Tier plan (`get-account-information` first timestamp 2026-06-12, read as the creation date; not in an AWS Organization). Per https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html the plan gives a USD 100 credit plus up to USD 100 more from activities, and ends after six months or when the credits are used, whichever comes first (latest end 2026-12-12 if the creation date is right); then the account closes and there are 90 days to upgrade. Eligible instance types (`describe-instance-types --filters Name=free-tier-eligible,Values=true`, 2026-10-04): `c7i-flex.large`, `m7i-flex.large`, `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `t8i.micro`, `t8i.small`. A non-eligible type fails at launch (the `t3.medium` node group failure above). EKS has no free tier: USD 0.10 per cluster-hour on standard support (https://aws.amazon.com/eks/pricing/). On-demand prices (AWS Pricing API, us-east-1, Linux, queried 2026-10-04): `m7i-flex.large` 0.09576, `c7i-flex.large` 0.08479, `t3.small` 0.0208 USD/h. Estimate at 730 h/month: 2 x `m7i-flex.large` 139.8 + EKS control plane 73.0 = about 213 USD/month, before the NAT gateway (price not queried), the runner, EBS and data transfer, so the USD 100 credit lasts about two weeks. Approach: a short test, then destroy following the README "Safe Teardown Protocol"; do not leave the cluster running. The published Free Tier policy for accounts of the "new AWS experience" (https://docs.aws.amazon.com/accounts/latest/reference/scps-and-rcps-for-projects.html, section "Service control policies for the Free Tier for projects") denies `ec2:CreateFleet`, `ec2:RequestSpotInstances` and `ec2:RunInstances` with `ec2:InstanceMarketType=spot`. Karpenter v1 launches through `CreateFleet` (the module policy allows it). Hence `kubernetes/workloads/karpenter-nodepool.yaml` allows on-demand only and only `m7i-flex.large` and `c7i-flex.large`, with limits cpu 8 / memory 32Gi. To verify: whether that policy applies to this account (NOT VERIFIED; the first Karpenter launch will show it, and if `CreateFleet` is denied Karpenter cannot provision nodes), the NAT gateway price, whether the flex types draw on the credits (inferred yes), and the real credit balance in the Billing console. |
| EKS `cluster_version = "1.35"` | verified | `aws eks describe-cluster-versions --region us-east-1` (2026-10-02): 1.35 is `STANDARD_SUPPORT`, standard support ends 2027-03-27, extended support ends 2028-03-27; 1.36 is the latest (standard support ends 2027-08-02). Policy: one minor behind the latest. Previous default 1.31 is in `EXTENDED_SUPPORT` (extended support ends 2026-11-26). Extended support pricing is not recorded here (see the AWS EKS pricing page). |
| `karpenter-nodepool.yaml`: name mismatch | fixed, not applied | The `EC2NodeClass` was named `entorno-juan-eslava` while the `NodePool` `nodeClassRef.name` was `default`. Both are now `default`. |
| `karpenter-nodepool.yaml`: `amiFamily: AL2` | fixed, not applied | The system node group uses `AL2023_x86_64_STANDARD`, so the two disagree. Per AWS (https://docs.aws.amazon.com/eks/latest/userguide/al2023.html) EKS stopped publishing EKS-optimized AL2 AMIs on 2025-11-26 and AL2023 and Bottlerocket AMIs are available for Kubernetes 1.33 and higher, so AL2 nodes cannot be launched on 1.35. Replaced by `amiSelectorTerms` with alias `al2023@v20260930`, pinned. Verified (2026-10-02, us-east-1): SSM parameter `/aws/service/eks/optimized-ami/1.35/amazon-linux-2023/x86_64/standard/amazon-eks-node-al2023-x86_64-standard-1.35-v20260930/image_id` exists, and Karpenter v1.14.1 `pkg/providers/amifamily/al2023.go` resolves pinned aliases through that path. The pin must be bumped on purpose; the alias is resolved against the cluster Kubernetes version. |
| Apply order for EKS 1.35 | verified (decision) | The Argo CD and AWS Load Balancer Controller chart bumps (branch `feat/argocd-lbc-upgrade`) were the last blocker; apply only after that PR is merged. The Karpenter compatibility table (aws/karpenter-provider-aws, `website/content/en/preview/upgrading/compatibility.md`) requires Karpenter >= 1.9 for Kubernetes 1.35. Chart 1.14.1 and the `v1` manifests are merged (not applied), and the EKS managed add-ons are merged (not applied). Remaining after the first apply: the "to verify after the first apply" items in this table (CoreDNS replicas, max pods on a live node, add-on adoption, real memory use). |
| Argo CD chart 10.9.6 | verified (docs), not tested on a live cluster | appVersion v3.5.3, chart `kubeVersion` `>=1.25.0-0`. `docs/operator-manual/tested-kubernetes-versions.md` at tag v3.5.3 lists Argo CD 3.5 with v1.36, v1.35, v1.34, v1.33 (https://github.com/argoproj/argo-cd/blob/v3.5.3/docs/operator-manual/tested-kubernetes-versions.md); there is no row for Argo CD 2.x, so the old chart 7.3.11 (appVersion v2.11.7) had no 1.35 statement. Upgrade guides (`docs/operator-manual/upgrading/` on argo-cd master): 2.14 to 3.0, 3.0 to 3.1, 3.1 to 3.2, 3.2 to 3.3, 3.3 to 3.4 and 3.4 to 3.5 were read for breaking changes; 2.11 to 2.12, 2.12 to 2.13 and 2.13 to 2.14 were only skimmed (headings and keyword grep), not read line by line. No hit against `kubernetes/` or our chart values (fresh install, no custom `argocd-cm` or RBAC). Chart changelog (argo-helm `charts/argo-cd/README.md`): 8.0.0 deploys Argo CD v3, 9.0.0 drops `configs.params` defaults, 10.0.0 enables NetworkPolicies by default; none affects our values. `server.ingress.paths` in `modules/gitops_argocd/main.tf` is not a chart key (the chart key is `path`), so it is ignored and the default `/` applies; left unchanged. Rendered with `helm template`: 7 pods, soft anti-affinity only. |
| Open risk: AWS Load Balancer Controller chart 3.5.0 | not verified | appVersion v3.5.0. There is no documented Kubernetes 1.35 statement for any controller version; the docs state only the lower bound 1.22+ (`docs/deploy/installation.md` at v3.5.0: "v2.5.0+ requires Kubernetes 1.22+"). The IAM policy of terraform-aws-modules/iam 5.60.0 (`attach_load_balancer_controller_policy`) equals `iam_policy.json` at v3.5.0 for action, resource and condition (98 of 98 action, resource and condition combinations; compared with a script, not with a rendered Terraform plan). Our values keys (`clusterName`, `serviceAccount.*`) are unchanged in 3.5.0. Rendered with `helm template`: 2 pods, soft anti-affinity only. |
| LB controller CRDs | verified (docs) | Helm installs `crds/` on first install only; `helm upgrade` and the Terraform `helm_release` never install or upgrade CRDs (helm-www `docs/topics/charts.mdx`, "Limitations on CRDs"; `docs/deploy/installation.md` at v3.5.0: "The `helm install` command automatically applies the CRDs, but `helm upgrade` doesn't"). A later chart bump needs a manual `kubectl apply -f` of the chart `crds/` files before the upgrade (chart 3.5.0 ships `crds.yaml` and `gateway-crds.yaml`; the v3.5.0 release notes ask for CRDs first). No `skip_crds` is set in `modules/eks_addons_helm/main.tf`. We use Ingress only, so the Gateway API CRDs are not needed. |
| Argo CD 10.x NetworkPolicies | verified (render), partly verified (VPC CNI default) | Since chart 10.0.0 `global.networkPolicy.create` defaults to true; we keep the chart default. The render has 6 NetworkPolicies (the server policy allows all ingress, so the ALB path is not blocked). They have no effect while the VPC CNI `enableNetworkPolicy` is off: this repo sets no `configuration_values` for the add-on and the upstream chart default is `"false"` (amazon-vpc-cni-k8s v1.22.4, `charts/aws-vpc-cni/values.yaml:126`). Not verified: the EKS managed add-on default for `v1.22.4-eksbuild.3`. Review these policies before enabling network policy enforcement. |
| Avoid LB controller v3.4.1 | verified (release notes) | The v3.4.1 release notes carry a security notice (HTTPRoute and GRPCRoute precedence on shared Gateways); fixed in v3.4.2. Do not pin 3.4.1. |
| Hardcoded Karpenter node role name | partly fixed | `karpenter-nodepool.yaml` sets `role: "karpenter-node-eks-gitops-production"`. The module created the role with a random suffix (`node_iam_role_use_name_prefix` defaults to true), so the name never matched; it is now `false` and the role is exactly `karpenter-node-${cluster_name}` (output `karpenter_node_role_name`). The manifest still matches only when `environment = production` (the default); the discovery tags use the same hardcoded cluster name. Follow-up: Kustomize overlay or patch to avoid fixed strings (Argo CD supports it natively); not done to keep the plain-YAML layout. |
| Karpenter chart 1.14.1 and IAM | fixed, not applied | Chart `1.14.1` with `settings.clusterName` and `settings.interruptionQueue` (unchanged keys). `enable_v1_permissions = true`. Four actions from the v1.14.1 `cloudformation.yaml` that module 20.37.2 lacks (`ec2:DescribeCapacityReservations`, `ec2:DescribeInstanceStatus`, `ec2:DescribePlacementGroups`, `iam:ListInstanceProfiles`) live in a separate managed policy `karpenter-controller-extra-<cluster_name>` attached through the module `iam_role_policies`, because module policy plus extras was 6067 of 6144 non-whitespace characters. Rendered sizes (scratch render, placeholder queue ARN, 2026-10-02): module policy 5708 (margin 436, 7.1%), extra policy 397. Risk: the base module policy is still within 10% of the limit, so a module upgrade that adds statements can overflow it. CRDs ship in the chart `crds/` directory (installed on first install only, never upgraded by Helm); the `karpenter-crd` chart 1.14.1 exists and is the follow-up for upgrades. Verified from a saved plan of `stacks/infra` (JSON): the node security group `module.eks_cluster.module.eks.aws_security_group.node[0]` carries `karpenter.sh/discovery = eks-gitops-production` (the cluster security group carries it too), and the new policy and its attachment are planned as creates. |
| EKS managed add-ons (vpc-cni, coredns, kube-proxy, eks-pod-identity-agent) | fixed, not applied | `aws_eks_addon` for_each in `modules/eks_addons` (stage 1), versions pinned by variables to the EKS 1.35 default versions (`aws eks describe-addon-versions`, 2026-10-02): vpc-cni `v1.22.4-eksbuild.3`, coredns `v1.13.2-eksbuild.31`, kube-proxy `v1.35.3-eksbuild.29`, eks-pod-identity-agent `v1.3.10-eksbuild.3`. Newer versions exist for 1.35 (vpc-cni `v1.23.2-eksbuild.1`, coredns `v1.14.6-eksbuild.4`, eks-pod-identity-agent `v1.4.0-eksbuild.3`) and are not used. `bootstrap_self_managed_addons` is left unset, so EKS installs the self-managed add-ons at cluster creation and the managed add-ons adopt them with `resolve_conflicts_on_create = OVERWRITE` (`NONE` would fail on field conflicts); changing `bootstrap_self_managed_addons` later forces a new cluster (provider docs), and with `false` vpc-cni would have to move to `cluster_addons` with `before_compute`. Max pods stay at 17 on `t3.medium` (VPC CNI without prefix delegation), which covers the 13 system pod slots. Prefix delegation is an option (`ENABLE_PREFIX_DELEGATION` via `configuration_values`), not enabled. Verified from a saved plan of `stacks/infra`: the four add-ons are creates with these versions and there are no replacements or destroys. Not verified: adoption of the bootstrapped add-ons on a live cluster. |
| Add-on ordering | verified | `aws_eks_addon.managed` in `modules/eks_addons` has no direct dependency on the managed node group: it references only `local.managed_addons` and `var.cluster_name` (checked in the `terraform graph -type=plan` output). Ordering after the node group comes only from `depends_on = [module.eks_cluster]` at `stacks/infra/main.tf:29` (module call at lines 23-30); keep that `depends_on` if the module call is moved. The four add-ons are created in parallel. To verify after the first apply: that the node group is ACTIVE with Ready nodes before CoreDNS is created. |
| CNI policy | verified | `iam_role_attach_cni_policy` defaults to `true` in terraform-aws-modules/eks 20.37.2 (`eks-managed-node-group/variables.tf:537-541`, passed through at `node_groups.tf:397`, attachment logic at `main.tf:499-501`, under `.terraform/modules/eks_cluster.eks`). The saved plan of `stacks/infra` creates `aws_iam_role_policy_attachment.this["AmazonEKS_CNI_Policy"]` for the `system_components` node group role and the `AmazonEKS_CNI_Policy` attachment for the Karpenter node role. |
| `aws_eks_addon` data source checks existence, not readiness | verified | See Consequences. |

## Addendum 2026-10-04: live run results

Reported by the operator from the live run of 2026-10-04; raw output not retained in the repo; not independently verified.

The original text above is unchanged.

Measured on the live run:

- 29 allocatable pods per node. Karpenter launched no node, so only system node group nodes were measured.
- CoreDNS ran with 2 replicas; the managed add-ons were adopted and ACTIVE.
- The stage 2 runner registered in SSM with the minimal policy and `user_data` worked.
- The Karpenter NodePool and EC2NodeClass reached READY via Argo CD.
- Argo CD, AWS Load Balancer Controller and Karpenter pods were Running and an ALB was created.

Open items (not verified by the live run):

- `ec2:CreateFleet` under the Free Tier policy (Karpenter never launched a node).
- Real memory use of the system pods.
- Managed vpc-cni `enableNetworkPolicy` default.
- AWS Load Balancer Controller 3.5.0 on Kubernetes 1.35 (no official statement; not verified).
- Argo CD 2.11 to 2.14 upgrade guides (only skimmed).
- Terraform GPG signature check on the runner.
- CloudWatch and NAT costs.
- Whether the runner needs `elasticloadbalancing:Describe*`.
