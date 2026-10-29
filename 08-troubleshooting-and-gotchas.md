# 08 — Troubleshooting and gotchas

Symptoms first. The render/apply and pod rows were all hit on Evenfire's own
GKE clusters; the network rows that concern edges Evenfire does not run
(Google load balancers, ingress-nginx, Istio, IAP, Dataplane V2) are the
expected failure modes of those components, not observations.

## Render / diff / apply

| Symptom | Cause | Fix |
|---|---|---|
| `unable to parse SM or JSON patch`, or the render is suspiciously empty | a multi-document YAML listed under `patches:` | move it to `patchesStrategicMerge:` ([02](02-assembly-and-overlay-structure.md)) |
| `kubectl diff` exits **2** (not 0/1), apiserver says `spec.strategy.rollingUpdate: Forbidden` | live Deployment still carries `rollingUpdate` while the manifest now says `Recreate` (control-api, control-postgres, HCC) | `kubectl --context "$CONTEXT" -n control-plane patch deploy <name> --type=merge -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'` then diff again. Idempotent; run it before every diff if unsure |
| `kubectl diff` exit 1 | drift — **not** an error | read the diff; exit 1 is the expected "there is something to apply" |
| apply aborts with `roles.rbac.authorization.k8s.io ... forbidden` | RBAC objects in the apply set with a non-admin identity | strip RBAC (B5) and run `bootstrap-rbac.sh` as admin |
| apply rejects an EnvVar with both `value` and `valueFrom` | a strategic-merge patch set `value:` on an env var the base defines via `valueFrom:` | mirror the base shape: copy the env entry from the rendered base Deployment |
| render succeeds, but under enforcement cloudflared cannot resolve its upstreams | `base/ingress` enabled while the `allow-dns-egress-ingress` patch target stayed commented: a JSON6902 target with no match is silently skipped, so the policy lacks the kube-dns ipBlock | uncomment the target (keep the three Cloudflare lines together); the ingress-DNS check in [02](02-assembly-and-overlay-structure.md) catches it at render time |
| the diff shows `mcp-host-config.CLERUM_AUTH_JWT_PUBLIC_KEY` replaced and `gfs-config.jwt-public-key` blanked | expected: the committed value is empty | **do not fix the overlay**; B8 restores both right after the apply. Never let a later step fail between B7 and B8 |
| pods still run old config after a ConfigMap-only change | ConfigMap edits do not roll pods; several mount via subPath/envFrom | B11 restart list; for others `rollout restart` by hand |
| HCC crash-loops on start with a CIDR validation error | placeholder or over-broad entry in `CONTEXT_MAPPER_K8S_API_CIDRS` | run the detect script; prefixes must be /24 or longer |

## Pods

