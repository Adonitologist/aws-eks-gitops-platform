# Enterprise AWS EKS GitOps Platform

![Terraform CI](https://github.com/Adonitologist/aws-eks-gitops-platform/actions/workflows/ci.yml/badge.svg)
![Terraform](https://img.shields.io/badge/IaC-Terraform_v1.5+-844FBA?logo=terraform)
![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.30-326CE5?logo=kubernetes)
![ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo)
![AWS](https://img.shields.io/badge/Cloud-AWS_EKS-232F3E?logo=amazon-aws)

A production-grade, declarative Cloud-Native infrastructure engineered by Juan E. This repository establishes a strict GitOps methodology on Amazon Elastic Kubernetes Service (EKS). It separates infrastructure provisioning from application lifecycle management: Terraform handles the foundational AWS layer, while ArgoCD assumes complete control over cluster state using the App of Apps pattern.

## System Architecture & GitOps Flow

1. **Infrastructure as Code (Terraform):** Provisions a dedicated VPC with multi-AZ topology, private subnets with auto-discovery tags, and a managed EKS control plane.
2. **Zero-Trust Identity (AWS IAM & IRSA):** Implements OpenID Connect (OIDC) to map native AWS IAM roles directly to Kubernetes Service Accounts, adhering to the principle of least privilege.
3. **Dynamic Compute (Karpenter):** Replaces traditional Auto Scaling Groups. Karpenter observes unschedulable pods and natively provisions right-sized, cost-optimized EC2 instances (Spot and On-Demand) directly from the AWS API in milliseconds.
4. **Continuous Deployment (ArgoCD):** Installed via Helm during the infrastructure bootstrap, ArgoCD immediately syncs with this Git repository (`kubernetes/` directory) to continuously reconcile the cluster state against the defined manifests.

## Core Technical Highlights

* **App of Apps Pattern:** The `root-app.yaml` dictates the entire cluster configuration. Any unauthorized manual changes made via `kubectl` are automatically detected and overwritten by ArgoCD to enforce Git as the single source of truth.
* **Remote State Management:** Terraform state is securely locked and stored remotely using Amazon S3 and DynamoDB, enabling safe CI/CD pipeline execution.
* **Automated Quality Gates:** Integrated GitHub Actions pipeline enforces syntax validation, `tflint` standards, and `tfsec` static security analysis on every commit.
* **SSL Offloading Prepared:** ArgoCD is deployed securely in ClusterIP mode without internal TLS, architected to allow the AWS Load Balancer Controller to handle Ingress routing and certificate termination.

## Repository Structure

```text
.
├── .github/workflows/ci.yml       # Automated security and validation pipeline
├── modules/
│   ├── vpc/                       # Network topology and discovery tags
│   ├── eks_cluster/               # Control plane, OIDC, and System Node Group
│   ├── eks_addons/                # AWS Load Balancer Controller and IAM Roles
│   └── gitops_argocd/             # ArgoCD Operator bootstrap via Helm
├── kubernetes/
│   ├── argocd-apps/               # Root application controller
│   └── workloads/                 # Karpenter NodePools and dynamic deployments
├── backend.tf                     # S3 + DynamoDB remote state configuration
└── main.tf                        # Root module orchestration
```
## Deployment Instructions
**Prerequisites**

    AWS CLI configured with active credentials.

    Terraform v1.5.0+ installed.

    Ensure your S3 bucket and DynamoDB table names are updated in backend.tf.

**Execution**

    Initialize the Environment:
    ```bash

    terraform init

    Validate and Plan:
    ```bash

    terraform validate
    terraform plan -var="environment=production"

    Deploy Infrastructure & Bootstrap GitOps:
    ```bash

    terraform apply -var="environment=production" -auto-approve

    Verify GitOps Synchronization:
    Once Terraform finishes, ArgoCD will automatically take over. You can verify the Karpenter NodePools are active by querying the cluster:
    ```bash

    aws eks update-kubeconfig --region us-east-1 --name eks-gitops-production
    kubectl get nodepools

## Safe Teardown Protocol (Cost Prevention)

Destroying a GitOps cluster strictly requires draining dynamic resources prior to invoking Terraform. Failure to do so will result in orphaned EC2 Spot instances and deadlocked VPC dependencies.

1. **Destroy GitOps Workloads & Ingress:**
   Remove the root application to force Argo CD to gracefully delete Ingress resources, signaling the AWS Load Balancer Controller to dismantle the physical ALBs.
   ```bash
   kubectl delete application root-application -n argocd

2. **Drain Karpenter Capacity:**
    Force Karpenter to cordorn and terminate all dynamically provisioned EC2 compute nodes to prevent ghost charges.
   ```bash

    kubectl delete nodepool --all
    kubectl delete ec2nodeclass --all

3. **Purge Orphaned Finalizers (If Namespace Deadlocked):**
    If the argocd namespace hangs in Terminating state, force the release of lingering finalizers:
   ```bash

    kubectl patch application root-application -n argocd --type=merge -p '{"metadata":{"finalizers":[]}}'

4. **Execute Core Infrastructure Destruction:**
    Once the cluster is drained of runtime-injected resources, proceed to safely destroy the Terraform state.
   ```bash

    terraform destroy -auto-approve
```

### Prerequisites
* AWS CLI configured with active credentials.
* Terraform v1.5.0+ installed.
* An isolated S3 bucket for remote state locking (Bootstrapped out-of-band to prevent accidental destruction):
