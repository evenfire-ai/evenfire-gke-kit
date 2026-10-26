# 02 — Assembly and overlay structure

## The assembly model

The overlay in [overlay-template/](overlay-template/) references `../../base`
and (optionally) `../../base/ingress`. Those directories, the CRD chart and
the generic deploy scripts are **not** in this folder: they come from the
public repo at the release tag you deploy. A deploy is always:

```
<workdir>/
  deploy/base/**, deploy/security/**     <- evenfire-ai/evenfire @ <RELEASE_TAG>
  deploy/scripts/**, scripts/**          <- evenfire-ai/evenfire @ <RELEASE_TAG>
  charts/clerum-crds/**                  <- evenfire-ai/evenfire @ <RELEASE_TAG>
  deploy/overlays/<OVERLAY_NAME>/**      <- YOUR copy of overlay-template/
```

Evenfire's own CI assembles two *different* commits — one for config
(`deploy/base`) and one for images — because it deploys continuously from
every merge. For a customer install, use **one release tag for both**: the manifests
at `vX.Y.Z` reference the images published as `vX.Y.Z`. Mixing a newer base
with older images (or vice versa) is unsupported.

```bash
export RELEASE_TAG=<RELEASE_TAG>        # e.g. v0.11.0 — agree it with Evenfire
export OVERLAY_NAME=<OVERLAY_NAME>      # e.g. gke-prod

git clone --branch "$RELEASE_TAG" --depth 1 https://github.com/evenfire-ai/evenfire.git evenfire
cd evenfire
mkdir -p deploy/overlays/"$OVERLAY_NAME"
cp -R /path/to/this-guide/overlay-template/. deploy/overlays/"$OVERLAY_NAME"/
chmod +x deploy/scripts/*.sh scripts/minikube/*.sh deploy/overlays/"$OVERLAY_NAME"/scripts/*.sh
```

Working directly inside the clone keeps every relative path (`../../base`,
`deploy/scripts/...`) correct. Keep your overlay in your own git repository
and copy it in at deploy time, or vendor the public tree — either way, never
edit `deploy/base` in place: your changes belong in the overlay.

## What comes from the open-source repo, and what is yours

Most of what runs on your cluster is defined **upstream**, in the public
repo, not in this guide. The overlay is a thin layer of environment values on
top. At `v0.11.0` the base alone renders **250 objects**; your overlay adds
**2** resources and patches the base (252 total; 261 with the Cloudflare
ingress slice, which adds 9 more upstream objects, two of which the overlay
also patches).

| Class | What | Where it lives | Who changes it |
|---|---|---|---|
| **Upstream (do not edit)** | every Deployment, Service, ServiceAccount, the 83 NetworkPolicies (the security model), RBAC (Roles/Bindings, ClusterRoles), ValidatingAdmissionPolicies, Namespaces + PodSecurity labels, PriorityClasses, PDB, canary Secrets, default ConfigMaps, the `PublicEgressExceptionSet`, the CRD chart, the deploy scripts | `deploy/base/**`, `deploy/security/**`, `charts/clerum-crds/**`, `deploy/scripts/**`, `scripts/**` at `<RELEASE_TAG>` | Evenfire, by release. You take changes by moving to a new tag. |
| **Overlay-owned objects** | `rpc-proxy/rpc-proxy-config` and `mcp-host/mcp-host-config` — **complete** ConfigMaps the base references but does not ship (deleting either file breaks rpc-proxy / agent pods); `instances/` (Host, Context, GlobalFileSystem, CommunicationChannel); optional `rbac-e2e-compat.yaml` | your overlay | you. Upstream's reference copies of the two ConfigMaps are `deploy/overlays/minikube/configmaps/` in the public repo: compare against them on every upgrade. |
| **Overlay patches** | changes that only work while the named base object exists (table below) | your overlay | you, re-checked on every upgrade |
| **Secrets and key material** | everything in [06](06-secrets-keys-rbac-crds.md) | the cluster only (scripts + your secret manager), never git | you |

What the overlay patches in the base:

