# Overlay template (GKE)

The Kustomize overlay for your GKE environment. Every environment-specific
value is a `<PLACEHOLDER>` marked `# CHANGE ME`. Copy it into an assembled public tree as
`deploy/overlays/<OVERLAY_NAME>/` (see [../02-assembly-and-overlay-structure.md](../02-assembly-and-overlay-structure.md)).

```
overlay-template/
├── kustomization.yaml             image pins, patch list, replacements
├── configmaps/
│   ├── control-api-config.yaml    public origins, OAuth callback, invitation mode, plugin registry (self-hosted), image allowlist
│   ├── rpc-proxy-config.yaml      streaming edge: CORS, OAuth callback, stream budgets
│   ├── mcp-host-config.yaml       agent runtime defaults; JWT key left EMPTY (synced after apply)
│   ├── channel-reader-config.yaml profile-ui URL handed to unverified chat senders
│   ├── codex-llm-proxy-config.yaml Codex subscription proxy gate (true)
│   ├── grok-llm-proxy-config.yaml  Grok subscription proxy gate (true)
│   └── cloudflared-config.yaml    ONLY with ../../base/ingress (Cloudflare Tunnel routing table)
├── patches/
│   ├── dynamic-images.yaml        runtime images, HCC policy resync, WRC feature gates
│   ├── external-rest-api-public-urls.yaml  what the Desktop App is told (API + RPC URLs), CORS
│   ├── hcc-allowed-image-prefixes.yaml  plugin image allowlist (your registry first)
│   ├── hcc-k8s-api-cidrs.yaml     API-server + kube-dns CIDRs HCC puts in generated policies
│   ├── hcc-pull-ref-overrides.yaml image pull Secret names for spawned pods (empty on GKE+AR)
│   ├── hcc-workspace-layout-merge.yaml  Host PVC layout merge switch ("true"; turn off per ../07)
│   ├── k8s-api-ip.yaml            API-server egress: control-plane
│   ├── k8s-api-ip-mcp-host.yaml   API-server egress: mcp-host
│   ├── k8s-api-ip-channels.yaml   API-server egress: channels
│   ├── nodelocal-dns-egress-rule.yaml  kube-dns ClusterIP allow, appended to every DNS policy
│   ├── nginx-workflow-approval-gateway.yaml  resources
│   ├── resource-limits.yaml       resources for the static Deployments
│   ├── gfs-upload-storage-floor.yaml  GFS upload v2 enabled, 200 MiB product limit
│   ├── storage-class.yaml         Postgres PVC StorageClass
│   └── workflow-output-storageclass.yaml  legacy shared workflow-output PVC
├── instances/                     CRD instances, applied separately after the overlay
│   ├── host.yaml                  first agent Host (LLM provider/model)
│   ├── context.yaml               default Context (MCP server allowlist)
│   ├── globalfilesystem.yaml      GFS volume (size, StorageClass)
│   └── communicationchannel.yaml  OPTIONAL chat channel binding
├── rbac-e2e-compat.yaml           OPTIONAL RoleBinding for your deploy SA (disabled)
└── scripts/
    ├── detect-k8s-api-ip.sh       rewrites the CIDR patches from the live cluster
    └── rollout-gate.sh            fail-closed rollout gate run after every apply (07, B13)
```

## Fill-in order

1. Decide `<REGISTRY_PATH>` and `<IMAGE_TAG>` ([../05-images-registry-and-pinning.md](../05-images-registry-and-pinning.md)).
   Replace in `kustomization.yaml`, `patches/dynamic-images.yaml`,
   `patches/hcc-allowed-image-prefixes.yaml`, `configmaps/control-api-config.yaml`.
