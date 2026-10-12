# Installing Evenfire on your own GKE cluster

This folder is the install guide Evenfire hands to a customer's platform
engineer. It describes how Evenfire runs its own production cluster on GKE and
how to map that setup onto yours. Every environment-specific value is a
`<PLACEHOLDER>`; nothing here refers to Evenfire's own project, hostnames,
addresses or credentials. Sizing values (machine types, volume sizes,
requests/limits) are indicative starting points, not requirements.

The platform itself is open source: **evenfire-ai/evenfire** on GitHub ships
every service, the Kubernetes base manifests (`deploy/base`), the CRD Helm
chart (`charts/clerum-crds`) and the deploy scripts. What this guide adds is the
*environment half*: the Kustomize overlay, the GKE-specific decisions, and the
order of operations that Evenfire has validated in production.
Every object you deploy is defined in the public repo except two ConfigMaps
your overlay adds; the overlay patches 27 of the 250 base objects with your
values. See [02 › What comes from the open-source repo](02-assembly-and-overlay-structure.md#what-comes-from-the-open-source-repo-and-what-is-yours)
for the ownership split and what it means for upgrades.

> `clerum` is the historical code name of the platform. It survives as the CRD
> API group (`clerum.io`), image names (`clerum/<service>`), env-var prefixes
> and several resource names. Treat it as a fixed identifier, not something to
> rename.

## One-page mental model

```
                 your users / Desktop App / chat providers / webhook senders
                                     │ HTTPS
                                     ▼
        ┌─────────────────── public edge (your choice) ───────────────────┐
        │  Cloudflare Tunnel (Evenfire's choice)  OR  GKE Gateway / GCLB  │
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

Three facts explain most of the design:

1. **Everything is default-deny.** Every namespace ships a `deny-all`
   NetworkPolicy; each allowed hop is an explicit policy. Two controllers
   (HCC and WRC) generate the per-agent and per-workflow policies at runtime.
   Your CNI must actually enforce NetworkPolicy, or none of this exists
   ([04](04-network-policies-and-cni.md)).
2. **Nothing renders on its own.** The overlay you write references
   `../../base` from the public repo; a deploy = assemble public tree at a
   release tag + your overlay, then `kubectl kustomize` ([02](02-assembly-and-overlay-structure.md)).
3. **Secrets never live in the overlay.** Base ships empty "canary" Secrets;
   scripts populate them with `kubectl patch` *outside* the apply envelope so
   re-applies never wipe them ([06](06-secrets-keys-rbac-crds.md)).

## Reading order

| # | File | Read it when |
|---|------|--------------|
| 0 | [00-prerequisites.md](00-prerequisites.md) | before creating anything: cluster shape, IAM, tools, DNS |
| 1 | [01-architecture-and-namespaces.md](01-architecture-and-namespaces.md) | to know what lands where and which pods are spawned at runtime |
| 2 | [02-assembly-and-overlay-structure.md](02-assembly-and-overlay-structure.md) | to build your overlay from [overlay-template/](overlay-template/) |
| 3 | [03-ingress-and-hostnames.md](03-ingress-and-hostnames.md) | to decide Cloudflare Tunnel vs. a GKE-native edge, and set every hostname-bearing value |
| 4 | [04-network-policies-and-cni.md](04-network-policies-and-cni.md) | to pick/verify the CNI, fill the API-server and DNS CIDRs, prove enforcement |
| 5 | [05-images-registry-and-pinning.md](05-images-registry-and-pinning.md) | to choose where images come from and how pins are bumped |
| 6 | [06-secrets-keys-rbac-crds.md](06-secrets-keys-rbac-crds.md) | to understand every Secret, key, RBAC object and CRD and who creates it |
| 7 | [07-deploy-sequence-and-verification.md](07-deploy-sequence-and-verification.md) | the actual first-install and upgrade runbook, with verification |
| 8 | [08-troubleshooting-and-gotchas.md](08-troubleshooting-and-gotchas.md) | when something is red |
| 9 | [09-values-checklist.md](09-values-checklist.md) | the single table of every `<PLACEHOLDER>` and how to discover it |

Start with 0, 2 and 9 if you only want to get to a rendered overlay quickly;
3 and 4 are the two decisions that cannot be deferred.

## Conventions used in this guide

- `<BASE_DOMAIN>` is your DNS zone or sub-zone, e.g. `evenfire.example.com`.
  The five subdomain **roles** (`app.`, `profile.`, `api.`, `rpc.`, `webhook.`)
  are a convention: rename freely, but keep each role consistent across every
  file that embeds it (listed in [03](03-ingress-and-hostnames.md)).
- "Evenfire's reference setup" means the production overlay this template was
  sanitized from. When the guide says "verified", it means verified on that
  cluster, with the CNI and release noted; when it says **verify**, it means
  the behaviour is expected but you must confirm it on *your* cluster, and the
  command to do so is given.
- Commands are written for a shell at the root of an assembled tree
  ([02](02-assembly-and-overlay-structure.md)) with `CONTEXT=<your kube-context>`
  exported. Every `kubectl` in this guide passes `--context "$CONTEXT"`, and the
  platform scripts take it from that variable. Always set it: several
  scripts (`bootstrap-rbac.sh`, `gen-jwt-keys.sh`, `apply-inter-service-tokens.sh`,
  `verify-secrets.sh`, ...) fall back to the current kubeconfig context when it
  is empty.

## What to ask Evenfire before you start

- Which **release tag** to deploy (the public repo's `vX.Y.Z` tags; images are
  published under the same tag).
- Whether you need the **LLM subscription** proxies (feature gates, default
  off). The plugin registry needs no Evenfire-issued credentials: the template
  already sets `REGISTRY_CONNECTION_MODE=self-hosted` and `CLERUM_REGISTRY_URL`,
  and after install an admin runs **Control UI -> Marketplace -> Connect**
  (organization name + contact email), which registers this deployment with
  its own keypair.
- Confirmation that the published images are pullable anonymously from the
  public registry, or an alternative pull path.