| Patch group | Base objects touched | Purpose |
|---|---|---|
| strategic-merge ConfigMaps | `control-api-config`, `clerum-channel-reader-config`, `codex-llm-proxy-config`, `grok-llm-proxy-config` (+ `cloudflared-config` with the tunnel) | hostnames, registry mode, allowlists, feature gates |
| resources | 9 Deployments (`resource-limits.yaml`) + `nginx-workflow-approval-gateway` | indicative requests/limits |
| controller env | `host-context-controller` (5 patches), `control-api`, `workflow-recipes`, `external-rest-api` | images embedded in env vars, CIDRs, allowlists, pull-secret names, CORS/public URLs |
| NetworkPolicy, API server | `allow-k8s-api-egress-{control-plane,mcp-host,channels}` | your cluster's API-server addresses |
| NetworkPolicy, DNS | 9 `allow-dns-egress-*` / `sandbox-ui-static-dns-egress` (10 with the tunnel) | your kube-dns ClusterIP (NodeLocal DNSCache) |
| storage | `control-postgres-data`, `clerum-workflow-output` PVCs | your StorageClass |

Consequences:

- **You never fork the base.** A change you need in a base object goes in the
  overlay as a patch; a change that should apply to everyone (a bug, a missing
  knob) goes to Evenfire / the public repo as an issue or PR.
- **The security model is upstream.** You *add* policies or *narrow* them in
  the overlay; you do not delete or rewrite base NetworkPolicies ([04](04-network-policies-and-cni.md)).
