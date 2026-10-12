# Deploy Evenfire on Google Kubernetes Engine

Runbook and Kustomize overlay template for running the open-source
[evenfire-ai/evenfire](https://github.com/evenfire-ai/evenfire) platform on
your own GKE cluster. Every value you must change is a `<PLACEHOLDER>` marked
`# CHANGE ME`; sizing values are indicative starting points, not requirements.

## How a deploy fits together

You do not fork the platform. A deploy is the public repo at a release tag
plus your copy of [overlay-template/](overlay-template/):

```
evenfire/                                  <- git clone --branch <RELEASE_TAG> evenfire-ai/evenfire
  deploy/base/**, charts/clerum-crds/**    <- workloads, Services, NetworkPolicies, RBAC, CRDs
  deploy/scripts/**, scripts/**            <- the scripts this runbook calls
  deploy/overlays/<OVERLAY_NAME>/**        <- your copy of overlay-template/ (hostnames, registry, CIDRs, sizing)
```

Secrets and keys never go in the overlay: scripts create them in the cluster
and you back them up to your secret manager. Details:
[02 › What comes from the open-source repo](02-assembly-and-overlay-structure.md#what-comes-from-the-open-source-repo-and-what-is-yours).

## Before you start

| You need | Where it is covered |
|---|---|
| A GKE **Standard** cluster whose dataplane **enforces NetworkPolicy** (Dataplane V2 or the Calico add-on) | [00](00-prerequisites.md), [04](04-network-policies-and-cni.md) |
| A DNS zone you control for five public hostnames, and a way to serve them (Cloudflare Tunnel, GKE Gateway / Cloud Load Balancing, ingress-nginx, Envoy/Istio, ...) | [03](03-ingress-and-hostnames.md) |
| Outbound HTTPS from the cluster (LLM providers, image registry, Evenfire registration hub; Cloud NAT if nodes are private) | [00](00-prerequisites.md#external-dependencies) |
| At least one LLM provider API key | [06](06-secrets-keys-rbac-crds.md) |
| `gcloud`, `kubectl`, `helm`, `git`, `jq`, `openssl`, `python3` + `bcrypt` (or `htpasswd`) | [00](00-prerequisites.md#workstation-tooling) |
| The platform **release tag** to deploy (e.g. `v0.11.0`), agreed with Evenfire | [02](02-assembly-and-overlay-structure.md) |

Two decisions cannot be deferred: **how you expose the hostnames** ([03](03-ingress-and-hostnames.md))
and **which NetworkPolicy dataplane** you run ([04](04-network-policies-and-cni.md)).

## Install path

| Step | What you do | Guide |
|---|---|---|
| 1 | Create the cluster (private nodes recommended) and confirm NetworkPolicy enforcement is on | [00](00-prerequisites.md), [04](04-network-policies-and-cni.md) |
| 2 | Clone the public repo at the release tag, copy `overlay-template/` in as your overlay | [02](02-assembly-and-overlay-structure.md#the-assembly-model) |
| 3 | Fill every placeholder; detect your API-server and DNS addresses with `scripts/detect-k8s-api-ip.sh` | [09](09-values-checklist.md), [04](04-network-policies-and-cni.md#fill-the-cluster-specific-cidrs) |
| 4 | Render offline and pass the lint gates (no cluster needed) | [02](02-assembly-and-overlay-structure.md#render-and-verify-no-cluster-needed) |
| 5 | **Phase A**, once: namespaces + CRDs, RBAC, keys, tokens, LLM keys | [07](07-deploy-sequence-and-verification.md#phase-a--one-time-bootstrap-admin-identity) |
| 6 | **Phase B**, every deploy: diff, apply, key sync, NetworkPolicy check, rollout gate | [07](07-deploy-sequence-and-verification.md#phase-b--every-deploy-first-install-and-upgrades) |
| 7 | **Phase C**, first install: claim the admin account, smoke-test, publish the edge, back up secrets, prove enforcement, connect the plugin registry | [07](07-deploy-sequence-and-verification.md#phase-c--first-install-only-after-b) |

Always run the **diff** before the **apply**. Back up `control-api-secrets`
right after it is generated: its encryption keys cannot be regenerated without
losing stored credentials ([06](06-secrets-keys-rbac-crds.md#backup)).

## Architecture at a glance

```
                 your users / Desktop App / chat providers / webhook senders
                                     │ HTTPS
                                     ▼
        ┌──────────────────────── public edge (your choice) ──────────────┐
        │  Cloudflare Tunnel  OR  GKE Gateway / Cloud Load Balancing      │
        │  OR ingress-nginx + cert-manager  OR  Istio / Envoy Gateway     │
        └──┬───────────┬──────────────┬──────────────┬───────────────┬────┘
           │           │              │              │               │
  app.<D>  │  profile.<D>      api.<D>│       rpc.<D>│      webhook.<D>
           ▼           ▼              ▼              ▼               ▼
      control-ui   profile-ui  external-rest-api  rpc-proxy    webhook-proxy
      :3000        :3001       :8091              :8094 (SSE)  :8095 (HMAC)
      control-plane profiles   profiles           rpc-proxy    webhook-ingress
           │           │              │              │               │
           └───────────┴──────┬───────┴──────────────┴───────────────┘
                              ▼
                 control-api :8090 (control-plane) ── control-postgres :5432
                              │
            ┌─────────────────┼─────────────────────────┐
            ▼                 ▼                         ▼
  host-context-controller   workflow-recipes (WRC)   gfs-controller (gfsc)
  spawns per-Host agent     spawns per-recipe         global file system
  pods (mcp-host), channel  coordinators, snippet     (writer + readers)
  readers, MCP servers,     runners, webhook
  NetworkPolicies           gateways, NetworkPolicies
            │                 │
            ▼                 ▼
   mcp-host / mcp-server   sandbox-recipes / sandbox-ui     (runtime namespaces,
   channels                                                 default-deny, HCC/WRC-managed policies)
```

(`<D>` is `<BASE_DOMAIN>`; ports are the in-cluster Service ports.)

What to keep in mind while operating it:

1. **Everything is default-deny.** Every namespace ships a `deny-all`
   NetworkPolicy and each allowed hop is an explicit policy; two controllers
   (HCC and WRC) add per-agent and per-workflow policies at runtime. If your
   dataplane does not enforce NetworkPolicy, none of this protects you
   ([04](04-network-policies-and-cni.md)).
2. **Nothing renders on its own.** The overlay references `../../base` from
   the public repo, so always render from an assembled tree ([02](02-assembly-and-overlay-structure.md)).
3. **Secrets live in the cluster, not in git.** The base ships empty
   placeholder Secrets; scripts fill them with `kubectl patch`, so later
   applies never wipe them ([06](06-secrets-keys-rbac-crds.md)).

## Guide map

| # | File | Use it to |
|---|------|-----------|
| 0 | [00-prerequisites.md](00-prerequisites.md) | create the cluster: shape, private nodes, storage, IAM, tools, DNS |
| 1 | [01-architecture-and-namespaces.md](01-architecture-and-namespaces.md) | know what runs where and which pods are created at runtime |
| 2 | [02-assembly-and-overlay-structure.md](02-assembly-and-overlay-structure.md) | build and render your overlay; keep it correct across upgrades |
| 3 | [03-ingress-and-hostnames.md](03-ingress-and-hostnames.md) | choose your edge and set every hostname-bearing value |
| 4 | [04-network-policies-and-cni.md](04-network-policies-and-cni.md) | pick and verify the dataplane, fill CIDRs, prove enforcement |
| 5 | [05-images-registry-and-pinning.md](05-images-registry-and-pinning.md) | choose where images are pulled from and bump versions |
| 6 | [06-secrets-keys-rbac-crds.md](06-secrets-keys-rbac-crds.md) | create, back up and rotate every Secret and key; RBAC and CRDs |
| 7 | [07-deploy-sequence-and-verification.md](07-deploy-sequence-and-verification.md) | run the install, upgrades and rollback, with verification |
| 8 | [08-troubleshooting-and-gotchas.md](08-troubleshooting-and-gotchas.md) | diagnose a failing step or pod |
| 9 | [09-values-checklist.md](09-values-checklist.md) | find every `<PLACEHOLDER>` and how to discover its value |

## Conventions

- **Set `CONTEXT`.** Commands run from the root of the assembled tree with
  `export CONTEXT=<your kube-context>`. Every `kubectl` here passes
  `--context "$CONTEXT"`; several platform scripts fall back to your current
  kubeconfig context when it is empty, so always set it.
- **Hostnames.** `<BASE_DOMAIN>` is your DNS zone, e.g. `evenfire.example.com`.
  The five roles (`app.`, `profile.`, `api.`, `rpc.`, `webhook.`) can be
  renamed, as long as each one is consistent everywhere it appears ([03](03-ingress-and-hostnames.md)).
- **"verify"** marks behaviour you must confirm on your cluster; the command to
  do so is given next to it.
- **`clerum`** is the platform's internal name. It appears in the CRD API group
  (`clerum.io`), image names, env-var prefixes and some resource names. Do not
  rename it.

## After install

- **Plugin registry:** no credentials to request. An admin connects from
  **Control UI → Marketplace → Connect** (organization name + contact email).
- **Upgrades:** move to the new release tag, re-assemble with your unchanged
  overlay, and run the drift checks before Phase B ([07 › Upgrades](07-deploy-sequence-and-verification.md#upgrades)).
- **Optional features:** the LLM subscription proxies are off by default; ask
  Evenfire before enabling them.
- **Help:** open an issue in this repository or contact your Evenfire
  representative.