| Symptom | Cause | Fix |
|---|---|---|
| `CreateContainerConfigError: couldn't find key connection-string` on control-api / trace-maintenance-worker / workflow-recipes | runtime DB roles never provisioned | B3 `provision-control-api-runtime-roles.sh` |
| same on `gfsc-writer` / `gfsc-reader` | GFS DB credentials not finalised | B10 `provision-gfs-runtime.sh` (waits for HCC, then patches the two Secrets) |
| `CreateContainerConfigError` on anything else | a Secret key the Deployment references is missing | `CONTEXT=... bash deploy/scripts/verify-secrets.sh` names it. **First install:** the key step that writes it has not run yet (`gen-jwt-keys.sh` A4, `apply-inter-service-tokens.sh` A4b). **Populated cluster:** never re-run `gen-jwt-keys.sh` (rule 8) — patch the single missing key back from your secret-manager backup (`kubectl patch --type=merge --patch-file`, [06](06-secrets-keys-rbac-crds.md#backup)); `apply-inter-service-tokens.sh` without env vars is safe to re-run, it preserves existing values |
| `ImagePullBackOff` pulling `clerum/<svc>:latest` from Docker Hub | an image with no `images:` entry / no `dynamic-images.yaml` reference after a release added a service | add the entry; the `grep ... clerum/` render gate in [02](02-assembly-and-overlay-structure.md) catches it before apply |
| `ImagePullBackOff` on `nginx`, `postgres`, `busybox` | no egress to Docker Hub from nodes | allow it, or mirror and re-point them: `images:` entries for nginx/postgres, `CONTEXT_MAPPER_WFC_INIT_IMAGE` for busybox ([05](05-images-registry-and-pinning.md)) |
| cloudflared pods in `CrashLoopBackOff` (no credentials file) | `cloudflared-credentials` Secret still the empty canary: the volume mounts but holds no `credentials.json` | patch the credentials, restart ([03](03-ingress-and-hostnames.md)) |
| control-api refuses to start: `MEMBER_REGISTRATION_MODE=hosted is mutually exclusive with ...` | `CONTROL_API_MEMBER_REGISTRATION_HMAC_KID` / `_TENANT_ID` present | remove them from the ConfigMap (the template never sets them) |
| migration Job fails `Cannot find module /app/dist/migrate.js` | the rendered control-api image is not a platform release image | fix `<REGISTRY_PATH>/<IMAGE_TAG>` |
| migration Job times out on a lock | a concurrent writer (retention prune) held a table lock | the Job retries (backoffLimit 2); re-run the gate if it still fails |
| HCC `rollout status` takes 15–20 min after an image change | HCC serves 503 on `/ready` until its initial fleet reconciliation completes; time scales with the number of McpServers/Contexts | wait (use a 1500 s timeout for HCC only); do not restart it |
| agent pod flaps 0/1 after a deploy with `workflow_auth_refresh` 401 then 429 | per-Host runtime token churn after HCC recreated pods | self-heals in ~6 min on an image-bump deploy (HCC mints a fresh pair); after a pure churn recreate, `rollout restart` that Host's Deployment |
| `channel-reader-<host>` is Ready but Telegram/Slack never starts (no adapter log line, bot silent) | the `CommunicationChannel` has no `spec.credentialsSecretRef`, or it names a Secret that does not exist (`[Credentials] CC <name> references missing Secret ...` in the pod log) | `kubectl --context "$CONTEXT" -n channels get communicationchannel <name> -o jsonpath='{.spec.credentialsSecretRef.name}'` must print a Secret that exists in `channels` with the provider key (`telegram-bot-token`, ...); set it via kubectl, the Control UI or the credentials API ([06](06-secrets-keys-rbac-crds.md#channel-credentials)) |
| `channel-reader-<host>` shows `0/0` | no `CommunicationChannel` references that Host yet; HCC scales the reader to 0 | expected; apply the channel instance |
| a Host's agent Deployment in `mcp-host` shows `0/0`, no pod | the Host has `spec.lifecycle.stateless: true` and is idle: HCC set `status.lifecycle.state: suspended` and scaled it to 0 ([01](01-architecture-and-namespaces.md#the-two-controllers)) | expected, not a failure; the next request wakes it. `kubectl --context "$CONTEXT" -n mcp-host get host <name> -o jsonpath='{.status.lifecycle}'`. A `0/0` Host **without** the flag is a real problem |
| a stateless Host never scales to 0 | `StatelessEnableRejected` condition on the Host (a `CommunicationChannel`, `spec.desktop`, or an unsatisfiable SharedFileSystem co-location), or work/activity within the idle window | `kubectl --context "$CONTEXT" -n mcp-host get host <name> -o jsonpath='{.status.conditions}'`; a rejected Host runs as an ordinary `replicas: 1` Host |
| a Host pod stuck in `Init:Error`, failing init container `workspace-layout-merge` (v0.12.0+) | the merge refused that PVC's tree; the init log names the rule. Every refusal exits before its first move, so the tree is unchanged | do not roll HCC back while it is in this state. Repair from a helper Pod (*Repairs* in `docs/deploy/host-pvc-layout-upgrade.md` in the clone), then run `bash deploy/scripts/host-layout-merge.sh verify --context "$CONTEXT"`. Run `inventory` before the next upgrade to catch these up front ([11](11-upgrades.md#upgrading-from-v0110-to-v0120)) |
| HCC fails at startup: `CONTEXT_MAPPER_WORKSPACE_LAYOUT_MERGE must be 'true' or 'false', got '...'` | a value other than the exact strings in `patches/hcc-workspace-layout-merge.yaml` | set `"true"` or `"false"` and re-apply |
| a Host's chat history is empty after the layout merge switch was set to `"false"` | its PVC was still split when the switch went off, so no merge ran; `verify` / `inventory` print `FLAG_FALSE_WITH_SPLIT_TREES=<n>` | set the switch back to `"true"` and deploy. If the Host already started with it off, the next start keeps the newer root database and renames the older history to `state.db.superseded-<ts>`; to serve the older one, see *Repairs* in the upstream note |
| OAuth grants / Marketplace connection / LLM subscription suddenly unreadable, control-api logs `registry_connection_state_unreadable` | `control-api-secrets` was regenerated (`gen-jwt-keys.sh` re-run) or restored from a different backup than the database | restore **only** the two data-encryption keys from your secret-manager backup, re-patch the Postgres password, restart the signing-key consumers and run the JWT sync — the key-scoped procedure in [06](06-secrets-keys-rbac-crds.md#recovery-after-an-accidental-re-run-of-gen-jwt-keyssh). Do not restore the whole backed-up `data:` map (old private keys against the regenerated public halves). Without the backup the records are lost |
| `calico-node` DaemonSet shows desired 0 after enabling the add-on | nodes not yet recreated with the `ds-ready` label | the node-pool recreation step ([04](04-network-policies-and-cni.md)) |

## Network

| Symptom | Cause | Fix |
|---|---|---|
| operators (HCC/WRC/control-api) log timeouts to the Kubernetes API right after enforcement went live | `allow-k8s-api-egress-*` carries only the ClusterIP; Calico evaluates the post-DNAT endpoint IP | detect script, re-apply; `np-enforce-preflight.sh` check [2] flags it ([04](04-network-policies-and-cni.md)) |
| DNS resolution fails inside pods (`EAI_AGAIN`) under enforcement | NodeLocal DNSCache + namespace-selector-only DNS rule | the kube-dns ipBlock patch (template) — check `patches/nodelocal-dns-egress-rule.yaml` and `CONTEXT_MAPPER_NODELOCAL_DNS_CIDR` |
| transient `EAI_AGAIN` for a minute after a node bounce | CoreDNS warming up on the new node | wait; DB-dependent pods restart once or twice and recover |
| everything works even though a policy should block it | CNI not enforcing | [04](04-network-policies-and-cni.md) — the deny probe must print `BLOCKED` |
| a WorkflowRecipe is refused: `NetworkPolicy enforcement mode is required for WorkflowRecipe "<name>", but CLERUM_NETWORK_POLICY_ENFORCEMENT_CONFIRMED is not true` | its MCP servers declare external egress and WRC runs `required` with `CONFIRMED=false` (the template default) | prove enforcement on this cluster ([04](04-network-policies-and-cni.md) probes), then set `CONFIRMED` to `"true"` and re-apply ([07](07-deploy-sequence-and-verification.md) C7). Never flip it without the proof |
| profile-ui -> external-rest-api `UND_ERR_CONNECT_TIMEOUT` | a missing intra-namespace lane | the base ships `profile-ui-to-external-rest-api`; make sure `verify-networkpolicies.sh` is clean |
| your ingress controller gets connection timeouts to the upstreams | every upstream admits only `ingress/cloudflared` | add the edge ingress policies ([03](03-ingress-and-hostnames.md) B.2) |
| GCLB backends never healthy | health-check ranges blocked | ipBlock for Google's health-check ranges on each upstream port |
| SSE streams from the Desktop App drop after 30–60 s | edge buffering or a short idle timeout on `rpc.` | `proxy-buffering off`, idle/backend timeout >= 600 s |
| webhook deliveries fail signature verification | the edge (WAF, body normalisation, compression) modified the body | exclude `webhook.` from WAF; pass bodies byte-for-byte |
| OAuth callback `redirect_uri mismatch` | `CONTROL_API_OAUTH_CALLBACK_BASE_URL` != `RPC_PROXY_OAUTH_CALLBACK_BASE_URL`, or the provider app registered a different URL | make all three identical |
| browser calls to `api.` fail CORS | `EXTERNAL_REST_API_CORS_ORIGIN` / `RPC_PROXY_CORS_ORIGIN` do not list the exact origin (scheme + host) | update both and restart |
| WRC logs `ExternalEgressReady` not fresh / stale | WRC rolled before HCC reconciled existing `McpServer`s | wait; it clears once HCC's pass finishes. On upgrades HCC rolls first by design |
| invitation emails not sent, hosted mode | UI base URLs are IP literals / single-label, or no egress to the registration hub | real public DNS names + public 443 egress from control-api |
| a pod needing Workload Identity cannot reach `169.254.169.254` | metadata range is in the public-egress exception list | explicit egress policy for that pod ([04](04-network-policies-and-cni.md)) |

## Desktop App

Start every case with the discovery check in
[03 › The Desktop App](03-ingress-and-hostnames.md#the-desktop-app). Every fix
below ends with the three steps under "After correcting a wrong value" there:
apply, have each user remove and re-add the environment, re-send old
invitations.

| Symptom | Cause | Fix |
|---|---|---|
| "Login failed. Check your email and password." with credentials that work in Profile UI | the app could not finish discovery: `EXTERNAL_REST_API_PUBLIC_BASE_URL` is not exactly the URL the user typed (base default `http://127.0.0.1:8091`), or `api.` is not reachable from the user's machine | set it to `https://api.<BASE_DOMAIN>` in `patches/external-rest-api-public-urls.yaml` |
| Profile UI **Settings → Setup desktop app** shows the API URL `http://127.0.0.1:8091` | `EXTERNAL_REST_API_PUBLIC_BASE_URL` left at the base default (the dialog shows what the discovery endpoint returns) | same |
| sign-in works, then chats or file transfers fail with connection errors; **Settings** shows an RPC proxy URL on `127.0.0.1` or a wrong host | `EXTERNAL_REST_API_DESKTOP_RPC_PROXY_BASE_URL` was wrong when the app first connected (base default `http://127.0.0.1:8094`), or `rpc.` is not routed | fix the value; the app keeps the old RPC URL until the user removes and re-adds the environment |
| after **Connect to your team**, an invited member cannot sign in and the app's **Settings** shows External REST API `http://127.0.0.1:8091` | `CONTROL_API_DESKTOP_EXTERNAL_REST_API_BASE_URL` left at the base default in `configmaps/control-api-config.yaml` (the app is set up with the API URL the invitation carried) | set it, and `CONTROL_API_DESKTOP_RPC_PROXY_BASE_URL` with it; apply (B11 restarts control-api); **re-send the invitation**. A member who already connected removes the environment and adds `https://api.<BASE_DOMAIN>` |
| works on the operator's workstation, fails for everyone else | the operator still has port-forwards on `8091` / `8094`, which answer for the base defaults | stop the forwards and re-test; fix the values above |
| **Forgot password** or profile settings in the app open the wrong site | the API hostname does not start with `api.`; the app derives `profile.<domain>` from it | keep the role prefixes ([03](03-ingress-and-hostnames.md#the-five-hostnames)) |

## Operational rules (learned the hard way)

1. **Diff before apply, every time**, and read the exit code the way the table says.
2. **Never leave the window between apply and JWT sync open**: if the sync
   (B8 on upgrades; B10's built-in sync on a first install) does not run,
   every agent and gfsc fails auth. Script apply + sync as one unit.
3. **Commit the tag you applied.** A cluster ahead of its overlay is rolled
   back by the next apply.
4. **Never hand-edit live objects.** Server-side apply with `--force-conflicts`
   reclaims the field on the next deploy; HCC's periodic resync reverts its
   own policies.
5. **CRDs before images, RBAC before apply.** Both are outside the apply.
6. **One release tag for tree and images.** Mixing them is unsupported.
7. **Keep `CLERUM_NETWORK_POLICY_ENFORCEMENT_CONFIRMED=false`** until the
   enforcement probes ([04](04-network-policies-and-cni.md)) passed on this cluster.
8. **Never re-run `gen-jwt-keys.sh` on a cluster with data**: it is a
   bootstrap generator that also replaces the data-encryption keys, which
   makes stored OAuth/registry/subscription credentials unreadable. Rotate
   per key ([06](06-secrets-keys-rbac-crds.md#key-rotation-key-by-key));
   `apply-inter-service-tokens.sh` preserves existing values as long as you
   pass it no override env vars (an env var wins over the stored value).
9. **Protect the apply path**: required reviewers on the CI environment,
   `CONFIRM`-style guards on manual production targets, explicit `--context`
   on every command.