- **Upgrades are a re-assembly**, not a merge: new tag + your unchanged
  overlay, then the checks in [Keeping the overlay honest](#keeping-the-overlay-honest-over-time).
- **Public docs apply too.** The clone ships `docs/` (e.g.
  `docs/deploy/production.md`, `docs/how-to/connect-to-registry.md`,
  `docs/how-to/connect-telegram.md`, `docs/how-to/member-invitations-self-hosted.md`,
  `docs/how-to/password-work-ownership-recovery.md`)
  for product-level topics. For anything GKE-specific — ordering, secrets,
  NetworkPolicy procedure, registry pull paths — **this guide governs** (for
  example, the generic production notes mention registry pull credentials;
  on GKE use the paths in [05](05-images-registry-and-pinning.md)).

## File-by-file

| File | What it does | Values you must set |
|---|---|---|
| `kustomization.yaml` | lists base + overlay resources, the `images:` pins, both patch lists, the `replacements:` block | `<REGISTRY_PATH>`, `<IMAGE_TAG>`; uncomment the three Cloudflare lines only if you use the tunnel |
| `configmaps/control-api-config.yaml` | strategic-merge over the base `control-api-config`: public origins, OAuth callback, desktop origins, invitation mode (`hosted`), plugin registry (`REGISTRY_CONNECTION_MODE=self-hosted`, `CLERUM_REGISTRY_URL`, also read by WRC), subscription gates/catalog sync, core pool sizing, image allowlist, deletes the OSS default DSN | `<BASE_DOMAIN>`, `<APP_NAME>`, `<ENV_NAME>`, `<CLUSTER_NAME>`, `<ZONE>`, `<REGISTRY_PATH>`; keep the two registry keys unless you run your own registry |
| `configmaps/rpc-proxy-config.yaml` | complete ConfigMap (not in base) for the streaming edge | `<BASE_DOMAIN>` (CORS + OAuth callback) |
| `configmaps/mcp-host-config.yaml` | complete ConfigMap (not in base) for agent pods; JWT key left empty on purpose | none (tune limits if you like) |
| `configmaps/channel-reader-config.yaml` | adds `CLERUM_PROFILE_UI_URL` to the base ConfigMap | `<BASE_DOMAIN>` |
| `configmaps/codex-llm-proxy-config.yaml`, `configmaps/grok-llm-proxy-config.yaml` | subscription proxy execution gates, `true` | none |
| `configmaps/cloudflared-config.yaml` | Cloudflare Tunnel routing table (only with `base/ingress`) | `<TUNNEL_UUID>`, `<BASE_DOMAIN>` |
| `patches/dynamic-images.yaml` | images embedded in env vars of control-api, HCC and WRC; plus HCC policy resync, workspace StorageClass, SDK/snippet/Grok flags, enforcement mode, webhook public URL | `<REGISTRY_PATH>`, `<IMAGE_TAG>`, `<STORAGE_CLASS_RWO>`, `<BASE_DOMAIN>` |
| `patches/external-rest-api-cors.yaml` | CORS origins + public base URLs of the REST API | `<BASE_DOMAIN>`, `<APP_NAME>` |
| `patches/hcc-allowed-image-prefixes.yaml` | HCC's plugin image allowlist | `<REGISTRY_PATH>` |
| `patches/hcc-k8s-api-cidrs.yaml` | API-server + kube-dns CIDRs HCC writes into generated policies | script-filled |
| `patches/hcc-pull-ref-overrides.yaml` | clears HCC's default pull-Secret names for spawned pods (public pulls / GKE node identity are the supported paths, [05](05-images-registry-and-pinning.md)) | none |
| `patches/k8s-api-ip.yaml`, `-mcp-host.yaml`, `-channels.yaml` | API-server egress ipBlocks for the three statically-policed namespaces | script-filled |
| `patches/nodelocal-dns-egress-rule.yaml` | kube-dns ClusterIP ipBlock appended to every DNS policy | script-filled |
| `patches/resource-limits.yaml`, `patches/nginx-workflow-approval-gateway.yaml` | requests/limits | tune to your node pool |
| `patches/gfs-upload-storage-floor.yaml` | GFS upload v2 enabled, 200 MiB product limit and chunk/session geometry | none |
| `patches/storage-class.yaml`, `patches/workflow-output-storageclass.yaml` | StorageClasses for the two base PVCs | `<STORAGE_CLASS_RWO>` |
| `rbac-e2e-compat.yaml` | optional RoleBinding for your deploy identity, disabled | `<DEPLOY_SA_EMAIL>` |
| `instances/*.yaml` | first `Host`, `Context`, `GlobalFileSystem`, optional `CommunicationChannel`; applied **separately** | `<LLM_PROVIDER>`, `<LLM_MODEL>`, `<GFS_SIZE>`, `<STORAGE_CLASS_RWO>` |
| `scripts/detect-k8s-api-ip.sh` | rewrites the five CIDR-bearing patches from the live cluster | run it |
| `scripts/rollout-gate.sh` | fail-closed rollout gate: every rendered + runtime Deployment must exist and roll out ([07](07-deploy-sequence-and-verification.md) B13) | run it after every apply |

## Kustomize rules that bite

- **Multi-document patch files go under `patchesStrategicMerge:`**, single-document
  ones under `patches:`. Listing a multi-doc file under `patches:` fails with
  `unable to parse SM or JSON patch` and can silently render nothing. The
  template already sorts them correctly; keep that split when you add files.
  (`patchesStrategicMerge` prints a deprecation warning on current kubectl;
  it still works.)
- **Env-var patches merge by `name`.** A strategic-merge patch that sets
  `value:` on an env var the base defines with `valueFrom:` produces an EnvVar
  carrying both, which the API server rejects mid-apply. Mirror the base shape
  exactly (copy the `env:` entry from the rendered base Deployment).
- **The `images:` block does not touch env-var values.** That is why
  `patches/dynamic-images.yaml` spells out full references and must be bumped
  together with `kustomization.yaml` ([05](05-images-registry-and-pinning.md)).
- **A JSON6902 target that matches nothing is silently skipped.** No error,
  no warning: forgetting to uncomment the `allow-dns-egress-ingress` target
  when you enable `base/ingress` renders fine and drops the DNS ipBlock from
  cloudflared's policy (so under enforcement + NodeLocal DNSCache cloudflared
  cannot resolve its upstreams). The gate below catches it. Keep the target
  and `base/ingress` toggled together. `replacements:` with zero matches is
  likewise a no-op (the base itself relies on that), so the cloudflared
  replacement is safe to leave in.
- **`instances/` is not a Kustomize resource.** CRD instances are applied with
  `kubectl --context "$CONTEXT" apply -f instances/` after the controllers are up; HCC reacts to
  them. Keeping them out of the render means a broken CRD or controller does
  not block the platform apply.

## Render and verify (no cluster needed)

