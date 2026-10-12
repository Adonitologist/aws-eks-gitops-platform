# AWS EKS GitOps Platform: private cluster, two-stage Terraform, Argo CD and Karpenter

[![Terraform CI](https://github.com/Adonitologist/aws-eks-gitops-platform/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Adonitologist/aws-eks-gitops-platform/actions/workflows/ci.yml)
![Terraform](https://img.shields.io/badge/IaC-Terraform_v1.15.6-844FBA?logo=terraform)
![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.35-326CE5?logo=kubernetes)
![ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo)
![AWS](https://img.shields.io/badge/Cloud-AWS_EKS-232F3E?logo=amazon-aws)

A single-environment Amazon EKS platform built and operated by one person as a portfolio project. Terraform is split into two stacks: stage 1 creates the VPC, a private-endpoint EKS cluster and an SSM-only runner; stage 2 runs on that runner and installs the AWS Load Balancer Controller, Karpenter and Argo CD, which then syncs the manifests in this repository. The design decisions, trade-offs and live-test results are recorded in the [ADRs](docs/adr/). The platform was applied and destroyed in live tests (see the ADR 0001 addenda); it is a reference implementation, not a multi-team production platform.

Sections: [What this demonstrates](#what-this-demonstrates), [Quick start](#quick-start), [Limitations](#limitations), [Cost](#cost), [Safe Teardown Protocol](#safe-teardown-protocol-cost-prevention), [How this repository is worked on](#how-this-repository-is-worked-on), [Author](#author).

## What this demonstrates

| Skill | Where |
|-------|-------|
| Private EKS endpoint and a way to operate it without a bastion or VPN | [ADR 0001](docs/adr/0001-private-eks-endpoint.md), [ADR 0002](docs/adr/0002-stage2-access-path.md), [`modules/stage2_runner`](modules/stage2_runner) |
| Splitting Terraform state and providers across two stacks | [`stacks/infra`](stacks/infra), [`stacks/cluster`](stacks/cluster), [ADR 0001](docs/adr/0001-private-eks-endpoint.md) |
| Network design with dedicated NACLs and flow logs | [`modules/vpc/main.tf`](modules/vpc/main.tf) |
| Workload identity with IRSA and EKS Pod Identity | [`modules/eks_addons/main.tf`](modules/eks_addons/main.tf) |
| Karpenter autoscaling under a restricted account policy | [`kubernetes/workloads/karpenter-nodepool.yaml`](kubernetes/workloads/karpenter-nodepool.yaml), [ADR 0001](docs/adr/0001-private-eks-endpoint.md) |
| GitOps with Argo CD (App of Apps) | [`kubernetes/argocd-apps/root-app.yaml`](kubernetes/argocd-apps/root-app.yaml), [`modules/gitops_argocd`](modules/gitops_argocd) |
| Pod Security admission (restricted) and default-deny network policy | [`kubernetes/workloads/sample-app`](kubernetes/workloads/sample-app) |
| CI with OIDC, tflint, Trivy and a manifest name check | [`.github/workflows/ci.yml`](.github/workflows/ci.yml), [`scripts/ci`](scripts/ci) |
| Operator credential hardening and its limits | [ADR 0003](docs/adr/0003-operator-credentials.md) |
| Teardown procedure and leftover detection, exercised in live tests | [Safe Teardown Protocol](#safe-teardown-protocol-cost-prevention), [`scripts/teardown`](scripts/teardown) |
| Cost tracking of live runs | [Cost](#cost) |

## Quick start

Needs an AWS account, an S3 state bucket and the operator profiles described in [Operator credentials](#operator-credentials).

1. Read [Operator credentials](#operator-credentials) and the prerequisites in [Deployment Instructions](#deployment-instructions).
2. Apply stage 1 (`stacks/infra`) from the workstation.
3. Start the stage 2 runner, open an SSM session and apply stage 2 (`stacks/cluster`) there.
4. Create the root application, then run the [Post-Deploy Checklist](#post-deploy-checklist).
5. Destroy everything the same day with the [Safe Teardown Protocol](#safe-teardown-protocol-cost-prevention).

## Limitations

- Single environment (`production`); the Karpenter manifest check validates only that environment ([ADR 0001](docs/adr/0001-private-eks-endpoint.md), "Karpenter names and Kustomize").
- Argo CD is served over HTTP: the ALB has no TLS listener (`modules/gitops_argocd/main.tf:34`).
- One NAT gateway, so no NAT high availability (`modules/vpc/main.tf:54`).
- One operator. The operator role has `AdministratorAccess`, an accepted trade-off ([ADR 0003](docs/adr/0003-operator-credentials.md)).
- Anyone who can start a session on the stage 2 runner has cluster-admin in practice ([ADR 0002](docs/adr/0002-stage2-access-path.md)).
- Because of the Free Tier plan policy, the NodePool is limited to on-demand, two instance types and cpu 8 / memory 32Gi (`kubernetes/workloads/karpenter-nodepool.yaml`); the Spot denial itself was not tested live.
- CI plans stage 1 only; stage 2 is never planned or applied in CI and there is no apply job (`.github/workflows/ci.yml`).
- The root application is applied by hand ([Creating root-application](#creating-root-application)); Argo CD self-heal is configured but not demonstrated live.
- No monitoring or backup module exists in `modules/`; metrics-server is not installed ([ADR 0001](docs/adr/0001-private-eks-endpoint.md), addendum 2026-10-11).
- A Terraform run longer than the 1 hour operator session was not exercised ([ADR 0001](docs/adr/0001-private-eks-endpoint.md), live test 3 addendum).
- The state bucket name contains the AWS account id by design; it was kept on purpose (see ADR 0001, "Addendum 2026-10-12: account id in the state bucket name").

## System Architecture & GitOps Flow

1. **Infrastructure as Code (Terraform):** Provisions a dedicated VPC with subnets in at least two availability zones (`azs` is validated to have two or more) and a single NAT gateway, private subnets with auto-discovery tags, and a managed EKS control plane.
2. **Workload identity and network limits:** IRSA (OIDC) maps an IAM role to the AWS Load Balancer Controller and EKS Pod Identity serves Karpenter (`modules/eks_addons/main.tf`); the Argo CD ALB accepts only the CIDRs in `argocd_allowed_cidrs`; a default-deny network policy exists only in the `sample-app` namespace. Least privilege does not apply everywhere: the operator role is `AdministratorAccess` (accepted trade-off, [ADR 0003](docs/adr/0003-operator-credentials.md)) and the stage 2 runner is cluster-admin ([ADR 0002](docs/adr/0002-stage2-access-path.md)).
3. **Dynamic Compute (Karpenter):** Karpenter observes unschedulable pods and provisions EC2 instances directly through the EC2 API; the system components run on one managed node group. The NodePool is limited to on-demand `m7i-flex.large` and `c7i-flex.large` because the published Free Tier plan policy denies Spot (`kubernetes/workloads/karpenter-nodepool.yaml`; a Spot launch was not tried live). A node became Ready in about 33 to 37 s in live tests 2 and 3 ([ADR 0001](docs/adr/0001-private-eks-endpoint.md) addenda).
4. **Continuous Deployment (ArgoCD):** Installed via Helm during the infrastructure bootstrap, ArgoCD syncs `kubernetes/workloads` from this Git repository once the root application is created (see "Creating root-application" below), continuously reconciling the cluster state against the defined manifests.

## Core Technical Highlights

* **App of Apps Pattern:** The `root-app.yaml` dictates the entire cluster configuration. The application has `selfHeal: true` and `prune: true` (`kubernetes/argocd-apps/root-app.yaml`), so manual `kubectl` changes to synced resources should be reverted; reverting a manual change was not demonstrated live (NOT VERIFIED).
* **Remote State Management:** Terraform state is stored remotely in Amazon S3 with native S3 state locking (`use_lockfile`, no DynamoDB), in two separate states (see [ADR 0001](docs/adr/0001-private-eks-endpoint.md)).
* **Automated Quality Gates:** The GitHub Actions pipeline runs `terraform validate` for both stacks, `tflint`, Trivy (`trivy config`), shellcheck and the Karpenter name check on every pull request, and plans stage 1 only; stage 2 is not planned in CI (`.github/workflows/ci.yml`).
* **HTTP only, TLS not configured:** Argo CD runs as a ClusterIP service without internal TLS (`--insecure`) behind an ALB ingress, and the ALB has only an HTTP listener. This is a documented limitation; the ingress is meant to let the AWS Load Balancer Controller terminate TLS once a certificate and domain exist. Without a custom domain (`argocd_hostname` empty) the ingress has no host match: read the ALB DNS name with `kubectl get ingress -n argocd` and open it over HTTP (no TLS listener yet; the ALB only accepts the CIDRs in `argocd_allowed_cidrs`); `argocd-cm` `url` stays `https://`.

## Architecture Diagram

Every box maps to a file in this repository. Solid arrows are runtime access or deployment paths; dotted arrows are reads of Git content or Terraform state.

```mermaid
flowchart LR
    OP["Operator workstation"]
    GH["GitHub repository<br/>(branch main)"]

    subgraph CI["GitHub Actions (.github/workflows/ci.yml)"]
        direction TB
        CHK["tflint, Trivy config,<br/>shellcheck, validate,<br/>check-karpenter-names"]
        OIDC["OIDC role<br/>(vars.AWS_CI_ROLE_ARN)"]
        PLAN["plan, stage 1 only"]
        CHK --> OIDC --> PLAN
    end

    subgraph AWS["AWS account"]
        SSM["SSM Session Manager"]
        S3[("S3 state bucket<br/>terraform.tfstate (stage 1)<br/>cluster.tfstate (stage 2)")]

        subgraph VPC["VPC (modules/vpc, flow logs, dedicated NACLs)"]
            subgraph PUB["Public subnets"]
                ALB["ALB<br/>(Argo CD ingress)"]
                NAT["NAT gateway<br/>(single)"]
            end
            subgraph PRIV["Private subnets"]
                RUN["Stage 2 runner EC2<br/>(modules/stage2_runner)"]
                API["EKS private API endpoint<br/>(modules/eks_cluster)"]
                SYS["System node group<br/>system_components"]
                KARP["Karpenter nodes<br/>(NodePool default)"]
                ARGO["Argo CD<br/>root-application"]
            end
        end
    end

    subgraph TF["Terraform stacks"]
        direction TB
        S1["Stage 1: stacks/infra<br/>vpc, eks_cluster, eks_addons,<br/>stage2_runner"]
        S2["Stage 2: stacks/cluster<br/>eks_addons_helm, gitops_argocd"]
    end

    WL["kubernetes/workloads<br/>NodePool, EC2NodeClass"]

    OP --> SSM --> RUN
    RUN --> API
    API --- SYS
    SYS -->|"Karpenter controller"| KARP
    S1 -.->|"state"| S3
    S2 -.->|"state"| S3
    OP -->|"stage 1 run from workstation"| S1
    RUN -->|"stage 2 run on runner"| S2
    S2 -->|"Helm: LB controller,<br/>Karpenter, Argo CD"| API
    GH --- WL
    ARGO -.->|"auto-sync, prune, selfHeal"| WL
    WL -->|"defines"| KARP
    ALB --> ARGO
    PRIV -->|"TCP 443 egress"| NAT
    GH --> CI
    PLAN -.->|"read state"| S3
```

Notes:

* Stage 1 (`stacks/infra`) is run from the workstation; stage 2 (`stacks/cluster`) is run on the runner because the API endpoint is private ([ADR 0001](docs/adr/0001-private-eks-endpoint.md), [ADR 0002](docs/adr/0002-stage2-access-path.md)).
* CI plans stage 1 only; it never plans or applies stage 2 and has no apply job.
* `kubernetes/argocd-apps/root-app.yaml` is applied by hand once; Argo CD then syncs `kubernetes/workloads` from `main`.

### Cost

Reference table for the live test. The figures are Cost Explorer estimates, not an invoice.

| Run | Duration and scope | Actual cost |
|-----|--------------------|-------------|
| Live test 2026-10-11 | about 1h10m, EKS + NAT + 2 system nodes + runner + up to 2 Karpenter nodes | see day total |
| Live test 2, 2026-10-11 | about 1h50m, apply 19:41 local to destroy end 21:29 local, including fixes; 117 + 4 resources; EKS + NAT + 2 system nodes + runner + 1 live Karpenter node | see day total |

Day total, not per run: Cost Explorer shows about USD 1.02 gross in Usage rows for 2026-10-11 UTC for the whole account, marked Estimated. It cannot be attributed to either live test without cost allocation tags, and Estimated data may still change. Of it, about USD 0.05 are Cost Explorer API calls. Covered 100% by AWS credits, net 0. Gross by service: EC2-Other 0.41, EC2-Compute 0.26, EKS 0.13, VPC 0.13, ELB 0.05. Data Transfer showed only a credit row (-0.038) with no Usage row, unexplained.

Main hourly cost drivers, approximate AWS list prices (us-east-1, on-demand), NOT VERIFIED; check the AWS pricing pages and Billing before relying on them:

| Driver | Approx. hourly price (NOT VERIFIED) |
|--------|-------------------------------------|
| EKS control plane | about USD 0.10 |
| NAT gateway (single) | about USD 0.045, plus per-GB data processing |
| System nodes, m7i-flex.large x 2 | about USD 0.10 each |
| Karpenter nodes, m7i-flex.large or c7i-flex.large (up to 2) | about USD 0.09 to 0.10 each |
| Stage 2 runner, t3.small (only while running) | about USD 0.02 |
| ALB (Argo CD ingress) | about USD 0.02, plus LCU usage |
| Public IPv4 addresses (NAT, ALB) | about USD 0.005 each |

Not itemized: CloudWatch (flow logs, session logs), S3 state storage and data transfer. Use the [Safe Teardown Protocol](#safe-teardown-protocol-cost-prevention) to stop the charges.

## Repository Structure

```text
.
|-- .claude/                       # Claude Code settings, slash commands and the PreToolUse hook (see "How this repository is worked on")
|-- .github/
|   |-- workflows/ci.yml           # Validate, lint and scan both stacks; plan stage 1
|   `-- dependabot.yml             # GitHub Actions and Terraform provider/module updates
|-- docs/adr/                      # Architecture decision records 0001 to 0003
|-- kubernetes/
|   |-- argocd-apps/               # root-app.yaml, the App of Apps root (applied by hand)
|   |-- tests/                     # netpol-test.yaml: throwaway clients for the network policy demo (not synced)
|   `-- workloads/                 # Synced by Argo CD
|       |-- karpenter-nodepool.yaml  # Karpenter NodePool and EC2NodeClass
|       `-- sample-app/            # Placeholder workload (stock nginx page, no Ingress) used to test Pod Security admission and network policy
|-- modules/
|   |-- vpc/                       # Network topology, NACLs, flow logs and discovery tags
|   |-- eks_cluster/               # Control plane, OIDC, and System Node Group
|   |-- eks_addons/                # IAM roles, SQS, Pod Identity, managed add-ons (stage 1)
|   |-- stage2_runner/             # SSM-only EC2 that runs stage 2 against the private endpoint (stage 1)
|   |-- eks_addons_helm/           # AWS Load Balancer Controller and Karpenter via Helm (stage 2)
|   `-- gitops_argocd/             # Argo CD via Helm (stage 2)
|-- scripts/
|   |-- ci/                        # check-karpenter-names.sh, run by CI
|   |-- teardown/                  # teardown-stage2.sh (runner) and check-leftovers.ps1 (workstation)
|   `-- review.ps1, ship.ps1, land.ps1   # Operator pull request flow, see scripts/README.md
|-- stacks/
|   |-- infra/                     # Stage 1: vpc, eks_cluster, eks_addons, stage2_runner (state: terraform.tfstate)
|   `-- cluster/                   # Stage 2: Helm releases and Argo CD (state: cluster.tfstate)
|-- CLAUDE.md                      # Working rules for Claude Code in this repository
|-- LICENSE                        # MIT
`-- SECURITY.md                    # How to report a problem
```

Design decisions: [ADR 0001: private EKS endpoint and two-stage split](docs/adr/0001-private-eks-endpoint.md), [ADR 0002: stage 2 access path](docs/adr/0002-stage2-access-path.md), [ADR 0003: operator credentials](docs/adr/0003-operator-credentials.md).

## Operator credentials
The workstation IAM user has no direct permissions: it can only assume the Terraform operator role (administrator, MFA required, 1 hour session) and the read-only role used by Claude Code. Stage 1 plan, apply and destroy and `scripts/teardown/check-leftovers.ps1` run with the `tf-admin-tf` profile; stage 2 runs on the runner with its instance role.

```powershell
aws sts get-caller-identity --profile tf-admin   # asks for the MFA code, caches a 1 hour session
$env:AWS_PROFILE = 'tf-admin-tf'                  # then run Terraform as usual
```

The session lasts one hour; a Terraform run longer than that is expected to fail (NOT VERIFIED), so repeat the first command and re-run. The profile `readonly` is for read-only plans (`-lock=false`) and Claude Code. Design and verification status: [ADR 0003](docs/adr/0003-operator-credentials.md).

## Deployment Instructions
**Prerequisites**

* AWS CLI with the `tf-admin` and `tf-admin-tf` profiles configured (see Operator credentials).
* Terraform v1.10+ (native S3 locking; CI uses 1.15.6).
* An isolated S3 bucket for remote state, bootstrapped out-of-band to prevent accidental destruction. Its name in `stacks/infra/backend.tf` and `stacks/cluster/backend.tf` must point to it.

**Apply order: infra, then cluster**

The stacks have separate states and must be applied in this order. Stage 2 reads stage-1 outputs and requires the Pod Identity agent addon created by stage 1 (a cross-stack `depends_on` is not possible, so `stacks/cluster` fails its plan if the addon is missing). Stage 2 must run on the stage 2 runner, an SSM-only EC2 instance that stage 1 creates inside the VPC (start it, open a Session Manager shell, run Terraform in tmux, stop it; procedure in [ADR 0002](docs/adr/0002-stage2-access-path.md)). See [ADR 0001](docs/adr/0001-private-eks-endpoint.md) for the known issues to fix before the first apply.

1. Stage 1, AWS resources (VPC, EKS, IAM, SQS, Pod Identity):
   ```bash
   cd stacks/infra
   terraform init
   terraform plan -var="environment=production"
   terraform apply -var="environment=production"
   ```
2. Stage 2, Helm releases and Argo CD, run on the stage 2 runner after cloning this repository there (see ADR 0002):
   ```bash
   cd stacks/cluster
   terraform init
   terraform plan -var='argocd_allowed_cidrs=["203.0.113.10/32"]'
   terraform apply -var='argocd_allowed_cidrs=["203.0.113.10/32"]'
   ```
   `argocd_allowed_cidrs` has no default and restricts the Argo CD ALB (`alb.ingress.kubernetes.io/inbound-cidrs`) to those IPv4 CIDRs; `0.0.0.0/0` is rejected. Replace the documentation-range example with the egress IP of the network you browse from. Never commit the real value: pass it with `-var` (or `TF_VAR_argocd_allowed_cidrs`) typed in the runner session; `*.tfvars` and `*.auto.tfvars` are git-ignored. The runner shell history and the CloudWatch session log will contain it. A wrong or outdated CIDR locks you out of the ALB (not out of `kubectl port-forward`) until stage 2 is applied again with the right value.
3. Create the root application (see Creating root-application below), then verify GitOps synchronization. Argo CD syncs `kubernetes/workloads`:
   ```bash
   aws eks update-kubeconfig --region us-east-1 --name eks-gitops-production
   kubectl get nodepools
   ```

### Creating root-application

Proposed procedure, NOT VERIFIED against the live run. No Terraform resource creates `root-application`, so it is applied by hand after the stage 2 apply, with `kubectl` against the private endpoint (stage 2 runs on the runner; step 2 of Deployment Instructions says to clone this repository there):

```bash
kubectl apply -f kubernetes/argocd-apps/root-app.yaml
kubectl get application root-application -n argocd
```

The manifest syncs `kubernetes/workloads` (the Karpenter EC2NodeClass and NodePool) from the GitHub repository with `targetRevision: main` (`kubernetes/argocd-apps/root-app.yaml:13`), with automated sync, prune and self-heal.

### Post-Deploy Checklist

The API endpoint is private-only, so run these on the stage 2 runner (see ADR 0002).

1. Nodes are Ready: `kubectl get nodes` shows all system nodes in `Ready`.
2. Image pulls work (private subnets reach the internet only on TCP 443 through the NAT): `kubectl get pods -A` shows no `ImagePullBackOff` or `ErrImagePull`.
3. CoreDNS is resolving: `kubectl -n kube-system get pods -l k8s-app=kube-dns` are `Running`, and `kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default.svc.cluster.local` returns an answer; kubectl may print a harmless "couldn't attach to pod ... falling back to streaming logs" warning and still prints the answer (observed in live test 3). Use the full name: in live test 3 (2026-10-12) the short name `kubernetes.default` returned NXDOMAIN from the cluster DNS while the full name resolved (probable cause: busybox `nslookup` does not apply the search domains, NOT VERIFIED).
4. Flow logs are flowing: the CloudWatch log group for `vpc-eks-gitops-<environment>` receives events.
5. Network policy enforcement (verified in live test 3, 2026-10-12): the vpc-cni add-on has `enableNetworkPolicy = true` (`vpc_cni_enable_network_policy`, default true) and `kubernetes/workloads/sample-app/networkpolicy.yaml` denies all traffic in `sample-app` except DNS and same-namespace pods. First check that probes still pass: `kubectl -n argocd get pods` and `kubectl -n sample-app get pods` must show every pod `Running`, ready and with 0 restarts (observed: all 7 Argo CD pods and the sample app stayed 1/1 with 0 restarts after more than 4 minutes under the policies; the `aws-node` pods are 2/2). Contingency only, not needed in live test 3: if Argo CD pods stay not ready, set `global.networkPolicy.create = false` in `modules/gitops_argocd/main.tf` (or `vpc_cni_enable_network_policy = false`); see ADR 0001, "Addendum 2026-10-12: network policy".
6. Network policy demonstration (apply from the repo on the runner; `kubernetes/tests/` is not synced by Argo CD):
   ```bash
   kubectl apply -f kubernetes/tests/netpol-test.yaml
   kubectl -n sample-app rollout status deploy/np-allow
   kubectl -n np-test rollout status deploy/np-deny
   kubectl -n sample-app get networkpolicy                # 3 policies: default-deny-all, allow-dns-egress, allow-same-namespace
   kubectl get policyendpoints -A                         # objects created by EKS for the policies (observed: 6 for Argo CD, 3 for the sample app)
   kubectl -n kube-system get networkpolicy               # expected: none (verified in live test 3: the managed CoreDNS add-on adds none)
   kubectl -n sample-app exec deploy/np-allow -- wget -qO- -T 3 http://sample-app.sample-app.svc.cluster.local   # expected: nginx page
   kubectl -n np-test exec deploy/np-deny -- wget -qO- -T 3 http://sample-app.sample-app.svc.cluster.local       # expected: timeout
   kubectl -n sample-app exec deploy/np-allow -- wget -qO- -T 3 http://example.com                               # expected: timeout (egress denied)
   kubectl -n sample-app exec deploy/np-allow -- nslookup sample-app.sample-app.svc.cluster.local                # expected: resolves (DNS allowed)
   ```
   Cleanup: `kubectl delete -f kubernetes/tests/netpol-test.yaml`.

## Safe Teardown Protocol (Cost Prevention)

Destroying a GitOps cluster strictly requires draining dynamic resources prior to invoking Terraform. Failure to do so will result in orphaned EC2 instances and deadlocked VPC dependencies.

Teardown is the reverse of the apply order: cluster stack (stage 2) first, then infra. Steps 1 to 5 need the private endpoint, so start the stage 2 runner and run them there (see ADR 0002). Steps 6 and 7 run from your workstation: step 7 also destroys the runner.

Steps 1 to 3 are automated by `scripts/teardown/teardown-stage2.sh` (run it on the runner; `--dry-run` previews it; set `ARGOCD_ALLOWED_CIDRS` so it prints the step 5 command with your CIDR). It stops with a clear error on any timeout or failed query, and never runs `terraform destroy`. The ALB check needs `tag:GetResources` on the runner role (stage 1 must be applied with that policy). The manual commands below are the fallback. The script was run live on 2026-10-11: in one run the ingress was deleted and no ALB was left after about 31 s; in the run with a live Karpenter node the ALB was gone in about 24 s and deleting the root application took about 35 s, and its cascade removed the NodePool, EC2NodeClass and the node. The script's final Karpenter wait loop passed immediately, so it was not exercised.

1. **Delete the Argo CD ingress and the root application:**
   The Argo CD ALB ingress is created by the Helm release (stage 2), not by Argo CD, so deleting the root application does not remove it. Confirm the ingress name, then delete it so the AWS Load Balancer Controller dismantles its ALB. Then delete the root application, which removes the NodePool and EC2NodeClass it syncs from `kubernetes/workloads`.
   ```bash
   kubectl get ingress -n argocd
   kubectl delete ingress argocd-server -n argocd
   kubectl delete application root-application -n argocd
   ```

2. **Wait for the ALBs to disappear:**
   Do not continue while load balancers created by the controller still exist, or the VPC cannot be deleted.
   ```bash
   aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
   ```
   The Argo CD ALB can take time to disappear; do not continue until the command returns an empty list.

3. **Drain Karpenter Capacity:**
   Force Karpenter to cordon and terminate all dynamically provisioned EC2 compute nodes to prevent ghost charges.
   ```bash
   kubectl delete nodepool --all
   kubectl delete ec2nodeclass --all
   ```

4. **Purge Orphaned Finalizers (If Namespace Deadlocked):**
   If the argocd namespace hangs in Terminating state, force the release of lingering finalizers:
   ```bash
   kubectl patch application root-application -n argocd --type=merge -p '{"metadata":{"finalizers":[]}}'
   ```

> Note: do not uninstall Argo CD before the ALB ingress, the NodePools, the EC2NodeClasses and the Argo CD Application are deleted. The Application finalizer blocks the namespace otherwise.

5. **Destroy the cluster stack (stage 2):**
   ```bash
   cd stacks/cluster
   terraform destroy -var='argocd_allowed_cidrs=["203.0.113.10/32"]'
   ```

6. **Check for leftovers (gate before stage 1):**
   Run from the workstation with the `readonly` profile, or `tf-admin-tf` after `tf-admin` has cached a session (see Operator credentials). It is read-only (aws describe/list calls) and lists only ids.
   ```powershell
   .\scripts\teardown\check-leftovers.ps1
   ```
   Do not run step 7 on exit 1. A Karpenter node that was removed can leave an orphan ENI (status `available`, no attachment) that blocks deletion of the security groups and the VPC. After confirming the instance is terminated, delete the listed ENI by hand and re-run the check. The check also reports Karpenter instances still present in the cluster VPC (tag key `karpenter.sh/nodepool`; managed nodes and the runner are expected and not reported), and prints a NOTE line if the VPC is not found. After step 7, `-AfterDestroy` confirms nothing is left: instances (runner, managed or Karpenter nodes), NAT gateways, Elastic IPs and the VPC are checked too; a remaining `eks-cluster-sg-*` security group is deleted by hand once no ENI uses it. The tag filters come from the Terraform modules and the Karpenter docs and were verified in live test 3 (2026-10-12): the Karpenter node, the managed nodes, the NAT gateway and its Elastic IP carried the expected tags and names, and the check, in default mode, reported the load balancer, the Karpenter instance and an orphan ENI as LEFT, then printed OK.

7. **Destroy the infra stack (stage 1):**
   ```bash
   cd stacks/infra
   terraform destroy
   ```

> PowerShell note: quote the flag, for example `"-out=destroy.tfplan"`. A stale plan must be re-planned and applied immediately.

## How this repository is worked on

`CLAUDE.md` and `.claude/` are tracked on purpose. They hold the rules for AI-assisted work in this repository and a PreToolUse hook (`.claude/hooks/block-writes.ps1`) that blocks mutating commands and any AWS profile other than `readonly` for Claude Code. The operator runs every apply, destroy and push. The hook is a guardrail, not a sandbox: its limits are in the "Addendum 2026-10-12: enforcement" section of [ADR 0003](docs/adr/0003-operator-credentials.md).

## Author

Juan E. ([Adonitologist](https://github.com/Adonitologist)).

## License

MIT, see LICENSE.
