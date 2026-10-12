# Operator-side gate before (and after) the stage 1 destroy: lists AWS leftovers of the cluster.
# Read-only: aws describe/list calls only. Prints ids and names, never account ids or ARNs.
# Exit 0 = nothing left; exit 1 = leftovers found or a query failed (do not continue).
#
# Default (before `terraform destroy` in stacks/infra): the cluster, its cluster security group, the
# in-use ENIs of the managed nodes, the managed nodes, the runner and the NAT gateway are expected,
# so only these are reported: ENIs in status "available" (orphans), load balancers, and instances in
# the cluster VPC that carry the tag key karpenter.sh/nodepool (Karpenter nodes). If the VPC is not
# found a NOTE line is printed and the instance check is skipped (not a failure).
# -AfterDestroy (after stage 1 is destroyed): the cluster, any ENI tagged for it, its cluster security
# group, load balancers, instances (runner, managed nodes, Karpenter nodes), NAT gateways, Elastic IPs
# and the VPC must all be gone.
#
# Filter basis. Repo code (terraform-aws-modules vpc 5.21.0 and eks 20.37.2, this repo's modules):
#   VPC, NAT gateway and Elastic IP carry Name = vpc-<cluster> / vpc-<cluster>-<az>
#   (modules/vpc/main.tf, vpc module main.tf); the runner carries Name = <cluster>-stage2-runner
#   (modules/stage2_runner/main.tf); managed node group instances carry karpenter.sh/discovery =
#   <cluster> through the launch template tag_specifications (modules/eks_cluster/main.tf tags).
# Karpenter docs (https://karpenter.sh/docs/concepts/nodeclasses/, "spec.tags"): instances carry
#   karpenter.sh/nodepool and eks:eks-cluster-name = <cluster>.
# NOT VERIFIED live until the live test: the Karpenter tags with controller 1.14.1, the tags EKS adds
# to managed node group instances, and the exact Name values of the NAT gateway and Elastic IP.
# "terminated" instances and "deleted" NAT gateways stay listed for a while and are excluded by state.
#
# Usage: .\scripts\teardown\check-leftovers.ps1 [-ClusterName <name>] [-Region <region>] [-AfterDestroy]
# Uses the active AWS profile (AWS_PROFILE).
param(
  [string]$ClusterName = 'eks-gitops-production',
  [string]$Region = 'us-east-1',
  [switch]$AfterDestroy
)
$ErrorActionPreference = 'Stop'

# Runs aws, fails closed on a non-zero exit code, returns the whitespace-separated tokens printed.
function Invoke-Aws([string[]]$CliArgs) {
  $out = & aws @CliArgs --region $Region --output text
  if ($LASTEXITCODE -ne 0) { throw "aws $($CliArgs[0]) $($CliArgs[1]) failed with exit code $LASTEXITCODE" }
  @(($out -join ' ') -split '\s+' | Where-Object { $_ -and $_ -ne 'None' })
}

$left = [ordered]@{}
function Add-Finding([string]$What, [string[]]$Ids) {
  if ($Ids.Count -gt 0) { $left[$What] = $Ids }
}