```bash
cd evenfire
OV=deploy/overlays/$OVERLAY_NAME

grep -rn '<[A-Z_]*>' "$OV" --include='*.yaml'          # must print nothing (after detect script)
kubectl kustomize "$OV" > /tmp/rendered.yaml
grep -c '^kind:' /tmp/rendered.yaml                     # ~250 objects (~260 with base/ingress)

# the public tree's own linters, as used by Evenfire's CD
bash deploy/scripts/lint-networkpolicies.sh --rendered /tmp/rendered.yaml --no-standalone
bash deploy/scripts/lint-workload-hardening.sh --rendered /tmp/rendered.yaml \
  --exceptions deploy/security/workload-hardening-exceptions.yaml

# nothing should still point at the unrewritten base image names
grep -nE '(image|value): *clerum/' /tmp/rendered.yaml && echo "UNPINNED" || echo "all images rewritten"

# only with base/ingress: cloudflared's DNS policy must carry the kube-dns ipBlock
if grep -qE '^ *- \.\./\.\./base/ingress' "$OV/kustomization.yaml"; then
  CIDR=$(grep -o 'cidr: [0-9.]*/32' "$OV/patches/nodelocal-dns-egress-rule.yaml" | head -1)
  [ -n "$CIDR" ] && grep -A40 'name: allow-dns-egress-ingress' /tmp/rendered.yaml | grep -q "$CIDR" \
    && echo "ingress DNS ok" || echo "MISSING: uncomment the allow-dns-egress-ingress target"
fi
```

What Evenfire verified with this template: with the public tree at the
release tag the template was written against, and every placeholder replaced
by test values (`ghcr.io/evenfire-ai`, that tag, `example.com`, TEST-NET
addresses, `standard-rwo`), both variants (with and without `base/ingress`)
render — 252 and 261 objects — and both linters pass (83 / 86 NetworkPolicies,
18 / 19 workloads). No live cluster was involved in that check; the apply
path is validated by the sequence in [07](07-deploy-sequence-and-verification.md).

## Keeping the overlay honest over time

- Every public release may add env vars, ConfigMap keys or NetworkPolicies to
  the base. Re-render with the new tag and diff the render against the previous
  one before bumping `<IMAGE_TAG>`; new keys that are environment-specific
  (anything with a hostname, registry or CIDR) belong in your overlay.
- **Patch targets fail silently.** A JSON6902 target that matches nothing is a
  no-op, not an error. After re-rendering at a new tag, compare the DNS
  policies the base ships with the targets your `kustomization.yaml` lists:

  ```bash
  # DNS policies in the render (name of every NetworkPolicy whose name contains dns-egress)
  awk '/^---/{k="";n=""} /^kind: /{k=$2} /^  name: /{if(!n)n=$2} k=="NetworkPolicy"&&n~/dns-egress/{print n;k=""}' \
    /tmp/rendered.yaml | sort -u > /tmp/dns-render.txt
  # DNS targets your kustomization.yaml patches (commented-out lines ignored)
  grep -v '^ *#' deploy/overlays/$OVERLAY_NAME/kustomization.yaml \
    | sed -n 's/^ *name: \(.*dns-egress.*\)/\1/p' | sort -u > /tmp/dns-targets.txt
  diff /tmp/dns-render.txt /tmp/dns-targets.txt && echo "DNS targets match"
  ```

  Any line on the left only is a new base DNS policy without your kube-dns
  ipBlock: add a target. A line on the right only is a renamed/removed
  policy: fix or drop the target.
- **Overlay-owned ConfigMaps do not pick up new upstream keys.** Compare the
  key sets of yours with the public reference copies on every upgrade:

  ```bash
  for f in mcp-host-config rpc-proxy-config; do
    diff <(sed -n 's/^  \([A-Za-z0-9_.-]*\):.*/\1/p' deploy/overlays/minikube/configmaps/$f.yaml | sort -u) \
         <(sed -n 's/^  \([A-Za-z0-9_.-]*\):.*/\1/p' deploy/overlays/$OVERLAY_NAME/configmaps/$f.yaml | sort -u)
  done
  ```

  Treat the output as a review list, not a to-do list. Keys missing from yours
  fall back to code defaults (the template already omits several on purpose,
  e.g. tracing and progress-interval tuning). The minikube copies also carry
  **dev-only secret placeholders** (desktop token, cookie secrets): never copy
  those into a ConfigMap; real values live in Secrets ([06](06-secrets-keys-rbac-crds.md)).
  Port a key only when the release notes or the service's config say it needs
  a value for your environment.

- **New base Deployments** are picked up by the rollout gate automatically
  (it reads the render), but not by `resource-limits.yaml`; give them requests
  and limits if your policy requires it.
- Treat `kubectl kustomize` output as the only source of truth for "what is
  deployed"; never `kubectl edit` live objects. The apply uses server-side
  apply with `--force-conflicts --field-manager=clerum-kustomize`, which
  reclaims hand-edited fields on the next deploy ([07](07-deploy-sequence-and-verification.md)).
