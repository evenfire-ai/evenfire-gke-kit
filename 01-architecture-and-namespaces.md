# 01 — Architecture and namespaces

Everything below is read from `deploy/base` in the public repo at the release
tag; nothing is specific to Evenfire's environment.

## Namespaces

`deploy/base/namespaces.yaml` creates all of these except `ingress`, which
comes with `deploy/base/ingress` (the Cloudflare slice). PodSecurity admission
labels are set in the manifests; you do not configure them.

| Namespace | PSA | Static workloads (from base) | Runtime workloads (spawned) | Role |
|---|---|---|---|---|
| `control-plane` | — | `control-api` (+ `control-api-rpc-gateway` nginx, `nginx-workflow-approval-gateway`), `control-ui`, `control-postgres`, `host-context-controller` (+ `host-context-controller-api-gateway` nginx), `workflow-recipes`, `trace-maintenance-worker`, `codex-llm-proxy`, `grok-llm-proxy` | DB migration Job | control plane, admin UI, Postgres, the two operators |
| `mcp-host` | — | ConfigMaps only (`mcp-host-config`, `clerum-model-secret-mapping`) | per-Host agent pods (`mcp-host-slim` / `mcp-host-desktop`), per-SharedFileSystem `workspace-files-controller` | first-party agents |
| `mcp-server` | baseline | `mcp-proxy` | HCC-managed MCP server Deployments, `stdio-bridge` sidecars, egress proxies | tool servers reachable by agents |
| `channels` | — | `workflow-approval-request-reader` | per-Host `channel-reader-<host>` | chat provider adapters (Telegram, Slack, email) |
| `profiles` | — | `external-rest-api`, `profile-ui`, `profile-control-funnel` (nginx) | — | end-user API and profile/invitation UI |
| `rpc-proxy` | — | `rpc-proxy` (2 replicas) | — | Desktop App / Control UI streaming edge (SSE) |
| `sandbox-recipes` | baseline | PVC `clerum-workflow-output` (ConfigMap `clerum-wrc-public-key` is created by `gen-jwt-keys.sh`, not base) | per-recipe coordinators, workflow mcp-hosts, snippet runners, webhook gateways, artifact readers | WorkflowRecipe execution |
| `sandbox-ui` | baseline | — | recipe-supplied UI workloads | iframe-embedded recipe UIs |
| `webhook-ingress` | baseline | `webhook-proxy` (2 replicas) | — | inbound provider webhooks |
| `gfs` | baseline | ConfigMap `gfs-config`, Secrets `gfs-controller-db` / `gfs-controller-reader-db` | `gfsc-writer`, `gfsc-reader` (from the `GlobalFileSystem` instance) | Global File System |
| `llm-hooks` | baseline | — | guardrail hook pods (sealed: no egress at all) | LLM request/response hooks |
| `ingress` | restricted | `cloudflared` (2 replicas) — only with `base/ingress` | — | Cloudflare Tunnel egress-only edge |
| `monitoring` | — | not shipped; referenced by scrape policies | — | your Prometheus, if any |

Rollout gating (the semantics Evenfire's CD applies, packaged for you as
[overlay-template/scripts/rollout-gate.sh](overlay-template/scripts/rollout-gate.sh)):
every Deployment the overlay renders (that includes `mcp-server/mcp-proxy`,
`webhook-ingress/webhook-proxy` and, when enabled, `ingress/cloudflared`),
the runtime Deployments created from your instances (`gfs/gfsc-*`, the
per-Host agent and `channel-reader-<host>`), and anything else live in
`channels control-plane gfs mcp-host profiles rpc-proxy webhook-ingress
ingress` are **gating** — a failed or missing one fails the deploy.
Deployments that the render does not own in `mcp-server` (third-party MCP
servers) and `sandbox-recipes` (WRC per-recipe workloads) are **non-gating**:
reported, never blocking.

## The two controllers

**host-context-controller (HCC)** reconciles `Host`, `Context`, `McpServer`,
`CommunicationChannel`, `GlobalFileSystem`, `SharedFileSystem` and `LlmHook`.
For each Host it creates the agent Deployment, its workspace PVC, a
channel-reader Deployment and the per-Host NetworkPolicies
(`mcp-host-<host>-ingress-rpc-proxy`, `rpc-proxy-<host>-egress-mcp-host`,
per-Context `ctx-<context>-<server>` lanes). It also reconciles the
*infrastructure* policies (`deny-all-<ns>`, `allow-dns-egress-<ns>`,
`allow-hcc-api-egress-<ns>`, label-gated `allow-k8s-api-egress-<ns>`) in its
**runtime namespaces**: `mcp-server, sandbox-recipes, rpc-proxy, sandbox-ui`
(`CONTEXT_MAPPER_RUNTIME_NAMESPACES`; `sandbox-ui` gets only the minimal
deny-all + DNS set). Base ships the deny-all, DNS and HCC-API policies there
statically too; only `allow-k8s-api-egress-<ns>` in those namespaces comes
from HCC alone. It runs
`replicas: 1` with `strategy: Recreate` because it must be the single
NetworkPolicy writer.

