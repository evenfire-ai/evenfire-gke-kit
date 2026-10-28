# 03 — Ingress and hostnames

> **Cloudflare Tunnel is Evenfire's choice, not a platform requirement.**
> The platform only needs five public HTTPS hostnames that reach five
> in-cluster Services (table below). *How* traffic gets there is yours to
> decide. Pick the row that fits your organisation:
>
> | If you already have... | Suggested path | Section |
> |---|---|---|
> | a Cloudflare account and want no public LoadBalancer / no inbound rule for the *application* | keep the tunnel (what we run) | [Option A](#option-a--keep-cloudflare-tunnel) |
> | GCP-native tooling and a managed certificate story | GKE Gateway / Google Cloud Load Balancer | [Option B](#option-b--a-gke-native-or-in-cluster-edge-no-cloudflare) |
> | an ingress controller (ingress-nginx, Istio, Envoy Gateway, ...) | run it, terminate TLS there | Option B |
> | corporate SSO in front of internal UIs (IAP, your IdP) | use it in place of Cloudflare Access | Option B, B.4 |
>
> Whatever you choose, three things are **not** optional: the hostnames must
> resolve publicly (invitation emails embed them), the NetworkPolicy lane for
> your edge must exist ([B.2](#b2-networkpolicies-you-must-add)), and the
> hostname-bearing config values must match the edge ([next sections](#every-value-that-embeds-a-hostname)).

## What Evenfire uses, and why

With the tunnel the **application edge has no public LoadBalancer, no public
IP and no inbound firewall rule of its own**. A `cloudflared` Deployment
(namespace `ingress`, 2 replicas, `deploy/base/ingress/cloudflared.yaml`)
dials *out* to the Cloudflare edge on UDP/TCP 7844; Cloudflare terminates TLS
for the five public hostnames and forwards each request down the tunnel to
the matching ClusterIP Service. This says nothing about the **nodes or the
Kubernetes API**: whether those have public addresses is decided by the
cluster-creation flags and the VPC firewall in [00](00-prerequisites.md),
not by the edge.

```
browser / app ──HTTPS──▶ Cloudflare edge ──tunnel (outbound 7844)──▶ cloudflared pod ──▶ Service:port
```

What that buys, and what each piece is in the manifests:

| Concern | Mechanism | Where |
|---|---|---|
| Inbound exposure (application) | none; the tunnel is established from inside (private nodes need Cloud NAT for it, [00](00-prerequisites.md)) | `allow-cloudflared-egress` NetworkPolicy allows only 7844 + 443 outbound to public ranges, plus the five upstreams |
| Routing | **locally managed** tunnel: hostname -> Service map is a ConfigMap in the cluster, not dashboard config | [configmaps/cloudflared-config.yaml](overlay-template/configmaps/cloudflared-config.yaml) |
| Tunnel identity | tunnel UUID + a credentials JSON mounted as a Secret; written with `kubectl patch` so applies never wipe it | `cloudflared-credentials` Secret (`kubectl patch --type=merge`, Option A step 4) |
| DNS | one proxied CNAME per hostname -> `<TUNNEL_UUID>.cfargotunnel.com` | `cloudflared tunnel route dns` |
| TLS | terminated at Cloudflare; plain HTTP inside the cluster | — |
| Operator SSO | a Cloudflare Access application on the `app.` hostname, allow-listed by identity-provider group membership | Cloudflare Zero Trust |
| Brute-force defence | a rate-limit rule on `api.<BASE_DOMAIN>/api/v1/auth/*` | Cloudflare ruleset (API-scripted) |
| WAF | managed ruleset on, **skipped** for `webhook.` so provider HMAC bodies are never rewritten | Cloudflare ruleset |
| Streaming | `rpc.` route sets `disableChunkedEncoding: false` and a 30 s connect timeout | cloudflared config |

Recommended: gate only the operator UI (`app.`). Keep `api.` and `rpc.` off
Access (the Desktop App calls them and cannot complete a browser SSO),
`profile.` (the public invitation surface) and `webhook.` (server-to-server).
Those rely on their own JWT/OAuth/HMAC auth. Access is defence in depth, never
a replacement for the application auth.

From v0.12.0, remote MCP OAuth identifies the platform to a third-party
authorization server by a public document,
`https://api.<BASE_DOMAIN>/api/v1/.well-known/evenfire-mcp-client`, built from
`CONTROL_API_OAUTH_CALLBACK_BASE_URL` (it answers 503 when that key is unset). That
server fetches it anonymously, so any WAF, bot or geo rule you put on `api.`
must let `GET` on that exact path through.

## The five hostnames

| Role | Example | Upstream | Called by | Needs |
|---|---|---|---|---|
| `app.` | `app.<BASE_DOMAIN>` | `control-ui.control-plane:3000` | admins, browser | long sessions; SSO/IAP recommended |
| `profile.` | `profile.<BASE_DOMAIN>` | `profile-ui.profiles:3001` | end users, browser (invitation links) | public |
| `api.` | `api.<BASE_DOMAIN>` | `external-rest-api.profiles:8091` | browsers (CORS), Desktop App, OAuth providers (callback) | bodies up to 150 MB; rate-limit `/api/v1/auth/*` |
| `rpc.` | `rpc.<BASE_DOMAIN>` | `rpc-proxy.rpc-proxy:8094` | Desktop App, Control UI (SSE) | **no response buffering, idle timeout >= 10 min**, 250 MB downloads |
| `webhook.` | `webhook.<BASE_DOMAIN>` | `webhook-proxy.webhook-ingress:8095` | GitHub/Slack/Telegram/... servers | HMAC bodies passed byte-for-byte; no WAF body rewriting; 10 MB bodies |

Whatever edge you choose, *these* are the only Services that may be reachable
from outside. In particular, never expose `mcp-host` pods or
`control-api:8090` directly: mcp-host trusts edge headers set by rpc-proxy, and
control-api is reached only through its nginx gateways and NetworkPolicies.

**Keep the five role prefixes.** `<BASE_DOMAIN>` is yours to choose, but the
`app.`, `profile.`, `api.`, `rpc.` and `webhook.` prefixes are read by the
clients: the Desktop App opens `profile.<domain>` (password reset, profile
settings) for a server at `api.<domain>`, and the Control UI shows Slack and
Teams webhook URLs on `webhook.<domain>` when it is served from
`app.<domain>`. Any other naming breaks those links.

## Every value that embeds a hostname

Change these together; they must agree with each other and with your edge's
routing table. **All of them are required** (the last row only with
Cloudflare). For each key the base either ships a loopback default
(`http://127.0.0.1:8091`, `http://127.0.0.1:8094`, `http://127.0.0.1:3001`,
`http://localhost:3001`) or no value at all, and nothing fails when your
overlay does not set it — a dropped patch file or a deleted key renders,
deploys and passes the rollout gate. The first symptom is an end user whose
Desktop App cannot sign in, or an invitation or OAuth flow that breaks. The
value gate in [02](02-assembly-and-overlay-structure.md#render-and-verify-no-cluster-needed)
catches both cases; run it.

| Key | File | Value |
|---|---|---|
| `CONTROL_API_CONTROL_UI_BASE_URL` | configmaps/control-api-config.yaml | `https://app.<BASE_DOMAIN>` |
| `CONTROL_API_DESKTOP_PROFILE_UI_BASE_URL` | configmaps/control-api-config.yaml | `https://profile.<BASE_DOMAIN>` |
| `CONTROL_API_OAUTH_CALLBACK_BASE_URL` | configmaps/control-api-config.yaml | `https://api.<BASE_DOMAIN>` — **must equal** `RPC_PROXY_OAUTH_CALLBACK_BASE_URL` |
| `CONTROL_API_DESKTOP_EXTERNAL_REST_API_BASE_URL` | configmaps/control-api-config.yaml | `https://api.<BASE_DOMAIN>` — the API URL an invited member's Desktop App is set up with; **must equal** `EXTERNAL_REST_API_PUBLIC_BASE_URL` |
| `CONTROL_API_DESKTOP_RPC_PROXY_BASE_URL` | configmaps/control-api-config.yaml | `https://rpc.<BASE_DOMAIN>` — sent with invitations next to the API URL; the app discovers the RPC URL itself, so keep it equal to `EXTERNAL_REST_API_DESKTOP_RPC_PROXY_BASE_URL` |
| `RPC_PROXY_CORS_ORIGIN` | configmaps/rpc-proxy-config.yaml | `https://app.<BASE_DOMAIN>,https://api.<BASE_DOMAIN>` |
| `RPC_PROXY_OAUTH_CALLBACK_BASE_URL` | configmaps/rpc-proxy-config.yaml | `https://api.<BASE_DOMAIN>` |
| `CLERUM_PROFILE_UI_URL` | configmaps/channel-reader-config.yaml | `https://profile.<BASE_DOMAIN>` |
| `EXTERNAL_REST_API_CORS_ORIGIN` | patches/external-rest-api-public-urls.yaml | `https://app.<BASE_DOMAIN>,https://profile.<BASE_DOMAIN>` |
| `EXTERNAL_REST_API_PUBLIC_BASE_URL` | patches/external-rest-api-public-urls.yaml | `https://api.<BASE_DOMAIN>` — the URL users type into the Desktop App; must match it exactly (no path) |
| `EXTERNAL_REST_API_DESKTOP_RPC_PROXY_BASE_URL` | patches/external-rest-api-public-urls.yaml | `https://rpc.<BASE_DOMAIN>` — the Desktop App's only source for the RPC URL |
| `WEBHOOK_PUBLIC_BASE_URL` | patches/dynamic-images.yaml | `https://webhook.<BASE_DOMAIN>` — reserved; not read by any component in the current release |
| `ingress[].hostname` | configmaps/cloudflared-config.yaml | the five names (Cloudflare only) |

Also in the base and **not** overridden by Evenfire's reference overlays —
**verify** whether you need them: `CONTROL_API_GOOGLE_CLIENT_ID` (control-api
ConfigMap), `EXTERNAL_REST_API_GOOGLE_CLIENT_ID` and
`NEXT_PUBLIC_GOOGLE_CLIENT_ID` (external-rest-api / profile-ui Deployments)
ship `replace-me` placeholders for Google sign-in; set them via a patch if you
enable Google login.

Invitation email (`CONTROL_API_MEMBER_REGISTRATION_MODE=hosted`) requires the
two UI base URLs to be **real public DNS names** — no IP literals, no
single-label names — and outbound HTTPS from control-api to the
Evenfire-operated registration hub.

## The Desktop App

End users type **one** URL into the Desktop App: `https://api.<BASE_DOMAIN>`.
Everything else is handed to the app by your server, so the values above are
what make the app work. The public repo's
`docs/how-to/desktop-setup-and-updates.md` describes the app side; this
section is the server side.

| How a user connects | What the app does | Server values it uses |
|---|---|---|
| **Manual:** sign-in screen, **+** beside **Environment**, enter `https://api.<BASE_DOMAIN>` | calls `GET https://api.<BASE_DOMAIN>/api/v1/desktop/environment`, refuses the answer unless its REST URL is exactly the typed one, then saves the RPC URL it was given | `EXTERNAL_REST_API_PUBLIC_BASE_URL`, `EXTERNAL_REST_API_DESKTOP_RPC_PROXY_BASE_URL` |
| **From Profile UI:** **Settings → Setup desktop app** | the dialog shows the API URL the same endpoint returns, with a copy button. The published images ship with the automatic link switched off ("Automatic Desktop handoff is temporarily unavailable"), so the user adds that URL with the manual path. A profile-ui image built with `--build-arg PROFILE_DESKTOP_HANDOFF_ENABLED=true` shows **Open desktop app and setup** instead; that link sets up a new environment, but for one the app already has it only selects it | `EXTERNAL_REST_API_PUBLIC_BASE_URL` (the URL shown) |
| **Invitation:** a new member completes the Profile UI invitation flow, then **Connect to your team** in the app | the registration hub returns the API URL control-api sent with the invitation; the app saves it and discovers the RPC URL from it | `CONTROL_API_DESKTOP_EXTERNAL_REST_API_BASE_URL` (+ the two above) |

Prove it from outside the cluster after the edge is published
([07](07-deploy-sequence-and-verification.md) C4), from a machine with no
port-forwards running:

```bash
curl -s https://api.<BASE_DOMAIN>/api/v1/desktop/environment | jq -e \
  '.externalRestApiBaseUrl == "https://api.<BASE_DOMAIN>" and .rpcProxyBaseUrl == "https://rpc.<BASE_DOMAIN>"'
# true; anything else (false, 127.0.0.1, an error) means the app cannot connect
curl -sSI https://rpc.<BASE_DOMAIN>/health                                       # 200
kubectl --context "$CONTEXT" -n control-plane get cm control-api-config -o json | jq -r \
  '.data | "\(.CONTROL_API_DESKTOP_EXTERNAL_REST_API_BASE_URL) \(.CONTROL_API_DESKTOP_RPC_PROXY_BASE_URL)"'
# https://api.<BASE_DOMAIN> https://rpc.<BASE_DOMAIN>
```

In the app, **Settings** shows the External REST API URL and the RPC proxy URL
it is using.

**After correcting a wrong value** (the symptoms are in [08](08-troubleshooting-and-gotchas.md#desktop-app)):

1. Apply through Phase B ([07](07-deploy-sequence-and-verification.md)); B11
   restarts control-api so it reads its ConfigMap again.
2. Each user who already added the environment removes it in the app and
   adds it again with `https://api.<BASE_DOMAIN>` (sign-in screen, **+**
   beside **Environment**). The app keeps the RPC URL it discovered first and
   does not ask the server again on its own; opening a Profile UI link for an
   environment it already has only selects it.
3. Re-send invitations issued before the fix: an invitation keeps the URLs
   that were configured when it was sent.

Two things to tell your users:

- The app's release link points at
  `https://github.com/evenfire-ai/evenfire/releases/tag/v<version>`. To point
  it at your own download page, add `EXTERNAL_REST_API_DESKTOP_RELEASE_BASE_URL`
  to `patches/external-rest-api-public-urls.yaml` (the server appends
  `/tag/v<version>`).
- **Connect to your team** sends the email address the user enters to the
  Evenfire-operated registration hub (`registration.evenfire.ai`) to find the
  invitation; that is how the invitation path works for every deployment.
  Users who prefer not to can add the environment manually.

## Option A — keep Cloudflare Tunnel

1. In `kustomization.yaml` uncomment `- ../../base/ingress`,
   `- configmaps/cloudflared-config.yaml` and the `allow-dns-egress-ingress`
   patch target.
2. On a workstation: `cloudflared tunnel login` (one-time browser auth to your
   zone), `cloudflared tunnel create <TUNNEL_NAME>`. Note the UUID and the
   credentials file `~/.cloudflared/<TUNNEL_UUID>.json` (a bearer credential;
   keep it in your secret store).
3. Put the UUID in `configmaps/cloudflared-config.yaml`.
4. Deploy the ingress slice (or the whole overlay). The pods crash-loop
   (`CrashLoopBackOff`, no credentials file) until the Secret is filled:
   ```bash
   kubectl kustomize deploy/overlays/$OVERLAY_NAME | kubectl --context "$CONTEXT" apply -l app.kubernetes.io/component=ingress -f -
   jq -n --rawfile f ~/.cloudflared/<TUNNEL_UUID>.json '{data:{"credentials.json":($f|@base64)}}' | \
     kubectl --context "$CONTEXT" -n ingress patch secret cloudflared-credentials --type merge --patch-file /dev/stdin
   kubectl --context "$CONTEXT" -n ingress rollout restart deploy cloudflared
   ```
   The `kubectl patch --type=merge` writes outside the apply envelope, so later
   applies of the empty canary Secret leave the credentials alone ([06](06-secrets-keys-rbac-crds.md)).
5. DNS: `cloudflared tunnel route dns <TUNNEL_NAME> <host>` for each of the
   five hostnames. **This is the moment the UIs become reachable** — do the
   admin bootstrap ([07](07-deploy-sequence-and-verification.md)) first.
6. Edge hardening (dashboard or API): enable the managed WAF ruleset; add a
   skip rule for `webhook.<BASE_DOMAIN>` in the managed phase; add a rate-limit
   rule on `api.<BASE_DOMAIN>` + path prefix `/api/v1/auth/`; create an Access
   application for `app.<BASE_DOMAIN>` tied to your IdP. Rate-limit options
   (window, number of rules) depend on your Cloudflare plan.
7. Adding a hostname later needs three edits: the ConfigMap route, a new
   egress block in `deploy/base/ingress/networkpolicies.yaml`
   (`allow-cloudflared-egress` is an enumerated allow-list — under enforcement
   a route with no egress lane is dropped), and the DNS CNAME.

## Option B — a GKE-native or in-cluster edge (no Cloudflare)

Leave the three Cloudflare lines commented. Then:

### B.1 What to remove / what changes

| Item | Effect without Cloudflare |
|---|---|
| `deploy/base/ingress` (cloudflared, its NetworkPolicies, the `ingress` namespace manifest) | not rendered. The **namespace `ingress` must still exist** before you run `bootstrap-rbac.sh` (it applies `base/ingress/rbac.yaml` regardless): `kubectl --context "$CONTEXT" create ns ingress`. |
| `configmaps/cloudflared-config.yaml` | not rendered |
| `allow-dns-egress-ingress` patch target | keep commented (it would match nothing and be silently skipped) |
| `replacements:` -> `allow-cloudflared-egress` | no-op (verified: renders without the ingress base) |
| `PublicEgressExceptionSet` | still used by base for every other public-egress policy; keep |
| TLS | now yours: Google-managed certificates (Gateway/Ingress), cert-manager, or a certificate you upload |
| Access/WAF/rate limiting | now yours: IAP, Cloud Armor, or the ingress controller's own features |

### B.2 NetworkPolicies you must add

Every public upstream only admits `namespace: ingress` + `app: cloudflared`
(table in [01](01-architecture-and-namespaces.md)). Add one ingress policy per
upstream that admits **your** edge instead. Two shapes:

**In-cluster proxy (ingress-nginx, Istio/Envoy Gateway):** select the proxy
pods by namespace + label. Example for ingress-nginx in namespace
`ingress-nginx` reaching rpc-proxy (repeat for the other four, changing
namespace/app/port):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-edge-ingress-rpc-proxy
  namespace: rpc-proxy
spec:
  podSelector:
    matchLabels: { app: rpc-proxy }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
          podSelector:
            matchLabels: { app.kubernetes.io/name: ingress-nginx }
      ports:
        - { port: 8094, protocol: TCP }
```

Put these in your overlay (e.g. `edge/networkpolicies.yaml`, listed under
`resources:`). The proxy's own namespace must not be default-deny unless you
also write its egress lanes.

**Google front end (GKE Gateway API / GCLB Ingress with container-native
NEGs):** traffic arrives from Google's proxy and health-check ranges, not from
a pod. Use `ipBlock` entries for those ranges (`35.191.0.0/16` and
`130.211.0.0/22` are the documented health-check/proxy ranges; **verify
against current Google Cloud documentation** for your load-balancer type and
region, and add the proxy-only subnet CIDR you create for a regional external
Application Load Balancer). Readiness probes from the LB must also be allowed
or the backends never become healthy.

Run `deploy/scripts/lint-networkpolicies.sh --rendered <render>` after adding
policies; it rejects over-broad shapes.

### B.3 Edge requirements per option

| Edge | TLS | SSE / long-lived (`rpc.`) | Large bodies | Webhook bodies | Auth for `app.` |
|---|---|---|---|---|---|
| **GKE Gateway API** (`gke-l7-global-external-managed`) + Google-managed certs | automatic | set backend timeout >= 600 s via a `GCPBackendPolicy`; HTTP/1.1 streaming works | default max fine; set `maxRequestBodySize` if you front with Cloud Armor | not inspected unless Cloud Armor rules are added; exclude `webhook.` from WAF rules | **IAP** on the `app.` backend (`GCPBackendPolicy.iap`) |
| **GCLB Ingress** (`ingress.class: gce`) + `ManagedCertificate` | automatic | `BackendConfig.timeoutSec: 600+` | — | same as above | IAP via `BackendConfig.iap` |
| **ingress-nginx + cert-manager** (needs a Service `type: LoadBalancer`, i.e. a public IP) | cert-manager / ACME | annotations `proxy-read-timeout: "600"`, `proxy-buffering: "off"` on the `rpc.` Ingress | `proxy-body-size: 250m` on `rpc.`, `150m` on `api.`, `10m` on `webhook.` | pass-through by default | oauth2-proxy / your IdP; or IAP is not available here |
| **Istio / Envoy Gateway** | cert-manager or your certs | `HTTPRoute` timeouts >= 600 s; streaming is native | per-route limits | pass-through | ext-authz / your IdP |

Common to all: forward `X-Forwarded-Proto: https` and the original `Host`;
control-api and external-rest-api build absolute URLs from the configured base
URLs rather than the request, but OAuth providers compare the callback they
receive against `CONTROL_API_OAUTH_CALLBACK_BASE_URL`.

### B.4 Recommended hardening to replace what Cloudflare provided

- Gate `app.<BASE_DOMAIN>` behind IAP (Google identities) or your IdP; keep
  `api.`, `rpc.`, `webhook.` on application auth only.
- Cloud Armor (or equivalent): rate-limit `api.<BASE_DOMAIN>/api/v1/auth/*`
  per source IP; enable managed WAF rules but exclude `webhook.<BASE_DOMAIN>`.
- Do not publish DNS for the UIs until the admin account is claimed
  ([07](07-deploy-sequence-and-verification.md)).
