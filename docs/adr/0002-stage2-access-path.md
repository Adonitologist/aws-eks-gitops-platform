# ADR 0002: Stage 2 access path (operator-run, SSM-only EC2 runner)

- Status: Accepted
- Date: 2026-10-03

## Context

ADR 0001 keeps the EKS API endpoint private-only and defers the access path for `stacks/cluster`
(stage 2) to this ADR. The constraints it sets, quoted from `docs/adr/0001-private-eks-endpoint.md`:

- `:23` "Keep the API endpoint private-only. Do not enable the public endpoint."
- `:24-25` "Do not use self-hosted runners: the repository is public and runs workflows on
  `pull_request`, so untrusted code could execute on a runner inside the VPC."
- `:36-37` CI plans stage 1 only and never plans, applies or initializes stage 2 with a backend.
- `:45-47` Stage 2 is applied from a host with a network path to the private endpoint; the access
  path is not decided in ADR 0001.
- `:17-19` The VPN has a shared exit IP and GitHub-hosted runner IPs cannot be allow-listed, so a
  public endpoint restricted by CIDR is rejected.

Stage 2 authenticates through the `helm` and `kubernetes` providers with `aws eks get-token`
(`stacks/cluster/providers.tf`), reads stage-1 outputs through `terraform_remote_state`, and calls
`data "aws_eks_addon"` once. Its only AWS API needs are the state bucket and that add-on lookup.

## Options considered

Prices: AWS Pricing API, us-east-1, Linux on-demand, queried 2026-10-03 (t3.micro 0.0104 USD/h,
t3.small 0.0208 USD/h, gp3 0.08 USD/GB-month). Assumptions: 730 h/month always on, or 20 h/month
when stopped while idle; the existing single NAT gateway is reused (no new fixed cost).

| Option | Cost per month | Verdict |
|---|---|---|
| 1A. Private EC2 reached through SSM Session Manager, Terraform runs on the instance | t3.small + 30 GiB gp3: 15.18 + 2.40 = 17.58 USD always on; 0.42 + 2.40 = 2.82 USD stopped when idle | Chosen |
| 1B. Same instance, SSM port forward from the laptop, Terraform on the laptop | Same infrastructure, smaller instance possible | Fallback: needs `tls_server_name` overrides in the providers and a stable tunnel during Helm installs |
| 2. CodeBuild project in the VPC | Not priced (price not retrieved) | Rejected: more moving parts for three Helm releases; buildspec, roles, trigger and log-driven debugging |
| 3a. CloudShell VPC environment | No charge to connect | Rejected: no persistent storage, 20 to 30 minute inactivity timeout, running processes do not count as interaction |
| 3b. Client VPN or Site-to-Site VPN | Not priced | Rejected: weight and cost for one operator |
| 3c. Public endpoint with CIDR allow-list | n/a | Violates ADR 0001 decision 1 |
| 3d. Self-hosted or CodeBuild-hosted GitHub runner in the VPC | n/a | Violates ADR 0001 decision 2 |

## Decision

1. Stage 1 creates a stage 2 runner (`modules/stage2_runner`): one EC2 instance (t3.small, AL2023)
   in the first private subnet, no public IP, no inbound rules, reached only through SSM Session
   Manager. The operator starts it, runs Terraform for `stacks/cluster` inside tmux, and stops it.
2. The runner is operator-run. It is not registered in CI and CI never starts it.
3. The runner IAM role gets an EKS access entry (type STANDARD) with `AmazonEKSClusterAdminPolicy`
   at cluster scope. `AmazonEKSAdminPolicy` is not enough: it has no rules for `clusterroles`,
   `clusterrolebindings` or CRDs, which the Karpenter and AWS Load Balancer Controller charts need.
4. The cluster creator admin entry (`enable_cluster_creator_admin_permissions = true` in
   `modules/eks_cluster/main.tf`) stays as break-glass access for the identity that applies stage 1.
5. Network: the runner security group has no inbound rules and one egress rule (TCP 443). The
   cluster security group gets one ingress rule (TCP 443 from the runner security group); the EKS
   docs state that the cluster security group rules control access to the private endpoint. Egress
   to the internet goes through the existing NAT gateway; no VPC endpoints are added.
6. Tooling is pinned and installed by `user_data` with SHA256 verification: Terraform 1.15.6 and
   kubectl 1.35.9 (both variables of the module, with their checksums).
7. Session Manager sessions are logged to a CloudWatch Logs group (retention 90 days by default)
   through the account default preferences document `SSM-SessionManagerRunShell`.
8. CI planning of stage 2 stays out of scope.

### Why an operator-run host does not violate ADR 0001 decision 2

Decision 2 rejects runners that execute workflow code from `pull_request` events on a public
repository. The stage 2 runner has no GitHub runner agent, no registration, no inbound port and no
network path from GitHub. The only way to execute code on it is `ssm:StartSession`, which needs IAM
permission held by the operator. Pull requests cannot reach it, and the code it runs is what the
operator checks out. Residual rule: only check out reviewed commits of `main` on the runner, never
branches from forks or unreviewed pull requests.

