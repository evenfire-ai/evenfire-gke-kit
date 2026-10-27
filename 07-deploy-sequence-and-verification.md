# 07 — Deploy sequence and verification

> **This is Evenfire's sequence, shown so you can adapt it.** We drive it from
> GitHub Actions; you can run it by hand, from your own CI (Cloud Build,
> GitLab, Jenkins) or from a GitOps tool. The tooling is your choice. The
> *ordering constraints* are not:
>
> 1. CRDs and namespaces before anything that uses them.
> 2. RBAC applied out-of-band by an admin identity (the deploy identity
>    should not hold `roles.update`).
> 3. Secrets and JWT keys created by script before the first apply; never
>    committed to the overlay.
> 4. DB migration gate before the workloads that need the new schema.
> 5. Diff before apply, using the same field manager for both.
> 6. JWT public-key sync **immediately after** every apply, before restarts
>    or verification.
> 7. NetworkPolicy verification, then the rollout gate.
>
> If you use Argo CD / Flux instead of the scripts, map steps 2–6 onto
> pre-sync/post-sync hooks. Evenfire has not validated GitOps tooling against
> this sequence, so treat that mapping as yours to test on a non-production
> cluster first. Approvals, environments and branch protection are also
> yours to define; we recommend a manual approval on the production apply.

Everything runs from the root of the assembled tree
([02](02-assembly-and-overlay-structure.md)) with:

```bash
export CONTEXT="gke_<GCP_PROJECT_ID>_<ZONE>_<CLUSTER_NAME>"
export OVERLAY_NAME=<OVERLAY_NAME>
OV=deploy/overlays/$OVERLAY_NAME
```

The order below is the one Evenfire's CD executes (for an existing cluster)
with the one-time bootstrap steps added in front. Do not reorder: each step's
preconditions are checked by the next script and the failure modes are listed
in [08](08-troubleshooting-and-gotchas.md).

## Phase A — one-time bootstrap (admin identity)

