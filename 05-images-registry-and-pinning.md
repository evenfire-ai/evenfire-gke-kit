# 05 — Images, registry and pinning

## Image inventory

All images are built for `linux/amd64` (and `arm64` for the public release
builds) and published as `ghcr.io/evenfire-ai/<name>:<tag>`.

| Image | Referenced by | Pinned in |
|---|---|---|
| `control-api`, `control-ui`, `external-rest-api`, `profile-ui`, `rpc-proxy`, `mcp-proxy`, `workflow-recipes`, `workflow-snippet-runner`, `workspace-files-controller`, `webhook-proxy`, `channel-reader`, `workflow-approval-request-reader`, `host-context-controller`, `codex-llm-proxy`, `grok-llm-proxy` | static Deployments in base (`trace-maintenance-worker` reuses `control-api`) | `kustomization.yaml` `images:` |
| `mcp-host-slim` (base says `clerum/mcp-host`; GKE runs the slim variant) | static reference + HCC/WRC env | both |
| `mcp-host-desktop`, `gfs-controller`, `stdio-bridge`, `workflow-coordinator`, `webhook-gateway`, `nginx-egress-proxy` | **only** env vars on HCC / WRC / control-api (`nginx-egress-proxy`: `CONTEXT_MAPPER_EGRESS_PROXY_IMAGE`, `CONTROL_API_REMOTE_MCP_EGRESS_PROXY_IMAGE`) | `patches/dynamic-images.yaml` (the template's `images:` entry for `nginx-egress-proxy` matches nothing; harmless) |
| `nginx:1.30.1-alpine`, `postgres:16-alpine` | base gateways, Postgres | base (third-party, Docker Hub) |
| `busybox:1.36` | WFC init container HCC spawns: **env only** (`CONTEXT_MAPPER_WFC_INIT_IMAGE`, also HCC's built-in default) | base (third-party, Docker Hub) |
| `cloudflare/cloudflared@sha256:...` | `base/ingress` | base (digest-pinned) |
| `airtable-mcp-server`, `playwright-server`, `web-search-mcp`, `mock-*`, `clerum-workflow-base`, `mcp-host`, `mcp-host-full` | not deployed by the overlay (optional MCP servers, build bases, test fixtures) | — |

Your cluster must be able to pull from Docker Hub as well as from
`<REGISTRY_PATH>`, or you re-point the three third-party images: `nginx` and
`postgres` with extra `images:` entries, `busybox` by setting
`CONTEXT_MAPPER_WFC_INIT_IMAGE` on HCC in `patches/dynamic-images.yaml`
(`images:` does not rewrite env values).

## Where to pull from

**Option 1 — public registry, release tag (simplest).**
`<REGISTRY_PATH>=ghcr.io/evenfire-ai`, `<IMAGE_TAG>=vX.Y.Z`. The public CI has
a guard asserting published images are anonymously pullable, but **verify**
before relying on it (`docker pull ghcr.io/evenfire-ai/control-api:<IMAGE_TAG>`
from a machine with no GitHub login) and ask Evenfire if it fails. No pull
Secret is needed; `patches/hcc-pull-ref-overrides.yaml` stays empty.

**Option 2 — mirror into Artifact Registry (what Evenfire does).** Digest-identical
copies, pulled with the node identity, immune to upstream outages or
visibility changes:

```bash
SRC=ghcr.io/evenfire-ai; DST=<REGISTRY_PATH>; TAG=<IMAGE_TAG>
for img in channel-reader workflow-approval-request-reader control-api control-ui external-rest-api \
  host-context-controller mcp-host-slim mcp-host-desktop mcp-proxy gfs-controller nginx-egress-proxy \
  profile-ui rpc-proxy workflow-recipes workflow-coordinator workflow-snippet-runner stdio-bridge \
  workspace-files-controller webhook-gateway webhook-proxy codex-llm-proxy grok-llm-proxy; do
  crane cp "$SRC/$img:$TAG" "$DST/$img:$TAG"      # or: gcrane / docker pull+tag+push
done
```

Then `<REGISTRY_PATH>` is your AR path; the node service account needs
`roles/artifactregistry.reader` ([00](00-prerequisites.md)). Mirror the three
Docker Hub images too if you want zero external pulls, and re-point them as
described under the inventory (two `images:` entries + the busybox env var).

**Option 3 — build yourself.** The public repo's `Makefile` and
`scripts/release/images-manifest.mjs` describe build contexts; several
services build from the repo root with `-f <service>/Dockerfile`. Only do this
if you must patch sources.

## Tags and the two-coordinate model

Evenfire's own pipeline tracks **two independent coordinates**:

- `base_sha` — the public commit that supplies `deploy/base` (config);
- `image_sha` — the `sha-<short7>` tag of mirrored images (code).

A config-only change reuses the running images; an image-only change reuses
the running base. That split suits continuous deployment from every merge,
but it needs extra guards (tag-shape and render-parity checks, and an
attestation before promotion). With one release tag you need none of them.

For a customer install the two coordinates collapse to **one release tag**:
`<RELEASE_TAG>` for the tree and `<IMAGE_TAG>` for the images, equal. The
guards that assume `sha-*` tags (the tag-shape and render-parity checks in
Evenfire's CD) are not something a release-tag install needs; the
equivalent check for you is the grep in [02](02-assembly-and-overlay-structure.md)
(`(image|value): *clerum/` must not appear in the render) — it proves every
reference was rewritten to your registry and tag.

## Bumping a release

1. Read the release notes; note CRD changes (CRDs are applied out-of-band,
   [06](06-secrets-keys-rbac-crds.md)) and new overlay-relevant env vars.
2. `git fetch --tags && git checkout <NEW_TAG>` (or re-assemble).
3. Replace the tag **everywhere at once**:
   ```bash
   OV=deploy/overlays/$OVERLAY_NAME
   sed -i.bak "s/<OLD_TAG>/<NEW_TAG>/g" "$OV/kustomization.yaml" "$OV/patches/dynamic-images.yaml"
   rm -f "$OV"/*.bak "$OV"/patches/*.bak
   grep -rn '<OLD_TAG>' "$OV" && echo "STALE PINS" || echo ok
   ```
   The static `images:` entries and the env-embedded references in
   `dynamic-images.yaml` must move together: if `dynamic-images.yaml` lags, the
   static Deployments run the new release while every pod HCC/WRC spawns stays
   on the old one — exactly the drift Evenfire's own tag-bump tooling exists
   to prevent by editing both files together. The images that appear in the
   template's `dynamic-images.yaml` as env values are `channel-reader
   mcp-host-slim mcp-host-desktop gfs-controller nginx-egress-proxy
   stdio-bridge workflow-recipes workflow-coordinator workflow-snippet-runner
   webhook-gateway workspace-files-controller`.
4. Render, diff, apply per [07](07-deploy-sequence-and-verification.md).
5. Commit the overlay change in your repo so the overlay always records what
   the cluster runs. A cluster ahead of its overlay gets rolled *back* by the
   next apply — the same rule Evenfire's CD enforces by committing the
   deployed tags back to the overlay repo after every apply.

## Allowlists that mention the registry

| Setting | File | Purpose |
|---|---|---|
| `CONTROL_API_ALLOWED_IMAGE_PREFIXES` | configmaps/control-api-config.yaml | which image hosts a plugin/recipe may reference (audit mode until `CONTROL_API_ENFORCE_IMAGE_ALLOWLIST=true`) |
| `CONTEXT_MAPPER_ALLOWED_IMAGE_PREFIXES` | patches/hcc-allowed-image-prefixes.yaml | same list for HCC-spawned workloads (`CONTEXT_MAPPER_ENFORCE_IMAGE_ALLOWLIST` in base) |
| `WRC_ALLOWED_COORDINATOR_IMAGE_PREFIXES` + `WRC_REQUIRE_COORDINATOR_IMAGE_DIGEST` | patches/dynamic-images.yaml | custom workflow coordinators must come from your registry **and** be digest-pinned |

Put `<REGISTRY_PATH>/` first in all three; keep `mongodb/`, `mcr.microsoft.com/`
and `clerum/` if you intend to run the sample MongoDB/Playwright MCP recipes.

Plugins installed from the Marketplace are served from `registry.evenfire.ai/<org>/<name>`.
The template lists `registry.evenfire.ai/` in the first two (plugin) lists; it
matters only once you set `CONTROL_API_ENFORCE_IMAGE_ALLOWLIST` /
`CONTEXT_MAPPER_ENFORCE_IMAGE_ALLOWLIST` to `true`, so do not drop it then.
Add it to `WRC_ALLOWED_COORDINATOR_IMAGE_PREFIXES` only if a registry recipe
ships a custom coordinator image (that list is always enforced, digest-pinned).

## Pull credentials — supported paths

Two pull paths are supported in v0.11.0, and both need **no pull Secret**:

| Path | Why it works |
|---|---|
| anonymous pulls from the public registry (Option 1) | nothing to authenticate |
| Artifact Registry in your project (Option 2) | the kubelet pulls with the **node** service account (`roles/artifactregistry.reader`), which covers every pod on the node — static Deployments and everything HCC/WRC spawn |

`patches/hcc-pull-ref-overrides.yaml` clears the two pull-Secret names HCC
would otherwise inject into Host and SharedFileSystem pods (its built-in
defaults reference a Secret that does not exist on your cluster); keep it.

**A registry that needs credentials is unsupported / unverified for the
platform images.** The reason is wiring, not policy: pull-Secret names are
only threaded through for some of the pods the controllers create (HCC's
Host, SharedFileSystem and GFS pods via `CONTEXT_MAPPER_*_IMAGE_PULL_SECRET`
env vars), while the per-Host `channel-reader` HCC creates and the
coordinator / snippet-runner / webhook-gateway pods WRC creates carry no
platform-level `imagePullSecrets` and run under ServiceAccounts the base
ships without any. Creating a pull Secret in every namespace therefore still
leaves those pods in `ImagePullBackOff`. If you must front an authenticated
registry, mirror into Artifact Registry instead (Option 2). Whatever you run,
verify after the first full deploy that every image came from where you
expect and nothing is stuck pulling:

```bash
# every row: IMAGE under your <REGISTRY_PATH> (or the three Docker Hub images), WAITING = <none>
kubectl --context "$CONTEXT" get pods -A \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,IMAGE:.spec.containers[*].image,WAITING:.status.containerStatuses[*].state.waiting.reason' \
  | grep -vE '^(kube-system|gke-)'
kubectl --context "$CONTEXT" get pods -A | grep -E 'ImagePullBackOff|ErrImagePull' || echo "no pull failures"
```
