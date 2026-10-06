#!/usr/bin/env bash
# Checks that the fixed strings in the Karpenter manifest match the Terraform naming,
# derived from the environment default. Usage: check-karpenter-names.sh [repo_root]
set -euo pipefail
root="${1:-.}"
yaml="$root/kubernetes/workloads/karpenter-nodepool.yaml"
main="$root/stacks/infra/main.tf"
vars="$root/stacks/infra/variables.tf"
addons="$root/modules/eks_addons/main.tf"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Prints the single quoted value of "<key> = "..."" in a file; fails unless exactly one line matches.
one() {
  local out
  out=$(tr -d '\r' < "$2" | sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p")
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "expected exactly one '$1 = \"...\"' in $2"
  printf '%s' "$out"
}

# default of variable "environment" (scoped to its block)
env=$(tr -d '\r' < "$vars" | awk '
  /^[[:space:]]*variable[[:space:]]+"environment"/ { b=1 }
  b && /^[[:space:]]*default[[:space:]]*=/ { gsub(/.*=[[:space:]]*"|".*/, ""); print; exit }')
[ -n "$env" ] || fail "no default for variable \"environment\" in $vars"

cluster_tpl=$(one cluster_name "$main")
cluster=${cluster_tpl//'${var.environment}'/$env}
role_tpl=$(one node_iam_role_name "$addons")
role=${role_tpl//'${var.cluster_name}'/$cluster}
case "$cluster$role" in *'$'*) fail "unresolved interpolation: '$cluster_tpl' / '$role_tpl'" ;; esac

yaml_role=$(tr -d '\r' < "$yaml" | sed -nE 's/^[[:space:]]*role:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p')
[ "$(printf '%s\n' "$yaml_role" | grep -c .)" = 1 ] || fail "expected exactly one 'role:' in $yaml"
[ "$yaml_role" = "$role" ] || fail "role: manifest='$yaml_role' terraform='$role'"

tags=$(tr -d '\r' < "$yaml" | sed -nE 's/^[[:space:]]*karpenter\.sh\/discovery:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p')
[ "$(printf '%s\n' "$tags" | grep -c .)" = 2 ] || fail "expected exactly 2 karpenter.sh/discovery values in $yaml"
while read -r t; do
  [ "$t" = "$cluster" ] || fail "discovery tag: manifest='$t' terraform='$cluster'"
done <<< "$tags"

echo "OK: env=$env cluster=$cluster role=$role"