try {
  Write-Host "cluster=$ClusterName region=$Region afterDestroy=$($AfterDestroy.IsPresent)"

  # ENIs left by the VPC CNI of terminated nodes (status available, no attachment) block the deletion
  # of the node and cluster security groups. Tag seen on the orphan ENI in the 2026-10-11 live test.
  $eniFilters = @("Name=tag:cluster.k8s.amazonaws.com/name,Values=$ClusterName")
  if (-not $AfterDestroy) { $eniFilters += 'Name=status,Values=available' }
  Add-Finding 'ENIs tagged for the cluster' (Invoke-Aws (@('ec2', 'describe-network-interfaces', '--filters') + $eniFilters + @('--query', 'NetworkInterfaces[].NetworkInterfaceId')))

  # Same query as alb_arns in teardown-stage2.sh; only the name part of each ARN is printed.
  $arns = Invoke-Aws @('resourcegroupstaggingapi', 'get-resources',
    '--resource-type-filters', 'elasticloadbalancing:loadbalancer',
    '--tag-filters', "Key=elbv2.k8s.aws/cluster,Values=$ClusterName",
    '--query', 'ResourceTagMappingList[].ResourceARN')
  Add-Finding 'load balancers tagged for the cluster' @($arns | ForEach-Object { ($_ -split 'loadbalancer/')[-1] })

  # Instance states that still hold or may resume resources.
  $liveStates = 'pending,running,stopping,stopped'
  $vpcName = "vpc-$ClusterName"
  $vpcIds = Invoke-Aws @('ec2', 'describe-vpcs', '--filters', "Name=tag:Name,Values=$vpcName", '--query', 'Vpcs[].VpcId')

  if (-not $AfterDestroy) {
    if ($vpcIds.Count -eq 0) {
      Write-Host "NOTE: VPC $vpcName not found; Karpenter instance check skipped."
    }
    else {
      # Karpenter nodes: tag key karpenter.sh/nodepool (Karpenter docs). Managed nodes and the runner
      # do not carry it, so they are not reported here.
      Add-Finding 'Karpenter instances in the VPC' (Invoke-Aws @('ec2', 'describe-instances',
        '--filters', "Name=vpc-id,Values=$($vpcIds -join ',')", 'Name=tag-key,Values=karpenter.sh/nodepool',
        "Name=instance-state-name,Values=$liveStates",
        '--query', 'Reservations[].Instances[].InstanceId'))
    }
  }

  if ($AfterDestroy) {
    # Separate calls, ORed here: describe-instances ANDs its filters. Basis in the header comment.
    $instanceIds = @()
    foreach ($tagFilter in @("Name=tag:Name,Values=$ClusterName-stage2-runner",
        "Name=tag:karpenter.sh/discovery,Values=$ClusterName",
        "Name=tag:eks:eks-cluster-name,Values=$ClusterName")) {
      $instanceIds += Invoke-Aws @('ec2', 'describe-instances', '--filters', $tagFilter,
        "Name=instance-state-name,Values=$liveStates", '--query', 'Reservations[].Instances[].InstanceId')
    }
    Add-Finding 'instances of the cluster (runner, managed or Karpenter nodes)' @($instanceIds | Select-Object -Unique)

    # Single NAT gateway named vpc-<cluster>-<az> (vpc module); "deleted" entries are excluded by state.
    Add-Finding 'NAT gateways' (Invoke-Aws @('ec2', 'describe-nat-gateways',
      '--filter', "Name=tag:Name,Values=$vpcName-*", 'Name=state,Values=pending,available,deleting',
      '--query', 'NatGateways[].NatGatewayId'))
    # NAT Elastic IP, same Name pattern (vpc module aws_eip.nat); an unattached address costs money.
    Add-Finding 'Elastic IPs' (Invoke-Aws @('ec2', 'describe-addresses',
      '--filters', "Name=tag:Name,Values=$vpcName-*", '--query', 'Addresses[].AllocationId'))
    Add-Finding 'VPC' $vpcIds
    Add-Finding 'EKS cluster' (Invoke-Aws @('eks', 'list-clusters', '--query', "clusters[?@=='$ClusterName']"))
    # EKS-created, not managed by Terraform; left over when an orphan ENI still uses it.
    Add-Finding 'cluster security groups' (Invoke-Aws @('ec2', 'describe-security-groups',
      '--filters', "Name=group-name,Values=eks-cluster-sg-$ClusterName-*",
      '--query', 'SecurityGroups[].GroupId'))
  }
}
catch {
  Write-Host "FAIL: $($_.Exception.Message). Do not continue."
  exit 1
}

if ($left.Count -eq 0) {
  Write-Host 'OK: nothing left.'
  exit 0
}
foreach ($k in $left.Keys) { Write-Host "LEFT: $k -> $($left[$k] -join ' ')" }
Write-Host 'FAIL: leftovers found. Do not run terraform destroy until they are gone.'
exit 1