| # | Step | Command |
|---|---|---|
| A1 | Namespaces + CRDs | `kubectl --context "$CONTEXT" apply -f deploy/base/namespaces.yaml && helm upgrade --install --kube-context "$CONTEXT" clerum-crds ./charts/clerum-crds && kubectl --context "$CONTEXT" apply -f ./charts/clerum-crds/crds/` |
| A2 | `ingress` namespace (always, before A3) | `kubectl --context "$CONTEXT" create ns ingress --dry-run=client -o yaml \| kubectl --context "$CONTEXT" apply -f -` — `bootstrap-rbac.sh` applies a Role into it even when you do not use Cloudflare; with `base/ingress` in the render the apply later adopts the namespace and adds its labels |
| A3 | RBAC | `CONTEXT="$CONTEXT" bash deploy/scripts/bootstrap-rbac.sh` |
| A4 | Keys — **once, never again on this cluster** | `gen-jwt-keys.sh` with the bcrypt hash from `getpass`, back up `control-api-secrets`, then patch the Postgres password — all three as written in [06](06-secrets-keys-rbac-crds.md#generating-the-keys--bootstrap-only-once) (re-running the generator later destroys the data-encryption keys) |
| A4b | Inter-service tokens — first run | `CONTROL_API_MEMBER_REGISTRATION_HMAC_SECRET=$(openssl rand -hex 32) CONTEXT="$CONTEXT" bash deploy/scripts/apply-inter-service-tokens.sh` — the only run that carries the env var: without it and without a stored value the script stops with `CONTROL_API_MEMBER_REGISTRATION_HMAC_SECRET is required ...`; with it on a later run it **rotates** the stored value ([06](06-secrets-keys-rbac-crds.md#inter-service-tokens)) |
| A5 | LLM keys and channel Secret | create `mcp-host/chatllm-api-keys` and, if you use a chat channel, `channels/cc-default-channel-credentials` + the `credentialsSecretRef` line in `instances/communicationchannel.yaml` ([06](06-secrets-keys-rbac-crds.md#channel-credentials)) |
| A6 | CIDRs | `CONTEXT="$CONTEXT" OVERLAY_DIR=$OV bash $OV/scripts/detect-k8s-api-ip.sh`; commit |
| A7 | Render gate | `grep -rn '<[A-Z_]*>' $OV --include='*.yaml'` prints nothing; `kubectl kustomize $OV > /tmp/rendered.yaml`; both linters pass ([02](02-assembly-and-overlay-structure.md)) |

## Phase B — every deploy (first install and upgrades)

| # | Step | Command / note |
|---|---|---|
| B1 | Inter-service tokens | `CONTEXT="$CONTEXT" bash deploy/scripts/apply-inter-service-tokens.sh` and `CONTEXT="$CONTEXT" bash deploy/scripts/apply-workflow-approval-bot-secret.sh` — **no env vars**: the script reads every token back from the Secrets, and an env var would override (rotate) the stored value. The HMAC was supplied once in A4b |
| B2 | DB migration gate | `CONTEXT="$CONTEXT" ALLOWED_CONTEXTS="$CONTEXT" bash deploy/scripts/run-control-api-db-migration.sh --overlay $OV` — applies the Postgres prerequisites from the render (SA, ConfigMap, PVC, Deployment, Service), waits for Postgres, verifies the referenced Secrets exist, runs `node dist/migrate.js` from the **rendered** control-api image as a Job, then asserts the schema and the runtime-role privilege contract |
| B3 | Runtime DB roles | `CONTEXT="$CONTEXT" ALLOWED_CONTEXTS="$CONTEXT" bash deploy/scripts/provision-control-api-runtime-roles.sh` (idempotent; mandatory on first install, harmless later) |
| B4 | Recreate-strategy repair | only when upgrading from a release where `control-api`, `control-postgres` or `host-context-controller` were `RollingUpdate`: patch `spec.strategy.rollingUpdate` to null first, or `kubectl diff` exits 2 (see [08](08-troubleshooting-and-gotchas.md)) |
| B5 | Render + strip RBAC | render to `/tmp/rendered.yaml`; produce `/tmp/deploy.yaml` without `Role/ClusterRole/RoleBinding/ClusterRoleBinding` (snippet below) |
| B6 | **Diff** | `kubectl --context "$CONTEXT" diff --server-side --force-conflicts --field-manager=clerum-kustomize -f /tmp/deploy.yaml; echo "rc=$?"` — `0` no drift, `1` drift (expected; read it), anything else is a **real error** |
| B7 | **Apply** | `kubectl --context "$CONTEXT" apply --server-side --force-conflicts --field-manager=clerum-kustomize -f /tmp/deploy.yaml` |
| B8 | JWT key sync — **immediately** (upgrades only) | `GFS_REMOTE_RECONCILE_AUTHORIZED=true ALLOWED_CONTEXTS="$CONTEXT" bash scripts/minikube/sync-auth-key.sh --context "$CONTEXT"`. On a **first install skip this step**: B10 syncs the key before it applies the instances that create the consumers. |
| B9 | Verify NetworkPolicies | `bash deploy/scripts/verify-networkpolicies.sh --overlay $OVERLAY_NAME --context "$CONTEXT"` |
| B10 | GFS + instances | `ALLOWED_CONTEXTS="$CONTEXT" bash deploy/scripts/provision-gfs-runtime.sh --context "$CONTEXT" --overlay $OV` — **first install:** run exactly like that (it syncs the auth key into `mcp-host-config` and `gfs-config`, applies `$OV/instances/`, waits for HCC, finalises the gfsc DB credentials, waits for `GlobalFileSystem/gfs` Ready). **Upgrades:** add `--skip-auth-sync` (B8 already did it; this is what Evenfire's CD runs) and optionally `--skip-instances` if you manage instances by hand. `--allow-prod` is an alternative to `ALLOWED_CONTEXTS` for the same context |
| B11 | Restart ConfigMap consumers | Run the ordered B11 snippet below: restart the gateways/approval reader, restart and wait for **both subscription proxies**, then restart Control API. ConfigMaps mounted via subPath or envFrom do not update the running process automatically |
| B12 | Re-apply tokens | `CONTEXT="$CONTEXT" bash deploy/scripts/apply-inter-service-tokens.sh` — the base re-applied a placeholder `webhook-proxy-secrets` value in B7; this restores the real token and rolls the consumers that read tokens at startup |
| B13 | **Rollout gate** (last; fail-closed) | `CONTEXT="$CONTEXT" RENDER=/tmp/rendered.yaml bash $OV/scripts/rollout-gate.sh` — exit 0 is the only success; semantics below |
| B14 | NetworkPolicy pre-flight (first install; again after any CNI or control-plane change) | `OVERLAY=$OVERLAY_NAME CONTEXT="$CONTEXT" bash deploy/scripts/np-enforce-preflight.sh`. It exits 1 even when healthy: the expected result is exactly one FAIL, `[3] llm-hooks: no NetworkPolicy allows TCP/UDP 53 ...` (sealed by design), and check [0]'s verdict is meaningless on Dataplane V2. Any other FAIL is real; how to read each line is in [04](04-network-policies-and-cni.md#pre-flight-check-after-the-first-full-deploy) |

B5 snippet (same as Evenfire's CD):

```bash
kubectl kustomize "$OV" > /tmp/rendered.yaml
python3 - <<'EOF'
import re
rbac = {'Role','ClusterRole','RoleBinding','ClusterRoleBinding'}
src = open('/tmp/rendered.yaml').read(); out = []
for doc in re.split(r'^---$', src, flags=re.MULTILINE):
    if not doc.strip(): continue
    for line in doc.strip().splitlines():
        if line.startswith('kind:'):
            if line.split(':',1)[1].strip() not in rbac: out.append(doc.strip())
            break
open('/tmp/deploy.yaml','w').write('\n---\n'.join(out) + '\n')
EOF
echo "deployable: $(grep -c '^kind:' /tmp/deploy.yaml) of $(grep -c '^kind:' /tmp/rendered.yaml)"
```

B11 — run in a Bash subshell so a failed proxy restart or readiness wait
stops the sequence before Control API is restarted with the enabled gates:

```bash
(
  set -euo pipefail
  : "${CONTEXT:?set CONTEXT to your kube-context}"
  for d in nginx-workflow-approval-gateway host-context-controller-api-gateway control-api-rpc-gateway; do
    kubectl --context "$CONTEXT" -n control-plane rollout restart "deployment/$d"
  done
  kubectl --context "$CONTEXT" -n channels rollout restart deployment/clerum-workflow-approval-request-reader
  for d in grok-llm-proxy codex-llm-proxy; do
    kubectl --context "$CONTEXT" -n control-plane rollout restart "deployment/$d"
    kubectl --context "$CONTEXT" -n control-plane rollout status "deployment/$d" --timeout=300s
  done
  kubectl --context "$CONTEXT" -n control-plane rollout restart deployment/control-api
)
```

Do not continue to B12 after a failed B11. The final B13 gate still verifies
Control API and every other gating Deployment. HCC-owned Host pods load
`mcp-host-config` when created; this sequence does not restart the Host fleet.
Verify upgraded Hosts after their per-Host recreation or stateless wake
([10](10-feature-defaults.md#adopting-the-profile-on-an-existing-install)).

B13 — what [rollout-gate.sh](overlay-template/scripts/rollout-gate.sh) does
(the semantics of Evenfire's CD gate, derived from the render instead of a
hand-maintained list):

- **Expected inventory** = every `Deployment` in `/tmp/rendered.yaml`
  (so `webhook-ingress/webhook-proxy`, `mcp-server/mcp-proxy` and, when you
  enable `base/ingress`, `ingress/cloudflared` are in it automatically) plus
  the runtime Deployments your instances create (`EXTRA`, default
  `gfs/gfsc-writer gfs/gfsc-reader`). An unreadable or empty render, a
  namespace that cannot be listed, or an expected Deployment that is **missing**
  each fail the gate.
- **Gating** = the expected inventory plus every other live Deployment in
  `channels control-plane gfs mcp-host profiles rpc-proxy webhook-ingress
  ingress` (per-Host agents and `channel-reader-<host>` land here).
  `rollout status --timeout=300s` each; `host-context-controller` gets
  `1500s` because it answers 503 on `/ready` until its first full fleet
  reconciliation. A Deployment HCC holds at `replicas: 0` (a suspended
  stateless Host, a `channel-reader-<host>` with no channel) has nothing to
  wait for and passes `rollout status` at once; one that is waking (0 -> 1)
  during the gate is waited for like any other.
- **Non-gating** = Deployments in `mcp-server` (third-party MCP servers) and
  `sandbox-recipes` (WRC per-recipe workloads) that the render does not own:
  checked with a 60 s timeout and reported, never failing the gate. Their
  failures belong to the recipe or server, not to the platform deploy.
- Prints a summary and exits **1 on any failure**, 0 only when every gating
  Deployment rolled out. `set -euo pipefail`; no error is swallowed in a
  command substitution.

Run it from the assembled tree after B12. Override the lists with the
`EXTRA`, `GATING_NAMESPACES`, `NONGATING_NAMESPACES`, `TIMEOUT`,
`HCC_TIMEOUT` env vars if you add platform namespaces.

**HCC-spawned Deployments and the 300 s timeout.** Per-Host agent pods
(`mcp-host`) and `channel-reader-<host>` (`channels`) are gated with the same
`TIMEOUT` as the platform, but after a deploy an agent can flap for ~6 min
([08](08-troubleshooting-and-gotchas.md#pods), `workflow_auth_refresh` 401/429
row), and a Host whose model key or image is wrong stays unready forever —
either reddens every deploy. Two overrides, pick by what you want the gate
to mean:

- `TIMEOUT=420s` covers the self-heal window; it lengthens the wait for
  **every** gating Deployment (the variable is global), and a genuinely
  broken Host still fails the gate — which is the point if the Hosts are
  platform-owned.
- `GATING_NAMESPACES="control-plane gfs profiles rpc-proxy webhook-ingress ingress"
  NONGATING_NAMESPACES="mcp-host channels mcp-server sandbox-recipes"`
  makes HCC-spawned Deployments report-only (`WARN`, exit stays 0) while
  everything the render owns stays gating — including
  `channels/clerum-workflow-approval-request-reader`, because the expected
  inventory is always gating regardless of namespace lists. The trade-off:
  a Host broken by the deploy no longer fails it, so check the Hosts
  separately (C3). **Move** the two namespaces, never just drop them: a
  namespace in neither list is not listed at all, and its rendered
  Deployments would be reported `MISSING`.

Evenfire proved the script's exit codes against a stubbed `kubectl` (all
healthy -> 0; one gating rollout failed -> 1; one expected Deployment missing
-> 1; namespace listing fails -> 1; render missing / empty / without a
Deployment -> 1; only a non-gating Deployment failed -> 0; a YAML-quoted
`name:` in the render matched against the live object -> 0; a failing
per-Host Deployment in `mcp-host` -> 1 by default and 0 with the namespaces
moved to `NONGATING_NAMESPACES`; `TIMEOUT=420s` reaching every
`rollout status` call).

Why server-side apply with a fixed field manager: fields absent from the
render are reclaimed on every apply, so hand edits do not survive — the
overlay is the single writer. Keep the manager name identical between diff
and apply or the preview lies.

## Phase C — first-install only, after B

| # | Step |
|---|---|
| C1 | Claim the admin account over a port-forward ([06](06-secrets-keys-rbac-crds.md)) **before** publishing DNS |
| C2 | Smoke test through port-forwards: `kubectl --context "$CONTEXT" -n control-plane port-forward svc/control-ui 3000:3000` -> log in at `http://localhost:3000`; `svc/external-rest-api 8091:8091` -> `curl -s localhost:8091/health`; `svc/rpc-proxy 8094:8094` -> `curl -s localhost:8094/health` |
| C3 | Check the Host: `kubectl --context "$CONTEXT" -n mcp-host get host,deploy,pods` — a Deployment per Host and a `channel-reader-<host>` in `channels` (`0/0` until a `CommunicationChannel` references the Host; that is HCC's doing, not a failure). A Host with `spec.lifecycle.stateless: true` also shows `0/0` and no pod while `status.lifecycle.state` is `suspended` ([01](01-architecture-and-namespaces.md#the-two-controllers)) |
| C3b | Chat channel, if any: `kubectl --context "$CONTEXT" -n channels get communicationchannel default-channel -o jsonpath='{.spec.credentialsSecretRef.name}'` prints the Secret you created in A5 (or set it now from the Control UI, [06](06-secrets-keys-rbac-crds.md#channel-credentials)); the reader's log shows the Telegram adapter initialising. Without the reference the reader is Ready and silent |
| C4 | Publish the edge ([03](03-ingress-and-hostnames.md)) and re-test the five hostnames from outside: `curl -sSI https://api.<BASE_DOMAIN>/health` -> 200; `https://app.<BASE_DOMAIN>` -> your SSO or the login page |
| C5 | Invite a first member from the Control UI (exercises hosted registration) and connect the Desktop App |
| C6 | Snapshot: export every generated Secret and ConfigMap in the [06](06-secrets-keys-rbac-crds.md#secret-and-key-inventory) table to your secret manager, as `-o json` and all at the same moment — `control-api-secrets` first, its encryption keys cannot be regenerated ([06](06-secrets-keys-rbac-crds.md#backup)); take a PD snapshot of the Postgres disk |
| C7 | Prove enforcement, then confirm it to WRC: run the three probes in [04](04-network-policies-and-cni.md#post-apply-verification) (DNS resolves, deny probe prints `BLOCKED`, no HCC API timeouts) on **this** cluster. Only then set `CLERUM_NETWORK_POLICY_ENFORCEMENT_CONFIRMED` to `"true"` in `$OV/patches/dynamic-images.yaml`, re-render and run Phase B as for an upgrade (B6 diff: that env change on `workflow-recipes` plus the expected JWT ConfigMap lines; B7 applies; B8 syncs), and commit. Until then WRC refuses every recipe whose MCP servers declare external egress |
| C8 | Connect the plugin registry: as an admin, **Control UI -> Marketplace -> Connect**, enter an organization name and contact email. No Evenfire-issued credentials; requires the two registry keys in `configmaps/control-api-config.yaml` (template default) |
| C9 | Connect a subscription: **Secrets -> LLM Subscriptions**, sign in with ChatGPT or Grok, sync the model catalog, then assign the connection and a model to an agent or recipe. ENV activation does not create a connection ([10](10-feature-defaults.md#connect-subscriptions)) |
| C10 | Verify EvenDrive: open **Files -> EvenDrive**, list the root folder, upload and download a small file, then upload a multi-chunk file within the 200 MiB product limit. Confirm `GlobalFileSystem/gfs` is `Ready` and the generated writer declares `GFS_UPLOAD_V2_ENABLED=true` ([10](10-feature-defaults.md#evendrive)) |

## Health checks worth scripting

```bash
kubectl --context "$CONTEXT" get deploy -A --no-headers | grep -vE 'kube-system|gke-' | awk '{split($3,r,"/"); if (r[1]!=r[2]) print}'   # any non-ready (0/0 is fine)
kubectl --context "$CONTEXT" get pods -A | grep -E 'CreateContainerConfigError|CrashLoop|ImagePull'
kubectl --context "$CONTEXT" -n gfs get globalfilesystem gfs -o jsonpath='{.status.phase}'   # Ready
kubectl --context "$CONTEXT" -n mcp-host get cm mcp-host-config -o jsonpath='{.metadata.annotations.clerum\.io/auth-key-applied-sha256}'  # non-empty
bash deploy/scripts/verify-secrets.sh                      # with CONTEXT exported: every secretKeyRef resolves
```

## Upgrades

1. Bump the tag ([05](05-images-registry-and-pinning.md)); re-assemble at the new tag
   (fresh public tree + your unchanged overlay), then run the upstream-drift
   checks in [02 › Keeping the overlay honest](02-assembly-and-overlay-structure.md#keeping-the-overlay-honest-over-time)
   (DNS patch targets, overlay-owned ConfigMaps, new Deployments).
2. A1 (CRDs, re-apply) and A3 (RBAC) again if the release changed them.
3. Phase B in full. Always read the B6 diff: expect the two JWT ConfigMaps to
   show their key being replaced/blanked (B8 restores them — do not "fix" the
   diff), image tags, and whatever the release notes announce.
4. HCC rolls out before WRC by itself (`Recreate` + `replicas: 1`); if WRC
   reports `ExternalEgressReady` not fresh during the window, it is waiting
   for HCC to reconcile existing `McpServer`s — it clears on its own.

### Upgrading from v0.10.0 to v0.11.0

1. **CRDs first (A1), before Phase B.** `mcpservers.clerum.io` gains the
   extended OAuth schema (`spec.oauth.source`, new transition rules);
   `workflowrecipes.clerum.io` changes descriptions only. Until the CRD is
   current the API server prunes the new fields (see [06](06-secrets-keys-rbac-crds.md#crds-first-always)).
   No RBAC, ServiceAccount or namespace change: A3 is not needed.
2. Add `RPC_PROXY_ARTIFACT_DOWNLOAD_TIMEOUT_MS: "300000"` to your
   `configmaps/rpc-proxy-config.yaml` (new in the template). The key is new in
   v0.11.0; unset, rpc-proxy caps each artifact download body at 60 s.
3. Phase B in full. B2 applies the new schema migrations and checks the
   runtime-role privileges they grant; B3 stays where it is. The B6 diff
   shows, besides tags and the JWT ConfigMap lines: `codex-llm-proxy` /
   `grok-llm-proxy` memory limit 2048Mi, a new `grok-llm-proxy-config` key,
   per-route rate limits in `control-api-config`, the approval gateway's
   larger body size and timeouts, and four stateless-Host env vars on
   `host-context-controller` (equal to its code defaults; HCC restarts and
   needs its long first reconcile, as on any image bump). All are base
   defaults: no overlay change. B11 restarts the consumers of those
   ConfigMaps (`grok-llm-proxy` rolls anyway: its Deployment changed).
4. `control-api` must stay `Recreate` (the base default; B4 if your cluster
   still carries `RollingUpdate`): v0.11.0 password verification must not run
   alongside an older control-api. Do not roll control-api back to v0.10.0
   once v0.11.0 has served logins
   (`docs/how-to/password-work-ownership-recovery.md` in the clone).

## Rollback

- Fast: `kubectl --context "$CONTEXT" -n <ns> rollout undo deploy/<name>` for
  the failing Deployment (Evenfire's CD does exactly this, targeted, for HCC
  when its rollout gate fails, then still marks the deploy failed). The overlay
  now disagrees with the cluster — fix the overlay next.
- Correct: revert the overlay to the previous tag and run Phase B again.
  There are no down-migrations: the older control-api runs against the newer
  schema, and some releases rule that out (see the upgrade notes above).
  Images for the previous tag must still exist in your registry (they do, on
  the public registry; keep them if you mirror).
- Postgres schema migrations are forward-only; a rollback to a release whose
  image predates a migration is **not** supported without a DB restore.

## Adopting CI

Evenfire deploys with GitHub Actions and Workload Identity Federation into a
dedicated deploy service account (`roles/container.developer`, no RBAC
rights); any CI that can hold a kubeconfig works the same way. The job order
is exactly Phase B. What we recommend you add around it: a `diff` mode that
is read-only and ungated; an `apply` mode that you bind to a manual approval
(required reviewers on a CI environment, a protected branch — the mechanism
is yours; the point is that an apply cannot be dispatched by one person
without a second look); a pre-checkout gate proving the requested commit/tag
is reachable from the public release branch (so a pasted sha cannot deploy
unmerged code); a CRD schema guard; a pre-apply rollout baseline so
pre-existing failures in non-core namespaces are not blamed on the deploy;
and a commit-back step that records the deployed tag in the overlay repo on
every apply attempt. Secrets for CI: only the WIF provider and SA; the
platform secrets never pass through CI (they are read back from the cluster
by the scripts).