2. Decide hostnames ([../03-ingress-and-hostnames.md](../03-ingress-and-hostnames.md)).
   Replace `<BASE_DOMAIN>` and `<APP_NAME>` in `configmaps/*.yaml`,
   `patches/external-rest-api-public-urls.yaml`, `patches/dynamic-images.yaml`.
   Keep every hostname key and keep both URL files: a key or file you delete
   leaves the base's loopback default in place, and the Desktop App is then
   handed `127.0.0.1` ([../03-ingress-and-hostnames.md › The Desktop App](../03-ingress-and-hostnames.md#the-desktop-app)).
3. Decide StorageClasses: `<STORAGE_CLASS_RWO>` in `patches/storage-class.yaml`,
   `patches/workflow-output-storageclass.yaml`, `patches/dynamic-images.yaml`,
   `instances/globalfilesystem.yaml` (plus `<GFS_SIZE>`).
4. Fill `<ENV_NAME>`, `<CLUSTER_NAME>`, `<ZONE>` in `configmaps/control-api-config.yaml`.
5. Run `CONTEXT=<ctx> OVERLAY_DIR=deploy/overlays/<OVERLAY_NAME> scripts/detect-k8s-api-ip.sh`
   against YOUR cluster. It fills `<K8S_API_CLUSTER_IP>`, `<K8S_API_ENDPOINT_IP>`
   and `<KUBE_DNS_CLUSTER_IP>`.
6. Fill `instances/host.yaml` (`<LLM_PROVIDER>`, `<LLM_MODEL>`); edit or delete
   `instances/communicationchannel.yaml` (its bot token lives in a Secret
   named by `credentialsSecretRef`, see
   [../06-secrets-keys-rbac-crds.md](../06-secrets-keys-rbac-crds.md#channel-credentials)).
7. Only if you use Cloudflare: uncomment `../../base/ingress`,
   `configmaps/cloudflared-config.yaml` and the `allow-dns-egress-ingress`
   patch target in `kustomization.yaml`; fill `<TUNNEL_UUID>`.

Gate before any apply: render, then run the **value gate** in
[../02-assembly-and-overlay-structure.md](../02-assembly-and-overlay-structure.md#render-and-verify-no-cluster-needed).
It must print `values ok`: no placeholder left, no `127.0.0.1` / `localhost`
(a base default that survived), and every hostname key present.

An unreplaced CIDR placeholder is not caught by the platform's own
`verify-networkpolicies.sh` (it forbids a different stale address); HCC does
crash on it, which is the fail-loud you want, but do not rely on that.

The template enables the [feature profile](../10-feature-defaults.md):
Codex/Grok subscriptions, six-hour catalog refresh, GFS upload v2, automatic
tool presentation and periodic HCC NetworkPolicy reconciliation. The core
database pool is 24 connections with a 3000 ms acquire timeout. Host tasks
can run for 24 hours and retain the 100-tool-call limit. Subscription accounts
still need to be connected and assigned; GFS still needs Phase B provisioning.

## What was verified

With the public tree assembled at tag `v0.12.0` and every placeholder
substituted with test values (`<REGISTRY_PATH>=ghcr.io/evenfire-ai`,
`<IMAGE_TAG>=v0.12.0`, `<BASE_DOMAIN>=example.com`, TEST-NET addresses for
the CIDRs, `standard-rwo` for the StorageClass), `kubectl kustomize` rendered
the overlay in both variants (252 objects without `../../base/ingress`, 261
with), the public tree's `lint-networkpolicies.sh` and
`lint-workload-hardening.sh` passed on both renders, no `clerum/<image>`
reference survived unrewritten, and the value gate printed `values ok` (it
reports the loopback lines when `patches/external-rest-api-public-urls.yaml`
or the `CONTROL_API_DESKTOP_*` keys are removed). The detect script and `rollout-gate.sh`
were exercised against a stubbed `kubectl` (the gate: healthy -> exit 0;
a gating rollout failure, a missing expected Deployment, or a failed
namespace listing -> exit 1; a non-gating failure alone -> 0).
**No cluster was involved**; the apply path is the
sequence in [../07-deploy-sequence-and-verification.md](../07-deploy-sequence-and-verification.md).
See [../02-assembly-and-overlay-structure.md](../02-assembly-and-overlay-structure.md)
for the exact commands so you can repeat the check on your copy.

The enabled feature profile was checked in both renders: ConfigMap gates
reach the intended containers through `envFrom`, controller flags reach the
named HCC/WRC containers, Control API keeps one replica for the pool budget,
and the Host tool-call ceiling stays at 100. Negative checks rejected partial
Grok activation, a shadowing ENV override and a 1000-call budget. The B11 Bash
sequence was exercised with a stubbed `kubectl`: both proxies must pass their
readiness waits before Control API restarts; either failed wait or a missing
context stops the sequence. These are offline checks, not an LLM or file
transfer test.
