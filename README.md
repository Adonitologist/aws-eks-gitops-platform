# Enterprise AWS EKS GitOps Platform

![Terraform CI](https://github.com/Adonitologist/aws-eks-gitops-platform/actions/workflows/ci.yml/badge.svg)
![Terraform](https://img.shields.io/badge/IaC-Terraform_v1.15.6-844FBA?logo=terraform)
![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.35-326CE5?logo=kubernetes)
![ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo)
![AWS](https://img.shields.io/badge/Cloud-AWS_EKS-232F3E?logo=amazon-aws)

A production-grade, declarative Cloud-Native infrastructure engineered by Juan E. This repository establishes a strict GitOps methodology on Amazon Elastic Kubernetes Service (EKS). It separates infrastructure provisioning from application lifecycle management: Terraform handles the foundational AWS layer, while ArgoCD assumes complete control over cluster state using the App of Apps pattern.

## System Architecture & GitOps Flow

1. **Infrastructure as Code (Terraform):** Provisions a dedicated VPC with multi-AZ topology, private subnets with auto-discovery tags, and a managed EKS control plane.
2. **Zero-Trust Identity (AWS IAM & IRSA):** Implements OpenID Connect (OIDC) to map native AWS IAM roles directly to Kubernetes Service Accounts, adhering to the principle of least privilege.
3. **Dynamic Compute (Karpenter):** Replaces traditional Auto Scaling Groups. Karpenter observes unschedulable pods and natively provisions right-sized, cost-optimized EC2 instances (Spot and On-Demand) directly from the AWS API in milliseconds.
4. **Continuous Deployment (ArgoCD):** Installed via Helm during the infrastructure bootstrap, ArgoCD syncs `kubernetes/workloads` from this Git repository once the root application is created (see "Creating root-application" below), continuously reconciling the cluster state against the defined manifests.

## Core Technical Highlights

* **App of Apps Pattern:** The `root-app.yaml` dictates the entire cluster configuration. Any unauthorized manual changes made via `kubectl` are automatically detected and overwritten by ArgoCD to enforce Git as the single source of truth.
* **Remote State Management:** Terraform state is stored remotely in Amazon S3 with native S3 state locking (`use_lockfile`, no DynamoDB), in two separate states (see [ADR 0001](docs/adr/0001-private-eks-endpoint.md)).
* **Automated Quality Gates:** Integrated GitHub Actions pipeline enforces syntax validation, `tflint` standards, and `tfsec` static security analysis on every commit.
* **SSL Offloading Prepared:** ArgoCD is deployed securely in ClusterIP mode without internal TLS, architected to allow the AWS Load Balancer Controller to handle Ingress routing and certificate termination.

## Repository Structure

```text
.
|-- .github/workflows/ci.yml       # Automated security and validation pipeline
|-- modules/
|   |-- vpc/                       # Network topology and discovery tags
|   |-- eks_cluster/               # Control plane, OIDC, and System Node Group
|   |-- eks_addons/                # IAM roles, SQS, Pod Identity (stage 1)
|   |-- stage2_runner/             # SSM-only EC2 that runs stage 2 against the private endpoint (stage 1)
|   |-- eks_addons_helm/           # AWS Load Balancer Controller and Karpenter via Helm (stage 2)
|   `-- gitops_argocd/             # ArgoCD Operator bootstrap via Helm (stage 2)
|-- stacks/
|   |-- infra/                     # Stage 1: vpc, eks_cluster, eks_addons (state: terraform.tfstate)
|   `-- cluster/                   # Stage 2: Helm releases and ArgoCD (state: cluster.tfstate)
|-- kubernetes/
|   |-- argocd-apps/               # Root application controller
|   `-- workloads/                 # Karpenter NodePools and dynamic deployments
`-- docs/adr/                      # Architecture decision records
```

Design decisions: [ADR 0001: private EKS endpoint and two-stage split](docs/adr/0001-private-eks-endpoint.md), [ADR 0002: stage 2 access path](docs/adr/0002-stage2-access-path.md).
## Deployment Instructions
**Prerequisites**

* AWS CLI configured with active credentials.
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
   terraform plan
   terraform apply
   ```
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
3. CoreDNS is resolving: `kubectl -n kube-system get pods -l k8s-app=kube-dns` are `Running`, and `kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default` returns an answer.
4. Flow logs are flowing: the CloudWatch log group for `vpc-eks-gitops-<environment>` receives events.

## Safe Teardown Protocol (Cost Prevention)

Destroying a GitOps cluster strictly requires draining dynamic resources prior to invoking Terraform. Failure to do so will result in orphaned EC2 Spot instances and deadlocked VPC dependencies.

Teardown is the reverse of the apply order: cluster stack (stage 2) first, then infra. Steps 1 to 5 need the private endpoint, so start the stage 2 runner and run them there (see ADR 0002). Step 6 runs from your workstation: it also destroys the runner.

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
   terraform destroy
   ```

6. **Destroy the infra stack (stage 1):**
   ```bash
   cd stacks/infra
   terraform destroy
   ```

> PowerShell note: quote the flag, for example `"-out=destroy.tfplan"`. A stale plan must be re-planned and applied immediately.