## Design

| Component | Detail |
|---|---|
| Instance | AL2023 from the public SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`, `ignore_changes = [ami]`, IMDSv2 required with hop limit 1, encrypted gp3 root volume (30 GiB), 2 GiB swap file, `user_data_replace_on_change = true` |
| Packages | git, tmux, unzip, AWS CLI v2 (present in the AL2023 standard AMI; installed only if missing), Terraform and kubectl with SHA256 check |
| IAM role | Session Manager minimal permissions, session log write to its log group, S3 access scoped to `eks-gitops-platform/*` (list with prefix condition, read `terraform.tfstate`, read/write `cluster.tfstate`, read/write/delete `cluster.tfstate.tflock`), `eks:DescribeAddon` on the cluster add-on ARNs |
| `aws eks get-token` | Needs no IAM permission of its own (see the verified list) |
| Security groups | Runner: no inbound, egress TCP 443. Cluster security group: ingress TCP 443 from the runner security group |
| EKS access | Access entry plus `AmazonEKSClusterAdminPolicy`, scope cluster |
| Logging | CloudWatch log group `/ssm/session-manager/<cluster_name>`, streaming enabled |

The preferences document `SSM-SessionManagerRunShell` is the default document of the whole account
and Region: its logging and idle timeout (30 minutes by default) apply to every Session Manager
session in the account, not only to this runner. It did not exist when this ADR was written, so
Terraform can create it; if another one is created later, `terraform apply` of stage 1 fails on a
name conflict and the document must be imported or merged.

## Operating procedure

Runs from the workstation that applies stage 1 (AWS CLI, Session Manager plugin, permissions for
`ec2:StartInstances`, `ec2:StopInstances` and `ssm:StartSession`).

1. Start the runner and wait until it is reachable:
   ```bash
   aws ec2 start-instances --instance-ids <instance_id>
   aws ec2 wait instance-status-ok --instance-ids <instance_id>
   ```
   `instance_id` and the session command are outputs of stage 1 (`stage2_runner_ssm_command`).
2. Open a shell and attach to tmux, so a dropped session does not kill a running apply:
   ```bash
   aws ssm start-session --target <instance_id>
   tmux new -A -s stage2
   ```
   After the first boot check `ls /var/lib/stage2-runner-ready` (bootstrap log:
   `/var/log/stage2-runner-bootstrap.log`).
3. First time only, clone the repository; every time, move to the reviewed commit of `main`:
   ```bash
   git clone https://github.com/Adonitologist/aws-eks-gitops-platform.git
   cd aws-eks-gitops-platform && git switch main && git pull --ff-only && git log -1 --oneline
   ```
4. Plan with the repository output rule, then apply by hand:
   ```bash
   terraform -chdir=stacks/cluster init
   terraform -chdir=stacks/cluster plan -no-color -compact-warnings 2>&1 | tail -n 40
   terraform -chdir=stacks/cluster apply
   ```
   On the runner the role can write and delete the `.tflock` object, so plans use the default
   lock. `-lock=false` stays reserved for the read-only workstation profile (plans only, never
   apply). Read the plan for replacements or destroys before applying.
5. If the session drops, reattach with `tmux new -A -s stage2`. Run `terraform force-unlock` only
   after confirming that no Terraform process is running (`pgrep -a terraform`).
6. Verify the cluster from the runner (`aws eks update-kubeconfig --region us-east-1 --name
   eks-gitops-production`, then `kubectl get nodes`), leave the shell, and stop the instance:
   ```bash
   aws ec2 stop-instances --instance-ids <instance_id>
   ```

Replace the runner from time to time (AL2023 AMIs are deprecated 90 days after release and the
instance ignores AMI changes): `terraform apply -replace=module.stage2_runner.aws_instance.runner`
in `stacks/infra`.

## Teardown order

Stage 2 is destroyed first and from the runner, because destroying Helm releases and deleting
Karpenter resources need the private endpoint. Stage 1 is destroyed last from the workstation: it
removes the runner, its access entry and its security group rule together with the cluster.

1. Start the runner and open a tmux session (steps 1 and 2 above).
2. Steps 1 to 5 of the README "Safe Teardown Protocol" (root application, ALBs, Karpenter
   NodePools and EC2NodeClasses, finalizers, `terraform destroy` of `stacks/cluster`) run on the
   runner.
3. Leave the shell. From the workstation run `terraform destroy` in `stacks/infra`.

## Consequences

- Stage 1 creates 11 new resources (verified in a plan: 117 to add, 0 to change, 0 to destroy for
  the whole stack) and exposes `cluster_security_group_id` from `modules/eks_cluster`.
- A standing instance role holds Kubernetes cluster-admin on this cluster plus state-bucket access.
  Mitigations: no inbound ports, IMDSv2 with hop limit 1, access only through SSM, the instance is
  stopped when idle, sessions are logged. The role has no AWS administrative permissions: stage 2
  creates no AWS resources.
- The runner reaches the internet (SSM, GitHub, HashiCorp, registries) only through the single NAT
  gateway of `modules/vpc/main.tf`; if its Availability Zone fails, the runner has no egress.
- CI planning of stage 2 is still not possible; it would need the same network path.

## Verified

- AL2023 SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`
  resolves in us-east-1 (version 191, `ami-0d27e0fb3bac4d724` on 2026-10-03); parameter names are
  listed in https://docs.aws.amazon.com/linux/al2023/ug/ec2.html.
- Private subnet NACLs allow the return traffic: inbound rule 110 TCP 1024-65535 from 0.0.0.0/0 and
  rule 100 for the VPC CIDR, outbound rule 110 TCP 443 (`modules/vpc/main.tf:6-14`); public subnet
  rules 100 to 130 and outbound 100 to 120 cover the NAT hop (`modules/vpc/main.tf:16-27`). NACLs do
  not filter DNS, DHCP, instance metadata or Time Sync traffic
  (https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html).
- SSM Agent needs outbound 443 to `ssm`, `ssmmessages` and `ec2messages`, and no inbound traffic
  (https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-create-vpc.html).
- Minimal Session Manager role and session log permissions
  (https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-create-iam-instance-profile.html).
  `AmazonSSMManagedInstanceCore` (version v2) grants 15 `ssm:` actions, the 4 `ssmmessages:` actions
  and 6 `ec2messages:` actions on `*`, read with `aws iam get-policy-version`.
- Terraform S3 backend permissions for `use_lockfile`: Get/Put/Delete on the `.tflock` key, Get/Put
  on the state key, ListBucket (https://developer.hashicorp.com/terraform/language/backend/s3). The
  state bucket uses SSE-S3 (AES256), has versioning enabled and no bucket policy, so no KMS
  permissions are needed.
- `aws eks get-token --cluster-name <nonexistent cluster>` succeeded (exit 0) under the read-only
  role, so it generates the token locally and needs no EKS permission. `sts:GetCallerIdentity`
  needs no permission (https://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html).
- `eks:DescribeAddon` backs the DescribeAddon API
  (https://docs.aws.amazon.com/eks/latest/APIReference/API_DescribeAddon.html); IAM Access Analyzer
  `validate-policy` returned no findings for the rendered runner policy.
- `aws_eks_access_entry`, `aws_eks_access_policy_association` and
  `aws_vpc_security_group_ingress_rule` exist in aws provider 5.100.0 (provider schema of
  `stacks/infra`).
- Access policy rules: `AmazonEKSClusterAdminPolicy` is `*` on `*`; `AmazonEKSAdminPolicy` has no
  cluster-scoped RBAC or CRD rules
  (https://docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html).
- The cluster security group controls access to the private endpoint and the EKS-attached security
  groups apply to the control plane network interfaces
  (https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html,
  https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html).
- Session preferences document format and `SSM-SessionManagerRunShell`
  (https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-create-preferences-cli.html).
  The document did not exist in the account on 2026-10-03.
- `terraform validate`, `terraform fmt`, `tflint` (12 warnings, same count as before) and `tfsec`
  (no problems) pass; the stage 1 plan shows only creates.

## Not verified

- `user_data` has not run on a real instance: package names (`git`, `tmux`, `unzip`, `awscli-2`),
  AL2023 repository access through the NAT on TCP 443, the `dl.k8s.io` redirect on 443, and the
  swap file creation are untested.
- Whether the minimal Session Manager policy is enough for the SSM agent to register. Fallback:
  attach the AWS managed policy `AmazonSSMManagedInstanceCore` (contents verified above).
- Whether `eks:DescribeAddon` accepts the add-on resource ARN pattern at runtime (Access Analyzer
  found no issue; the Service Authorization Reference page could not be read). Fallback: `*`.
- Terraform and kubectl checksums were copied over TLS from `releases.hashicorp.com` (SHA256SUMS)
  and `dl.k8s.io` on 2026-10-03; the HashiCorp GPG signature of SHA256SUMS was not checked.
- The AWS CLI v2 is part of the AL2023 standard AMI (documentation claim, not checked on an
  instance), the `ssm-user` PATH includes `/usr/local/bin`, and the t3.small is enough for the aws,
  helm and kubernetes providers (the 2 GiB swap file is the safety margin).
- CloudWatch Logs cost of the session log group, NAT data processing cost, and the price of the
  options that were not selected.
- The operator workstation permissions (`ssm:StartSession`, `ec2:StartInstances`,
  `ec2:StopInstances`) and the Session Manager plugin on the workstation.
- Behavior of the Helm releases (default provider timeout 300 s, no `atomic`) during a first apply
  on a fresh cluster; unrelated to the access path but relevant to the first run.
