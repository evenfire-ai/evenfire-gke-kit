#!/usr/bin/env bash
#
# Detects, on the targeted cluster, the addresses that the overlay's
# NetworkPolicies must allow explicitly, and rewrites the overlay patches:
#
#   patches/k8s-api-ip*.yaml           ipBlock list  <- kubernetes Service ClusterIP + endpoint IP(s)
#   patches/hcc-k8s-api-cidrs.yaml     CONTEXT_MAPPER_K8S_API_CIDRS   <- same list, comma-joined
#                                      CONTEXT_MAPPER_NODELOCAL_DNS_CIDR <- kube-dns Service ClusterIP/32
#   patches/nodelocal-dns-egress-rule.yaml   ipBlock cidr <- kube-dns Service ClusterIP/32
#
# Why two API IPs: a pod connects to the `kubernetes` Service ClusterIP; the
# dataplane DNATs it to the real API-server endpoint and may evaluate egress
# policy against the post-DNAT address. Carrying both keeps the rule valid on
# either side of the DNAT.
#
# Usage:
#   CONTEXT=my-kube-context OVERLAY_DIR=deploy/overlays/OVERLAY_NAME scripts/detect-k8s-api-ip.sh
#
# Read-only against the cluster; writes only the files above. Review the
# printed diff, then commit.
set -euo pipefail

OVERLAY_DIR="${OVERLAY_DIR:?set OVERLAY_DIR to the overlay directory (e.g. deploy/overlays/my-gke)}"
CONTEXT="${CONTEXT:?set CONTEXT to the kube-context of the TARGET cluster}"

PATCH_FILES=()
while IFS= read -r file; do
  PATCH_FILES+=("$file")
done < <(find "$OVERLAY_DIR/patches" -maxdepth 1 -name 'k8s-api-ip*.yaml' | sort)

if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
  echo "ERROR: no k8s-api-ip*.yaml patches found in $OVERLAY_DIR/patches." >&2
  exit 1
fi

kq() { kubectl --context "$CONTEXT" "$@"; }

CLUSTER_IP="$(kq get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')"
ENDPOINT_IPS="$(kq get endpoints kubernetes -n default -o jsonpath='{.subsets[*].addresses[*].ip}')"
DNS_IP="$(kq -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')"

[ -n "$CLUSTER_IP" ]   || { echo "ERROR: could not read kubernetes svc clusterIP." >&2; exit 1; }
[ -n "$ENDPOINT_IPS" ] || { echo "ERROR: could not read kubernetes endpoints (v1 Endpoints is deprecated in k8s 1.33+; check EndpointSlice)." >&2; exit 1; }
[ -n "$DNS_IP" ]       || { echo "ERROR: could not read kube-system/kube-dns clusterIP." >&2; exit 1; }

for ip in "$CLUSTER_IP" $ENDPOINT_IPS "$DNS_IP"; do
  if ! [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "ERROR: detected a non-IPv4 address '$ip' — refusing to write patches." >&2
    exit 1
  fi
done

CIDRS=("$CLUSTER_IP/32")
for ip in $ENDPOINT_IPS; do
  [ "$ip" = "$CLUSTER_IP" ] && continue
  CIDRS+=("$ip/32")
done
DNS_CIDR="$DNS_IP/32"

echo "Detected K8s API ClusterIP: $CLUSTER_IP"
echo "Detected K8s API endpoints: $ENDPOINT_IPS"
echo "Detected kube-dns ClusterIP: $DNS_IP"
echo "ipBlock CIDRs: ${CIDRS[*]}"

# 1. k8s-api-ip*.yaml — replace the whole ipBlock list under the egress `- to:`.
CIDR_LIST="${CIDRS[*]}"
for PATCH_FILE in "${PATCH_FILES[@]}"; do
  tmp="$(mktemp)"
  awk -v cidrs="$CIDR_LIST" '
    /^[[:space:]]*-[[:space:]]+to:[[:space:]]*$/ {
      print
      match($0, /^[[:space:]]*/)
      base = substr($0, 1, RLENGTH)
      ib = base "    "
      cd = base "        "
      n = split(cidrs, C, " ")
      for (i = 1; i <= n; i++) {
        print ib "- ipBlock:"
        print cd "cidr: " C[i]
      }
      skip = 1
      next
    }
    skip && /^[[:space:]]*-[[:space:]]+ipBlock:[[:space:]]*$/ { next }
    skip && /^[[:space:]]*cidr:[[:space:]]/ { next }
    skip && /^[[:space:]]*#/ { next }
    skip && /^[[:space:]]*$/ { next }
    { skip = 0; print }
  ' "$PATCH_FILE" > "$tmp"
  mv "$tmp" "$PATCH_FILE"
  echo "Patched $PATCH_FILE"
done

# 2. hcc-k8s-api-cidrs.yaml — the two env values.
HCC_FILE="$OVERLAY_DIR/patches/hcc-k8s-api-cidrs.yaml"
if [ -f "$HCC_FILE" ]; then
  HCC_VALUE="$(IFS=,; echo "${CIDRS[*]}")"
  tmp="$(mktemp)"
  awk -v api="$HCC_VALUE" -v dns="$DNS_CIDR" '
    $0 ~ /name: CONTEXT_MAPPER_K8S_API_CIDRS/    { print; getline; print "              value: \"" api "\""; next }
    $0 ~ /name: CONTEXT_MAPPER_NODELOCAL_DNS_CIDR/ { print; getline; print "              value: \"" dns "\""; next }
    { print }
  ' "$HCC_FILE" > "$tmp"
  mv "$tmp" "$HCC_FILE"
  PATCH_FILES+=("$HCC_FILE")
  echo "Patched $HCC_FILE (K8S_API_CIDRS=$HCC_VALUE, NODELOCAL_DNS_CIDR=$DNS_CIDR)"
fi

# 3. nodelocal-dns-egress-rule.yaml — the single ipBlock cidr.
DNS_FILE="$OVERLAY_DIR/patches/nodelocal-dns-egress-rule.yaml"
if [ -f "$DNS_FILE" ]; then
  tmp="$(mktemp)"
  awk -v dns="$DNS_CIDR" '
    /^[[:space:]]*cidr:[[:space:]]/ { match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) "cidr: " dns; next }
    { print }
  ' "$DNS_FILE" > "$tmp"
  mv "$tmp" "$DNS_FILE"
  PATCH_FILES+=("$DNS_FILE")
  echo "Patched $DNS_FILE (cidr=$DNS_CIDR)"
fi

echo ""
echo "git diff preview:"
git --no-pager diff -- "${PATCH_FILES[@]}" 2>/dev/null || true
echo ""
echo "Remaining placeholders (must be empty before apply):"
grep -rn '<[A-Z_]*>' "$OVERLAY_DIR" --include='*.yaml' || echo "  none"
