# Operator-side gate before (and after) the stage 1 destroy: lists AWS leftovers of the cluster.
# Read-only: aws describe/list calls only. Prints ids and names, never account ids or ARNs.
# Exit 0 = nothing left; exit 1 = leftovers found or a query failed (do not continue).
#
# Default (before `terraform destroy` in stacks/infra): the cluster, its cluster security group and the
# in-use ENIs of the managed nodes are expected, so only ENIs in status "available" (orphans) and
# load balancers are reported.
# -AfterDestroy (after stage 1 is destroyed): the cluster, any ENI tagged for it, its cluster security
# group and load balancers must all be gone.
#
# Not checked: NAT gateways and EC2 instances. Nothing in this repo's Terraform tags them with the
# cluster name, so there is no verified filter for them.
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

  if ($AfterDestroy) {
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
