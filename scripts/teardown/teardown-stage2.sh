#!/usr/bin/env bash
# Drains the stage 2 workloads before `terraform destroy` in stacks/cluster. Run it on the stage 2 runner.
# Usage: teardown-stage2.sh [--dry-run]    (dry-run prints every command and runs nothing)
# Env: CLUSTER_NAME (default eks-gitops-production), AWS_REGION (default us-east-1),
#      ALB_TIMEOUT / NODE_TIMEOUT in seconds (default 900 / 600), POLL_INTERVAL in seconds (default 15),
#      ARGOCD_ALLOWED_CIDRS (comma-separated, e.g. 203.0.113.10/32; only used to print the destroy command)
set -euo pipefail

cluster="${CLUSTER_NAME:-eks-gitops-production}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
alb_timeout="${ALB_TIMEOUT:-900}"
node_timeout="${NODE_TIMEOUT:-600}"
interval="${POLL_INTERVAL:-15}"
dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

log() { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { if [ "$dry" = 1 ]; then echo "DRY-RUN: $*"; else log "$*"; "$@"; fi; }

# wait_empty <what> <timeout_s> <command...>: polls until the command prints nothing.
wait_empty() {
  local what=$1 timeout=$2 out waited=0
  shift 2
  if [ "$dry" = 1 ]; then echo "DRY-RUN: wait until no $what (timeout ${timeout}s): $*"; return; fi
  while :; do
    out=$("$@") || fail "query for $what failed (permissions or connectivity); do not continue"
    if [ -z "$out" ]; then log "no $what left"; return; fi
    [ "$waited" -lt "$timeout" ] || fail "timeout after ${timeout}s, still present: $(echo "$out" | tr '\n' ' ')"
    log "waiting for $what: $(echo "$out" | tr '\n' ' ')"
    sleep "$interval"
    waited=$((waited + interval))
  done
}

alb_arns() {
  aws resourcegroupstaggingapi get-resources \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$cluster" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text
}
# Both the NodeClaims and the nodes they became must be gone.
karpenter_capacity() {
  kubectl get nodeclaims -o name
  kubectl get nodes -l karpenter.sh/nodepool -o name
}

log "cluster=$cluster region=$AWS_REGION dry-run=$dry"

# 1. The ingress is owned by the Helm release, not Argo CD: delete it so the controller removes its ALB.
run kubectl delete ingress argocd-server -n argocd --ignore-not-found --timeout=300s

# 2. Do not continue while ALBs of this cluster exist (they block VPC deletion).
wait_empty "load balancers tagged for $cluster" "$alb_timeout" alb_arns

# 3. Root application (cascades to NodePool/EC2NodeClass through its finalizer), then the rest explicitly.
run kubectl delete application root-application -n argocd --ignore-not-found --timeout=300s
run kubectl delete nodepool --all --ignore-not-found --timeout=300s
run kubectl delete ec2nodeclass --all --ignore-not-found --timeout=300s

# 4. Karpenter capacity must be gone, or EC2 instances are orphaned.
wait_empty "Karpenter nodeclaims and nodes" "$node_timeout" karpenter_capacity

cidrs="${ARGOCD_ALLOWED_CIDRS:-<cidr>}"
cidrs="[\"${cidrs//,/\",\"}\"]"
log "Done. Not run: destroy stage 2 yourself with"
echo "  cd stacks/cluster && terraform destroy -var='argocd_allowed_cidrs=$cidrs'"