**Stateless Hosts scale to zero.** A Host with `spec.lifecycle.stateless: true`
(default `false`; the template's Host does not set it) keeps its session state
in SQLite on the workspace PVC, and HCC drives `status.lifecycle.state`
`active -> draining -> suspended` from the agent's heartbeats: no active work
and no activity for `max(CONTEXT_MAPPER_STATELESS_IDLE_MINUTES,
CONTEXT_MAPPER_STATELESS_IDLE_FLOOR_MINUTES)` (base: 30 / 15 min), or the pod
older than 72 h (code default), starts a drain; once drained (or the 60 s drain
grace expires after the agent acknowledged it or stopped heartbeating) HCC sets
the agent Deployment to
`replicas: 0`. The Deployment, PVC and NetworkPolicies stay; the next request
for the Host wakes it (rpc-proxy holds the request, up to 48 s by default,
while HCC scales the Deployment back to 1). HCC rejects the flag
(`StatelessEnableRejected` condition, Host kept `active`) on a Host with a
`CommunicationChannel`, a desktop, or an unsatisfiable SharedFileSystem
co-location.

**workflow-recipes (WRC)** reconciles `WorkflowRecipe` / `WorkflowRecipePolicy`:
per-recipe coordinator, workflow mcp-host, snippet runner, webhook gateway and
the per-recipe NetworkPolicies in `sandbox-recipes`. It depends on HCC
(`ExternalEgressReady` on child `McpServer`s), so **HCC rolls out before WRC**.

Both read the images they spawn from env vars
([patches/dynamic-images.yaml](overlay-template/patches/dynamic-images.yaml)).

## Data

| Store | Where | Backed by | Backup you own |
|---|---|---|---|
| Control-plane Postgres (`profiles` DB) | `control-plane/control-postgres` (`postgres:16-alpine`, `Recreate`) | PVC `control-postgres-data` | yes: pg_dump or PD snapshots |
| GFS content | `gfs/gfsc-writer` | PVC created by HCC | yes |
| Agent sessions/memory | each Host pod | per-Host workspace PVC (SQLite) | optional |
| Workflow artifacts | WRC per-recipe PVCs | RWO PVCs | optional |

Schema migrations run as a Kubernetes Job built from the rendered control-api
Deployment (`deploy/scripts/run-control-api-db-migration.sh`) **before** the
overlay apply; the migrations also create least-privilege DB roles whose
credentials a second script materialises ([06](06-secrets-keys-rbac-crds.md)).

## Auth chain (why several keys exist)

```
Desktop App ──session JWT──▶ external-rest-api ──▶ control-api  POST /external/rpc/token
                                                     ◀── RPC JWT {iss: control-api, aud: rpc-proxy, 300 s}
Desktop App ──RPC JWT──▶ rpc-proxy (verifies with RPC_PROXY_JWT_PUBLIC_KEY)
                           └─▶ mcp-host :8080  with edge headers, NO Authorization header
Control UI  ──admin JWT──▶ control-api
mcp-host    ──runtime auth──▶ nginx-workflow-approval-gateway :8092 ──▶ control-api (approvals, usage, tracing)
WRC/HCC     ──InternalControl HMAC JWT──▶ control-api :8090
services    ──service tokens (CONTROL_API_INTERNAL_SERVICE_TOKENS)──▶ control-api
```

One RSA key pair (the "RPC" pair) is shared by rpc-proxy, every mcp-host
(`mcp-host-config.CLERUM_AUTH_JWT_PUBLIC_KEY`) and gfsc (`gfs-config.jwt-public-key`);
the public half is **copied into those ConfigMaps after every apply** by the
auth-key sync, because the apply resets them to the committed empty value.
Details in [06](06-secrets-keys-rbac-crds.md).

## Public upstreams (what an edge must reach)

| Role | Service (namespace) | Port | Traffic shape | Base NetworkPolicy that admits the edge |
|---|---|---|---|---|
| `app.` | `control-ui` (control-plane) | 3000 | HTTP, long admin sessions | `control-ui-network` |
| `profile.` | `profile-ui` (profiles) | 3001 | HTTP | `allow-ingress-profiles` |
| `api.` | `external-rest-api` (profiles) | 8091 | HTTP + OAuth callbacks, JSON bodies up to 150 MB | `allow-ingress-profiles` |
| `rpc.` | `rpc-proxy` (rpc-proxy) | 8094 | **SSE / long-lived HTTP** (10-minute streams, 15 s keepalives), artifact downloads up to 250 MB | `rpc-proxy` |
| `webhook.` | `webhook-proxy` (webhook-ingress) | 8095 | provider POSTs with **HMAC-signed bodies** (must not be rewritten), bodies up to 10 MB | `allow-public-ingress-webhook-proxy` |

All five policies admit only pods labelled `app: cloudflared` in namespace
`ingress`. Any other edge needs additional policies ([03](03-ingress-and-hostnames.md)).

## CRDs (API group `clerum.io/v1alpha1`)

`Host`, `Context`, `McpServer`, `LlmHook`, `CommunicationChannel`,
`WorkflowRecipe`, `WorkflowRecipePolicy`, `SharedFileSystem`,
`GlobalFileSystem`. Installed from `charts/clerum-crds` **before** anything
else; the overlay's `instances/` directory holds your first `Host`, `Context`,
`GlobalFileSystem` and (optionally) `CommunicationChannel`, applied after the
controllers are up ([07](07-deploy-sequence-and-verification.md)).
