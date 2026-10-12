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
│   ├── codex-llm-proxy-config.yaml subscription proxy gate (false)
│   └── cloudflared-config.yaml    ONLY with ../../base/ingress (Cloudflare Tunnel routing table)
├── patches/
│   ├── dynamic-images.yaml        images embedded in env vars (controller-spawned pods)
│   ├── external-rest-api-cors.yaml public REST API CORS + public base URLs
│   ├── hcc-allowed-image-prefixes.yaml  plugin image allowlist (your registry first)
│   ├── hcc-k8s-api-cidrs.yaml     API-server + kube-dns CIDRs HCC puts in generated policies
│   ├── hcc-pull-ref-overrides.yaml image pull Secret names for spawned pods (empty on GKE+AR)
│   ├── k8s-api-ip.yaml            API-server egress: control-plane
│   ├── k8s-api-ip-mcp-host.yaml   API-server egress: mcp-host
│   ├── k8s-api-ip-channels.yaml   API-server egress: channels
│   ├── nodelocal-dns-egress-rule.yaml  kube-dns ClusterIP allow, appended to every DNS policy
│   ├── nginx-workflow-approval-gateway.yaml  resources
│   ├── resource-limits.yaml       resources for the static Deployments
│   ├── gfs-upload-storage-floor.yaml  GFS upload geometry (v2 disabled)
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
   `patches/external-rest-api-cors.yaml`, `patches/dynamic-images.yaml`.
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

Gate before any apply (must print nothing):

```bash
grep -rn '<[A-Z_]*>' deploy/overlays/<OVERLAY_NAME> --include='*.yaml'
```

An unreplaced CIDR placeholder is not caught by the platform's own
`verify-networkpolicies.sh` (it forbids a different stale address); HCC does
crash on it, which is the fail-loud you want, but do not rely on that.

## What was verified

With the public tree assembled at tag `v0.11.0` and every placeholder
substituted with test values (`<REGISTRY_PATH>=ghcr.io/evenfire-ai`,
`<IMAGE_TAG>=v0.11.0`, `<BASE_DOMAIN>=example.com`, TEST-NET addresses for
the CIDRs, `standard-rwo` for the StorageClass), `kubectl kustomize` rendered
the overlay in both variants (252 objects without `../../base/ingress`, 261
with), the public tree's `lint-networkpolicies.sh` and
`lint-workload-hardening.sh` passed on both renders, and no `clerum/<image>`
reference survived unrewritten. The detect script and `rollout-gate.sh`
were exercised against a stubbed `kubectl` (the gate: healthy -> exit 0;
a gating rollout failure, a missing expected Deployment, or a failed
namespace listing -> exit 1; a non-gating failure alone -> 0).
**No cluster was involved**; the apply path is the
sequence in [../07-deploy-sequence-and-verification.md](../07-deploy-sequence-and-verification.md).
See [../02-assembly-and-overlay-structure.md](../02-assembly-and-overlay-structure.md)
for the exact commands so you can repeat the check on your copy.
