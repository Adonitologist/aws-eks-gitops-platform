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
| Argo CD chart 10.9.6 | verified (docs); ran on a live cluster 2026-10-11 (addendum 2026-10-12) | appVersion v3.5.3, chart `kubeVersion` `>=1.25.0-0`. `docs/operator-manual/tested-kubernetes-versions.md` at tag v3.5.3 lists Argo CD 3.5 with v1.36, v1.35, v1.34, v1.33 (https://github.com/argoproj/argo-cd/blob/v3.5.3/docs/operator-manual/tested-kubernetes-versions.md); there is no row for Argo CD 2.x, so the old chart 7.3.11 (appVersion v2.11.7) had no 1.35 statement. Upgrade guides (`docs/operator-manual/upgrading/` on argo-cd master): 2.14 to 3.0, 3.0 to 3.1, 3.1 to 3.2, 3.2 to 3.3, 3.3 to 3.4 and 3.4 to 3.5 were read for breaking changes; 2.11 to 2.12, 2.12 to 2.13 and 2.13 to 2.14 were only skimmed (headings and keyword grep), not read line by line. No hit against `kubernetes/` or our chart values (fresh install, no custom `argocd-cm` or RBAC). Chart changelog (argo-helm `charts/argo-cd/README.md`): 8.0.0 deploys Argo CD v3, 9.0.0 drops `configs.params` defaults, 10.0.0 enables NetworkPolicies by default; none affects our values. `server.ingress.paths` in `modules/gitops_argocd/main.tf` is not a chart key (the chart key is `path`), so it is ignored and the default `/` applies; left unchanged. Rendered with `helm template`: 7 pods, soft anti-affinity only. |
| Open risk: AWS Load Balancer Controller chart 3.5.0 | not verified | appVersion v3.5.0. There is no documented Kubernetes 1.35 statement for any controller version; the docs state only the lower bound 1.22+ (`docs/deploy/installation.md` at v3.5.0: "v2.5.0+ requires Kubernetes 1.22+"). The IAM policy of terraform-aws-modules/iam 5.60.0 (`attach_load_balancer_controller_policy`) equals `iam_policy.json` at v3.5.0 for action, resource and condition (98 of 98 action, resource and condition combinations; compared with a script, not with a rendered Terraform plan). Our values keys (`clusterName`, `serviceAccount.*`) are unchanged in 3.5.0. Rendered with `helm template`: 2 pods, soft anti-affinity only. |
| LB controller CRDs | verified (docs) | Helm installs `crds/` on first install only; `helm upgrade` and the Terraform `helm_release` never install or upgrade CRDs (helm-www `docs/topics/charts.mdx`, "Limitations on CRDs"; `docs/deploy/installation.md` at v3.5.0: "The `helm install` command automatically applies the CRDs, but `helm upgrade` doesn't"). A later chart bump needs a manual `kubectl apply -f` of the chart `crds/` files before the upgrade (chart 3.5.0 ships `crds.yaml` and `gateway-crds.yaml`; the v3.5.0 release notes ask for CRDs first). No `skip_crds` is set in `modules/eks_addons_helm/main.tf`. We use Ingress only, so the Gateway API CRDs are not needed. |
| Argo CD 10.x NetworkPolicies | verified (render), partly verified (VPC CNI default) | Since chart 10.0.0 `global.networkPolicy.create` defaults to true; we keep the chart default. The render has 6 NetworkPolicies (the server policy allows all ingress, so the ALB path is not blocked). They have no effect while the VPC CNI `enableNetworkPolicy` is off: this repo sets no `configuration_values` for the add-on and the upstream chart default is `"false"` (amazon-vpc-cni-k8s v1.22.4, `charts/aws-vpc-cni/values.yaml:126`). Not verified: the EKS managed add-on default for `v1.22.4-eksbuild.3`. Review these policies before enabling network policy enforcement. |
| Argo CD ingress host | verified (render); answered 200 on a live cluster 2026-10-11 (addendum 2026-10-12) | Chart 10.9.6 always renders `host:` from `global.domain` (default `argocd.example.com`), so the ALB DNS name never matched. `ingress_hostname` (stack variable `argocd_hostname`, default empty) sets `global.domain`; empty renders `host:` empty (`helm template` before/after diff on 2026-10-07: host, `argocd-cm` `url` and notifications `argocdUrl` change, pods roll). An empty hostname leaves `argocd-cm` `url` as `https://` (only SSO callbacks and notification links use it; neither is configured). Stage 2 plan NOT VERIFIED locally. Live test: `kubectl get ingress -n argocd` shows HOSTS `*` and the ALB DNS name in ADDRESS; `curl -I http://<alb-dns>/` is answered by Argo CD; the ALB listener rule has no host-header condition. |
| Argo CD ALB inbound-cidrs | verified (docs, render); allowed network answered 200 on a live cluster 2026-10-11, rejection operator-observed only (addendum 2026-10-12) | `alb.ingress.kubernetes.io/inbound-cidrs` is a comma-separated stringList; the controller ignores it only if `alb.ingress.kubernetes.io/security-groups` is set (we do not set it), and without it the controller-managed security group allows only those CIDRs on the listen ports (`docs/guide/ingress/annotations.md` at tag v3.5.0, https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.5.0/docs/guide/ingress/annotations.md). Built from the required variable `argocd_allowed_cidrs` (IPv4, non-empty, `0.0.0.0/0` rejected); `helm template` adds only that annotation. Stage 2 plan NOT VERIFIED locally. Risk: a wrong or outdated CIDR locks you out of the ALB until stage 2 is applied again; every stage 2 `plan`, `apply` and `destroy` needs `-var`. Live test: the annotation is on the ingress, the ALB security group allows port 80 only from the CIDR, `curl -I http://<alb-dns>/` works from the allowed IP and times out from another network. |
| Avoid LB controller v3.4.1 | verified (release notes) | The v3.4.1 release notes carry a security notice (HTTPRoute and GRPCRoute precedence on shared Gateways); fixed in v3.4.2. Do not pin 3.4.1. |
| Hardcoded Karpenter node role name | partly fixed; Kustomize evaluated, not done (addendum 2026-10-12) | `karpenter-nodepool.yaml` sets `role: "karpenter-node-eks-gitops-production"`. The module created the role with a random suffix (`node_iam_role_use_name_prefix` defaults to true), so the name never matched; it is now `false` and the role is exactly `karpenter-node-${cluster_name}` (output `karpenter_node_role_name`). The manifest still matches only when `environment = production` (the default); the discovery tags use the same hardcoded cluster name. Follow-up: Kustomize overlay or patch to avoid fixed strings (Argo CD supports it natively); not done to keep the plain-YAML layout. |
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

## Addendum 2026-10-11: live run results

Measured by the operator on a live run of 2026-10-11; raw output retained locally, masked, not in the repo. The original text and the 2026-10-04 addendum are unchanged; this addendum closes some of its open items.

| Item | Result |
|---|---|
| `ec2:CreateFleet` under the Free Tier policy | OK: `c7i-flex.large`, on-demand; about 35 s from Pending pod to Ready node |
| Node capacity of the Karpenter node | allocatable pods 29, cpu 1930m, memory 3114Mi |
| Consolidation of empty nodes | OK: about 4 min after the load was deleted |
| Argo CD ingress | `argocd-server` ingress with host `*`; ALB created by the LB controller |
| UI access | reachable from the allowed CIDR (login page) |
| ALB tag | `elbv2.k8s.aws/cluster=eks-gitops-production` |
| `tag:GetResources` from the runner | works |
| Root application | created with `kubectl apply -f`; Synced/Healthy; NodePool and EC2NodeClass READY |
| vpc-cni `enableNetworkPolicy` default | `aws-node` runs with `--enable-network-policy=false` |
| Teardown script | OK: ingress deleted, no ALB left after about 31 s; NodePool and EC2NodeClass were already removed by the root-app cascade |
| Destroy | stage 2: 4 resources; stage 1: 117 resources; no leftovers afterwards |
| Stage 1 apply duration | about 13 min (EKS control plane 10m21s) |

Findings:

- `gnupg2-minimal` lacks `gpg-agent` (fixed in PR #39, see ADR 0002).
- `kubectl top` fails because metrics-server is not installed. System pod memory was measured only as requests, roughly 45-80% of allocatable.
- Kubernetes warns about the unqualified finalizer name in `kubernetes/argocd-apps/root-app.yaml`.

Not tested: rejection of the ALB from another network, the teardown wait with live Karpenter nodes, the fixed `user_data` on a recreated runner.

Account id, ARNs, the ALB DNS name and the operator IP are masked in all records of this run.

## Addendum 2026-10-12: live test 2 results

Reported by the operator from the live test of 2026-10-11 (apply 19:41 local to destroy end 21:29 local, 17:41 to 19:29 UTC, about 1 h 50 min including fixes); raw terminal output is not stored in the repo. Older addenda are unchanged. This one supersedes the "Not tested" line of the 2026-10-11 addendum, except where noted.

- Stage 1: 117 resources created. Stage 2: 4 created (LB controller 3.5.0, Karpenter 1.14.1, Argo CD chart 10.9.6, namespace `argocd`).
- Argo CD: `root-application` Synced and Healthy. The sample app pod ran 1/1 as uid/gid 10101 with a read-only root filesystem and writable `/tmp`; readiness and liveness returned 200; port-forward from the runner returned HTTP 200. It landed on a system node.
- ALB: Argo CD answered 200 from the allowed /32 network. Rejection from a mobile network without VPN was observed by the operator and reported as the expected result (not independently verified).
- Karpenter: a throwaway pod forced a node; NodeClaim Ready and pod Running in about 33 s (`c7i-flex.large`, on-demand, us-east-1b). The nodes pull from `public.ecr.aws`.
- Teardown with the live Karpenter node: ALB gone in about 24 s, root-application deletion about 35 s, and its cascade removed the NodePool, EC2NodeClass and the node. The script's final Karpenter wait loop passed immediately and was not exercised. Stage 2 destroy: 4 destroyed (about 1 min).
- Stage 1 destroy failed twice, both fixed by hand: (1) `DeleteSecurityGroup` `DependencyViolation` from an orphan VPC CNI ENI (status `available`, tags `eks:eni:owner=amazon-vpc-cni`, cluster name and the instance id of the terminated Karpenter node); (2) `DeleteVpc` `DependencyViolation` from the EKS-created cluster security group `eks-cluster-sg-<cluster>-<n>`, which is not in Terraform. The destroy then completed (1 resource). Afterwards no EKS, EC2, NAT, load balancer, volume, IAM role, SSM document, SQS queue or KMS alias of the cluster remained. Mitigation: PR #60 (`scripts/teardown/check-leftovers.ps1`, README Safe Teardown step 6).
- Cost: see the README "Cost" day total; it is account-wide for 2026-10-11 UTC and is not attributed to this test alone.

## Addendum 2026-10-12: network policy

Added, nothing verified yet (the next live test is the first run): `enableNetworkPolicy = true` on the `vpc-cni` managed add-on (variable `vpc_cni_enable_network_policy`, default true, `modules/eks_addons`); `kubernetes/workloads/sample-app/networkpolicy.yaml` (default deny plus DNS and same-namespace exceptions); and `kubernetes/tests/netpol-test.yaml` (two throwaway clients, not synced by Argo CD). The README Post-Deploy Checklist has the demonstration.

Rendered with `helm template`, the Argo CD chart 10.9.6 policies (enabled by default since chart 10.0.0) are Ingress-only and none denies by default, and the Karpenter and AWS Load Balancer Controller charts create none. The one open risk: kubelet probes to pods that a policy selects (repo-server and the application controller probe the `metrics` port) come from the node IP, which no policy rule names; whether the VPC CNI agent always allows node traffic is not documented in the pages read. Fallback: `global.networkPolicy.create = false` in `modules/gitops_argocd/main.tf`, or `vpc_cni_enable_network_policy = false`. Also not verified: whether the managed CoreDNS add-on ships a policy, the AL2023 kernel number, the agent's CPU and memory requests, and the plan behavior of a `configuration_values` change on a live cluster.

## Addendum 2026-10-12: Karpenter names and Kustomize

Delta against the row "Hardcoded Karpenter node role name" (follow-up: Kustomize overlay or patch). Kustomize for the Karpenter names was evaluated and deliberately not done. Reasons:

- `kubernetes/argocd-apps/root-app.yaml` uses an explicit `directory` source with `recurse: true`. Per the Argo CD tool detection docs an explicitly configured tool wins, so a `kustomization.yaml` alone would not be used; using it needs a change to the root app, and any manifest not listed in `resources:` (for example the sample app) would drop out and, with `prune: true`, be deleted from the cluster.
- Rendering the manifests from Terraform would move the NodePool and EC2NodeClass out of Argo CD. The teardown relies on the root-application cascade to remove them (README Safe Teardown), so tearing down stage 2 could remove Karpenter while nodes still exist.
- Only one environment exists (`production`, the default and the value CI plans with), so there is nothing to vary.

Instead, `scripts/ci/check-karpenter-names.sh` now also requires exactly one NodePool and one EC2NodeClass and that the NodePool `nodeClassRef.name` equals the EC2NodeClass `metadata.name`. The check still validates only the default environment. Not verified: behavior of a `kustomization.yaml` under `directory.recurse: true`, and Kustomize `replacements` for this layout (evaluation, not tested).

## Addendum 2026-10-12: live test 3 results

Reported by the operator from the live test of 2026-10-12 (cluster `us-east-1`, EKS 1.35.8, Argo CD v3.5.3 / chart 10.9.6, Karpenter 1.14.1); raw terminal output is not stored in the repo. Earlier addenda are unchanged. This one supersedes the "nothing verified yet" statement of the "network policy" addendum and the "NOT VERIFIED live" statements about the leftover-check filters and the final Karpenter wait loop, except where noted below.

Timeline (Europe/Madrid local time, "about" = derived from resource timestamps):

- Stage 1 apply started 14:31 and finished about 14:52 (about 20 min, 117 added). Stage 2 apply about 1 min (Argo CD release 45 s, 4 added). Root application created and first synced 15:07. Karpenter probe 15:15. Teardown scripts 15:23 to 15:37.
- Stage 2 destroy: 4 destroyed in about 10 s; the `argocd` namespace did not hang. Helm kept the three Argo CD CRDs by resource policy (expected).
- Stage 1 destroy 15:42 to about 15:52: 117 destroyed, NAT gateway destroy 1 min 2 s, no manual intervention. Whole test about 1 h 25 min.
- The apply used the first MFA session and the destroy a fresh one (cache cleared). A Terraform run longer than 1 hour was not exercised (longest run about 20 min).

VERIFIED:

- Network policy enforcement: `aws-node` pods 2/2; policyendpoints existed for the 6 Argo CD policies and the 3 sample-app policies. From the same namespace nginx answered; from another namespace `wget` timed out; egress to the internet timed out; DNS from `sample-app` was allowed. All 7 Argo CD pods and the sample app stayed 1/1 Running with 0 restarts after more than 4 minutes under the policies, so the kubelet probe fallback was not needed. `kube-system` has no NetworkPolicy (the managed CoreDNS add-on adds none).
- Karpenter node: Amazon Linux 2023.12.20260928, kernel 6.12.110-135.201.amzn2023 (5.10 or later), containerd 2.2.7, `c7i-flex.large` on-demand, NodeClaim to Ready in 37 s. The pinned `busybox:1.36` digest pulled fine.
- Instance tags (keys only). Runner: `Environment`, `Component`, `Name`. Managed node group nodes: `karpenter.sh/discovery`, `eks:cluster-name`, `aws:eks:cluster-name`, `eks:nodegroup-name`, `kubernetes.io/cluster/<cluster>`, `Name` and `aws:*` keys; no `karpenter.sh/nodepool`. Karpenter node: `karpenter.sh/nodepool`, `karpenter.sh/nodeclaim`, `karpenter.k8s.aws/ec2nodeclass`, `eks:eks-cluster-name`, `aws:eks:cluster-name`, `kubernetes.io/cluster/<cluster>`, `ManagedBy`, `Intent`, `Name`; no `karpenter.sh/discovery`. The NAT gateway and its Elastic IP both have `Name = vpc-<cluster>-us-east-1a`. The VPC flow log group `/aws/vpc-flow-log/<vpc id>` is destroyed with stage 1. The tags and names used by the filters of `check-leftovers.ps1` (PR #69) were therefore observed live.
- Leftover gate: baseline `-AfterDestroy` before the test printed OK. With the Karpenter node alive it exited 1 with LEFT for the load balancer and the Karpenter instance. After the drain it exited 1 with LEFT for an orphan VPC CNI ENI (status `available`, no attachment, owner instance already terminated), the same finding as live test 2; it was deleted by hand with the operator profile and the re-run before stage 1 printed OK. `-AfterDestroy` after stage 1 printed OK. Independent read-only checks afterwards (EKS clusters, instances, NAT gateways, Elastic IPs, VPC, load balancers, SQS queue, IAM roles, log groups) were all empty for this cluster, and the runner SSM session log group is gone too. Resources of another project were not touched.
- `teardown-stage2.sh`, real script: the stub test of the wait loop (no cluster effect) passed before the kubeconfig existed. Timeout path with `NODE_TIMEOUT=30`: ALB gone in 20 s, root application deleted in 36 s, FAIL after 30 s with exit 1. Success run: with the label `karpenter.sh/nodepool=loop-test` on a managed node, waiting lines from 15:36:33, label removed by a background timer about 36 s later, "no Karpenter nodeclaims and nodes left" 49 s after the first waiting line, exit 0. An earlier run waited for real for more than 9 minutes polling every 16 s and was interrupted by the operator with Ctrl-C (not counted as the success run). The real Karpenter node was again removed by the root-application cascade before the loop started.
- Argo CD: login page and UI answered 200 over HTTP through the ALB from the allowed IP; the initial admin secret exists with chart 10.9.6. The only application is `root-application` (8 resources: namespace, service, deployment, EC2NodeClass, NodePool and 3 NetworkPolicies, shown with their policyendpoints and, while it lasted, the NodeClaim and node). No HTTPS (documented limitation). The password was printed in an SSM session logged to CloudWatch; that log group was destroyed with stage 1 and is gone.
- Budget: a daily USD 5 alert-only test budget was created with the CLI call shape of the runbook (no error) and deleted afterwards; deletion needed the operator profile (the read-only role is denied `budgets:ModifyBudget`, expected). Another budget of the account was left untouched.

Finding: in a pod, `nslookup kubernetes.default` returned NXDOMAIN from the cluster DNS (the server answered), while `nslookup kubernetes.default.svc.cluster.local` resolved. Probable cause: busybox `nslookup` does not use the search domains (not verified). The README Post-Deploy Checklist now uses the full name.

Process: pass the operator profile per command with `--profile` instead of leaving it set in a terminal window.

NOT VERIFIED:

- The `network-policy-agent` CPU and memory requests.
- Whether the `vpc-cni` `configuration_values` change replaces the add-on on an already running cluster (this test used a fresh cluster).
- A Terraform run longer than 1 hour.
- The state of the labelled node while the `teardown-stage2.sh` wait loop waited (not captured).
- Rejection of the ALB from a non-allowed network: from a phone on mobile data the ALB did not answer (timeout), observed by the operator, not independently verified.
- Cost: Cost Explorer for 2026-10-12 will be added in a later PR.
- Positive detection of the `-AfterDestroy` branch of `check-leftovers.ps1` (runner, managed nodes, NAT gateway, Elastic IP, VPC): it was only run when everything was already gone (negative case, OK). The default-mode instance filter was exercised positively (Karpenter node).
