# 04 — NetworkPolicies and the CNI

> **This is the most important guide in the folder.** The platform's security
> boundary between tenants' agents, the control plane and the database is
> NetworkPolicy. Read it before your first apply, not after.
>
> **What is fixed vs. what is your choice**
>
> | Fixed (do not weaken) | Flexible (your decision; we show what we do) |
> |---|---|
> | The cluster's dataplane **enforces** NetworkPolicy before any workload is applied (see the probe below) | *Which* enforcing dataplane: Dataplane V2 (Cilium) or the Calico add-on. We run Calico; Dataplane V2 is the recommended path for a new cluster but not validated by us |
> | Default-deny in both directions in every platform namespace, plus the named allow lanes in `deploy/base` | How traffic enters (your edge needs its own lane, [03](03-ingress-and-hostnames.md) B.2) |
> | The API-server and DNS CIDRs match **your** cluster ([below](#fill-the-cluster-specific-cidrs)) | Whether you add your own policies: monitoring scrapers, service mesh sidecars, cluster-wide baseline policies |
> | HCC/WRC-owned (`clerum.io/managed-by`) policies are left alone | Tightening public egress further (e.g. FQDN allow-lists instead of `0.0.0.0/0:443`) if your dataplane supports it — **verify** on your GKE version; the base uses the broad rule plus the exception set |
> | | How you roll out: validate with WRC `CLERUM_NETWORK_POLICY_ENFORCEMENT_MODE` and the probes before setting `..._CONFIRMED=true` |
>
> Rule of thumb: you may **add** policies and **narrow** what the base allows;
> do not delete a base policy to "make something work". A connect timeout
> means a lane is missing: find it, do not remove the deny.

## The security model (from `deploy/base`)

Every platform namespace is **default-deny in both directions**, and every
allowed hop is a named policy. Three layers:

| Layer | Examples | Owner |
|---|---|---|
| L0 `deny-all-<ns>` | `deny-all-control-plane`, `deny-all-mcp-host`, ... (`clerum.io/policy-type: default-deny`) | base (static) in every platform namespace (named `sandbox-ui-static-deny-all` and `llm-hooks-static-default-deny` there); in HCC's runtime namespaces (`mcp-server`, `rpc-proxy`, `sandbox-recipes`, `sandbox-ui`) HCC **also** reconciles `deny-all-<ns>` at runtime |
| L1 infrastructure | `allow-dns-egress-<ns>` (UDP/TCP 53 to kube-system), `allow-k8s-api-egress-<ns>` (443 to the API server, pod-selected), `allow-hcc-api-egress-<ns>` (8081 to the HCC gateway) | base ships DNS egress in every namespace except `gfs` (HCC generates it with the GlobalFileSystem) and `llm-hooks` (sealed: no egress at all); `allow-hcc-api-egress-*` in `mcp-server`, `rpc-proxy`, `sandbox-recipes`; `allow-k8s-api-egress-*` in `channels`, `control-plane`, `mcp-host`. HCC also reconciles the runtime-namespace ones and is the **only** source of `allow-k8s-api-egress-*` in `mcp-server`, `rpc-proxy`, `sandbox-recipes`, where K8s API egress is **opt-in** per pod via the label `clerum.io/k8s-api-egress=true` |
| L2 service lanes | `control-api-to-postgres`, `control-ui-network`, `rpc-proxy`, `allow-cloudflared-egress`, ... | base (static) |
| Dynamic | `mcp-host-<host>-ingress-rpc-proxy`, `rpc-proxy-<host>-egress-mcp-host`, `ctx-<context>-<server>`, per-recipe `wf-<recipe>-*`, per-hook `llmhook-<key>` | HCC / WRC at reconcile time |

Public egress (LLM APIs, chat providers, OAuth) is `0.0.0.0/0` on 443 (and 80
for the agent's `http_request` tool) **minus** the ranges in
`deploy/base/public-egress-exceptions.yaml` (`PublicEgressExceptionSet`:
RFC1918, link-local `169.254.0.0/16`, CGNAT, multicast, documentation ranges),
projected into every such rule by a Kustomize `replacements:` block. Internal
hops are always separate selector-based policies.

Consequences you must plan for:

- **A CNI that does not enforce NetworkPolicy makes all of this decorative.**
  The objects are accepted by the API server and nothing happens. The platform
  then runs wide open: any pod can reach `control-api:8090`, Postgres, or an
  agent's runtime port whose edge-header trust is forgeable.
- **With enforcement, a wrong or missing CIDR breaks real traffic**: the API
  server address and the DNS address are the two cluster-specific values the
  policies cannot know, hence the patches below.

## What Evenfire runs, and what is verified vs. assumed

| | Status |
|---|---|
| CNI | GKE legacy **Calico network-policy add-on** (`networkPolicy.enabled=True provider=CALICO`), created with `--enable-network-policy` |
| Enforcement live | **verified** on Evenfire's reference clusters: `calico-node` running on every node, policies enforcing, and denied hops observed at packet level |
| Post-DNAT evaluation | **verified on Calico**: egress to the `kubernetes` Service ClusterIP is evaluated against the API-server endpoint IP after kube-proxy's DNAT, so a ClusterIP-only rule breaks the operators |
| NodeLocal DNSCache | the kube-dns ClusterIP ipBlock is **verified on an Evenfire reference cluster under Calico enforcement** |
| GKE Dataplane V2 (Cilium) | **not validated by Evenfire**. Enforcement is native (no add-on), and the dual ClusterIP+endpoint CIDRs are expected to hold on either side of service translation. Treat as "verify" (procedure below). |

## Choosing and checking the dataplane on your cluster

Read the state:

```bash
gcloud container clusters describe <CLUSTER_NAME> --zone=<ZONE> --project=<GCP_PROJECT_ID> \
  --format='value(networkPolicy.enabled,networkPolicy.provider,networkConfig.datapathProvider,addonsConfig.networkPolicyConfig.disabled,addonsConfig.dnsCacheConfig.enabled)'
```

| Output | Meaning |
|---|---|
| `True CALICO LEGACY_DATAPATH ...` | Calico add-on, enforcement on (Evenfire's reference) |
| `... ADVANCED_DATAPATH ...` | Dataplane V2: NetworkPolicy enforced natively; `networkPolicy.enabled` is irrelevant |
| blank / `False` and `LEGACY_DATAPATH` | **no enforcement** — policies are decorative |

Recommendation for a new cluster: **Dataplane V2** (`--enable-dataplane-v2`;
it is the default on recent GKE versions, but confirm with the describe
command above after creation) — nothing to install, no node-pool recreation
to turn it on, and policy logging is available. If you must match
Evenfire exactly, create the cluster with `--enable-network-policy` (Calico).
Do not run both.

Enabling Calico enforcement on an **existing** legacy-datapath cluster is a
three-step, node-recreating change: `--update-addons=NetworkPolicy=ENABLED`
(installs calico-typha; `calico-node` stays at 0 desired), then
`--enable-network-policy` (flips the control-plane flag; still not enforcing),
then a same-version node-pool upgrade (`gcloud container clusters upgrade
<CLUSTER_NAME> --node-pool=<POOL> --cluster-version=<CURRENT>`) which recreates
nodes labelled `projectcalico.org/ds-ready=true` so `calico-node` schedules.
Only then is anything enforced. Expect every pod to bounce once.

## Fill the cluster-specific CIDRs

Run the template's script against **your** cluster; it rewrites five files
([overlay-template/scripts/detect-k8s-api-ip.sh](overlay-template/scripts/detect-k8s-api-ip.sh)):

```bash
CONTEXT="$CONTEXT" OVERLAY_DIR=deploy/overlays/$OVERLAY_NAME \
  bash deploy/overlays/$OVERLAY_NAME/scripts/detect-k8s-api-ip.sh
```

What it reads and where it goes:

| Value | Command | Lands in |
|---|---|---|
| `kubernetes` Service ClusterIP | `kubectl --context "$CONTEXT" get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}'` | `patches/k8s-api-ip*.yaml` ipBlocks, `CONTEXT_MAPPER_K8S_API_CIDRS` |
| API-server endpoint IP(s) | `kubectl --context "$CONTEXT" get endpoints kubernetes -n default -o jsonpath='{.subsets[*].addresses[*].ip}'` | same |
| kube-dns Service ClusterIP | `kubectl --context "$CONTEXT" -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}'` | `patches/nodelocal-dns-egress-rule.yaml`, `CONTEXT_MAPPER_NODELOCAL_DNS_CIDR` |

Why both API addresses: pods connect to the ClusterIP; the dataplane DNATs it
to the endpoint; Calico evaluates the post-DNAT address (verified). Carrying
both is intended to keep the rule valid whichever side your CNI evaluates;
on Dataplane V2 that is expected, not verified by Evenfire, so confirm it with
the API-server probe under [Post-apply verification](#post-apply-verification). Namespaces whose
API egress HCC manages (`mcp-server`, `rpc-proxy`, `sandbox-recipes`) get the
same pair through `CONTEXT_MAPPER_K8S_API_CIDRS`; HCC validates that value at
startup and crashes on a malformed or over-broad entry (prefix shorter than
/24), so an unreplaced placeholder fails loudly.

Why the DNS ipBlock: with NodeLocal DNSCache the resolver answering on the
kube-dns ClusterIP is a host-network cache, not a `kube-system` pod, so the
base rule (`namespaceSelector: kube-system`) does not match it under Calico
enforcement. The ipBlock to `<KUBE_DNS_CLUSTER_IP>/32` closes that gap and is
harmless when the cache is off.

Re-run the script if you ever recreate the cluster or its control plane; the
endpoint IP changes.

## Pre-flight check (after the first full deploy)

The public tree ships a read-only checker. It reads live policies, so it is
only meaningful **after** the first full deploy (HCC running, `GlobalFileSystem`
Ready; step B14 in [07](07-deploy-sequence-and-verification.md)). It needs the
overlay name and the context explicitly:

```bash
OVERLAY=$OVERLAY_NAME CONTEXT="$CONTEXT" bash deploy/scripts/np-enforce-preflight.sh
```

It runs both linters on the render, then checks: [1] the API ClusterIP +
endpoint are readable; [2] `allow-k8s-api-egress-<ns>` exists in
`channels control-plane mcp-host mcp-server rpc-proxy sandbox-recipes` and
carries the endpoint IP, no over-broad/stale CIDR; [3] every namespace labelled
`app.kubernetes.io/part-of=clerum` has a policy allowing 53/UDP+TCP to the
kube-dns ClusterIP; [4] pods in HCC's runtime namespaces with API RBAC carry
the opt-in label (WARN); [5] no policy grants a sealed `llm-hooks` pod egress.

It **cannot exit 0 on this base**. Read it as follows:

| Output | Meaning |
|---|---|
| `[3] FAIL llm-hooks: no NetworkPolicy allows TCP/UDP 53 ...` | **expected, always.** `llm-hooks` is sealed by design (no egress, not even DNS; check [5] enforces exactly that). With only this FAIL the result is clean, even though the script exits 1 |
| `[2] FAIL mcp-server` / `rpc-proxy` / `sandbox-recipes: allow-k8s-api-egress-... not found` | expected until HCC has started once (it creates these at startup); a FAIL after that is real |
| `[3] FAIL gfs: ...` | expected until the `GlobalFileSystem` instance is reconciled (HCC generates the gfs DNS policy); a FAIL after that is real |
| `[0] PASS enforcement is DISABLED (expected pre-flip)` / `WARN ... already ENABLED` | ignore: check 0 only reads the Calico flag `networkPolicy.enabled` (and only for `gke_*` contexts). On Dataplane V2 it prints DISABLED although enforcement is on; on a Calico cluster created with enforcement it warns. Use the describe command above instead |
| `[3] FAIL ingress: ...` (Cloudflare only) | the `allow-dns-egress-ingress` patch target is still commented ([02](02-assembly-and-overlay-structure.md)) |
| any other FAIL | a real gap: fix it before trusting enforcement |

## Post-apply verification

```bash
# every rendered NetworkPolicy exists in the cluster and its spec matches
bash deploy/scripts/verify-networkpolicies.sh --overlay $OVERLAY_NAME --context "$CONTEXT"
```

This renders the overlay, runs both linters, refuses if the base's placeholder
address is still rendered, then compares against `kubectl get networkpolicy -A`.
It is read-only. Evenfire's CD runs it after every apply.

Prove enforcement on **your** dataplane at least once (and before setting
`CLERUM_NETWORK_POLICY_ENFORCEMENT_CONFIRMED=true` on WRC). Run the probes
from `profiles`: a throwaway pod there matches only `deny-all-profiles` and
`allow-dns-egress-profiles` (`podSelector: {}`), so DNS is its one allowed lane
and everything else must be denied. A pod in a namespace without that DNS
policy would fail the positive probe for the wrong reason.

```bash
# 1. positive: the DNS lane works (a failure here also makes probe 2 meaningless)
kubectl --context "$CONTEXT" -n profiles run np-dns --rm -i --restart=Never \
  --image=busybox:1.36 -- nslookup control-api.control-plane.svc.cluster.local
# expected: an answer with the control-api ClusterIP

# 2. negative: an UNALLOWED hop must time out
kubectl --context "$CONTEXT" -n profiles run np-probe --rm -i --restart=Never \
  --image=curlimages/curl:8.7.1 -- \
  sh -c 'curl -sS -m 5 -o /dev/null -w "%{http_code}\n" http://control-api.control-plane.svc.cluster.local:8090/health || echo BLOCKED'
# expected: BLOCKED (profiles has no lane to control-api:8090; only profile-control-funnel does)

# 3. API-server lane: the operators must not be timing out against the Kubernetes API
kubectl --context "$CONTEXT" -n control-plane logs deploy/host-context-controller --since=30m | grep -iE 'timeout|ETIMEDOUT'
# expected: no steady stream of Kubernetes-API timeouts (a stray unrelated timeout line is not a failure)
```

If probe 2 prints `200`, enforcement is **not** active; stop and fix the
dataplane before going further. If probe 1 or 3 fails, a CIDR is wrong for
your dataplane ([fill the CIDRs](#fill-the-cluster-specific-cidrs), [08](08-troubleshooting-and-gotchas.md)).

WRC's `CLERUM_NETWORK_POLICY_ENFORCEMENT_MODE` stays `required` in the
template and `..._CONFIRMED` stays `"false"` until all three probes pass on
*this* cluster. Until then WRC **refuses** every WorkflowRecipe whose MCP
servers declare external egress, with `NetworkPolicy enforcement mode is
required for WorkflowRecipe "<name>", but CLERUM_NETWORK_POLICY_ENFORCEMENT_CONFIRMED
is not true`. That is intended; flip the flag once proven (step C7 in
[07](07-deploy-sequence-and-verification.md)).

## GKE-specific egress considerations

- **Metadata server / Workload Identity.** `169.254.169.254` sits inside the
  `169.254.0.0/16` exception, so pods with the standard public-egress rules
  cannot reach the GKE metadata server. The platform does not need it (image
  pulls happen on the node). If you add a workload of your own that does
  (e.g. Vertex AI with application-default credentials through Workload
  Identity), add a hand-written egress NetworkPolicy for that pod allowing `169.254.169.254/32`
  TCP 80 **and** `169.254.169.252/32` TCP 988 — never widen the exception
  list. Why both (GKE behaviour, not verified by Evenfire; **verify** on your
  cluster): with Workload Identity the node DNATs `169.254.169.254:80` to the
  host-network `gke-metadata-server` on `169.254.169.252:988`, so under
  post-DNAT evaluation a `/32:80` rule alone may not match. It cannot be an
  `egressBindings` entry on an `McpServer`: HCC rejects link-local CIDRs there.
- **Google APIs** (Artifact Registry, Vertex) are public ranges on 443 and
  pass the existing public-egress rules where a pod has one.
- **Image pulls** are done by the kubelet, outside pod NetworkPolicy.
- **Cloud Logging/Monitoring agents** run in `kube-system`, unaffected.

## Operating with enforcement on

- Adding a public hostname, a new sidecar, a monitoring scraper (`monitoring`
  namespace selectors exist in several policies) or a new DB consumer always
  means a policy change; the symptom of a missing one is a connect timeout,
  not a 403.
- HCC and WRC own their policies; do not hand-edit `clerum.io/managed-by`
  policies, HCC's periodic resync will revert them. Static base policies are
  reclaimed by the next server-side apply.
- `deploy/scripts/lint-networkpolicies.sh --overlay $OVERLAY_NAME` (no cluster)
  catches unsafe shapes before you apply.
