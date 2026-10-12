# 06 — Secrets, keys, RBAC and CRDs

Four things are deliberately **outside** the Kustomize apply: CRDs, RBAC,
Secrets and the JWT public-key sync. Each has a reason and a script.

## CRDs (first, always)

```bash
kubectl --context "$CONTEXT" apply -f deploy/base/namespaces.yaml
helm upgrade --install --kube-context "$CONTEXT" clerum-crds ./charts/clerum-crds
kubectl --context "$CONTEXT" apply -f ./charts/clerum-crds/crds/      # Helm 3 never upgrades crds/
```

Nine CRDs in `clerum.io/v1alpha1` ([01](01-architecture-and-namespaces.md)).
On upgrades the safe order is **CRD -> control-api -> control-ui**: until the
CRD declares a new field the API server silently prunes it on every write.
Evenfire's CD has a guard that compares the cluster's CRD *schema* with the
chart's and fails an apply on mismatch; do the same check yourself before
each release:

```bash
for f in charts/clerum-crds/crds/*.yaml; do
  kubectl --context "$CONTEXT" diff -f "$f" >/dev/null 2>&1 && echo "ok   $f" || echo "DIFF $f"
done
```

## RBAC — applied out-of-band with an admin identity

Evenfire's deploy identity intentionally lacks the permission to patch
Roles/RoleBindings (so CD can never escalate itself). Consequently the
rendered overlay is **stripped of** `Role`, `ClusterRole`, `RoleBinding`,
`ClusterRoleBinding` before diff/apply, and RBAC is applied by an operator:

```bash
kubectl --context "$CONTEXT" get ns ingress >/dev/null 2>&1 || kubectl --context "$CONTEXT" create ns ingress
CONTEXT="$CONTEXT" bash deploy/scripts/bootstrap-rbac.sh
```

- It finds every `rbac.yaml`, `clusterroles.yaml`, `clusterrolebindings.yaml`
  under `deploy/base` — including `base/ingress/rbac.yaml`, which is why the
  `ingress` namespace must exist even without Cloudflare.
- Re-run it after **every release** whose diff touches those files; a
  stripped apply never updates them, and a pod with a missing permission
  fails at runtime, not at apply time.
- RBAC defined *inline* in a workload manifest (not in those file names) is
  not picked up; render and select by kind if a release introduces one.
- Its production guard is a substring rule on `CONTEXT`: a name that contains
  `clerum` and none of `example-dev`, `clerum-test`, `minikube`, `kind` is
  treated as production, and the script exits with `Refusing to bootstrap
  RBAC in prod context ...` unless `CONFIRM=yes` is set. If your context does
  not contain `clerum` the guard never fires; if it does, pass `CONFIRM=yes`.
  There is no other override.
- Always set `CONTEXT`: when it is empty this script (like several others)
  falls back to the current kubeconfig context.
- If you run with cluster-admin for everything you may skip the stripping and
  apply RBAC inline — but you lose the separation; Evenfire recommends keeping it.

The optional [rbac-e2e-compat.yaml](overlay-template/rbac-e2e-compat.yaml)
binds the base Role `e2e-compat-networkpolicy-reader` to your deploy identity
so a non-admin CI can run `verify-networkpolicies.sh`.

## The canary pattern (why `kubectl apply` never wipes a Secret)

Base ships Secrets with `stringData: {}` (`control-api-internal-tokens`,
`internal-control-jwt-secrets`, `codex-llm-proxy-secrets`,
`grok-llm-proxy-secrets`, `workflow-approval-request-reader-credentials`,
`cloudflared-credentials`) or with the key simply absent
(`control-api-postgres-runtime`, `trace-maintenance-postgres-runtime`,
`workflow-recipes-postgres-runtime`, `gfs-controller-db`,
`gfs-controller-reader-db`). Scripts fill them with **`kubectl patch --type=merge`**,
which writes outside the `last-applied-configuration` envelope: the next apply
sees the empty canary as desired state and leaves the real values alone. Never
convert one of these to `kubectl create ... | kubectl apply` and never add
real values to the overlay — both reintroduce wipe-on-apply.

## Secret and key inventory

| Secret / ConfigMap (namespace) | Created by | Keys | Consumer |
|---|---|---|---|
| `control-api-secrets` (control-plane) | `gen-jwt-keys.sh` | session/RPC/admin RSA-4096 private keys, admin bootstrap hash, OAuth state HMAC, **two data-encryption keys** (`CONTROL_API_OAUTH_ENCRYPTION_KEY`, `TRACING_APPROVAL_PROMPT_HISTORY_ENCRYPTION_KEY` — see [Key rotation](#key-rotation-key-by-key)) | control-api |
| `control-ui-secrets` (control-plane) | `gen-jwt-keys.sh` | CSRF secret | control-ui |
| `rpc-proxy-secrets` (rpc-proxy) | `gen-jwt-keys.sh` + `apply-inter-service-tokens.sh` | RPC public key, desktop API token, cookie secrets; control-api service token | rpc-proxy |
| `external-rest-api-secrets` (profiles) | `gen-jwt-keys.sh` + `apply-inter-service-tokens.sh` | session public key; control-api service token | external-rest-api |
| `control-postgres` (control-plane) | `gen-jwt-keys.sh` | `POSTGRES_DB/USER/PASSWORD` — **generated as `postgres/postgres`; change it (below)** | control-postgres, migration Job, runtime-roles script |
| `inter-service-tokens` (control-plane) | `gen-jwt-keys.sh` | `desktop-api-token` (+ legacy placeholders) | HCC (desktop pods) |
| `clerum-wrc-signing-key` (control-plane) + ConfigMap `clerum-wrc-public-key` (control-plane, sandbox-recipes) | `gen-jwt-keys.sh` | WRC RSA pair; public half for workflow pods | WRC, workflow mcp-hosts |
| ConfigMap `control-api-public-key` (control-plane) | `gen-jwt-keys.sh` | admin JWT public key | WRC, HCC, codex/grok LLM proxies (verify control-api-issued tokens) |
| `control-api-internal-tokens` (control-plane) | `apply-inter-service-tokens.sh` | `CONTROL_API_INTERNAL_SERVICE_TOKENS` map, `CONTROL_API_INTERNAL_TOKENS`, `CONTROL_API_MEMBER_REGISTRATION_HMAC_SECRET` | control-api |
| `internal-control-jwt-secrets` (control-plane) | `apply-inter-service-tokens.sh` | HMAC secrets for the WRC and HCC InternalControl issuers | control-api, WRC, HCC |
| `webhook-proxy-secrets` (webhook-ingress), `codex-llm-proxy-secrets`, `grok-llm-proxy-secrets` (control-plane), `workflow-approval-request-reader-credentials` (channels) | `apply-inter-service-tokens.sh` (+ `apply-workflow-approval-bot-secret.sh` for the Telegram webhook secret) | per-service tokens | the named service |
| `control-api-postgres-runtime`, `trace-maintenance-postgres-runtime`, `workflow-recipes-postgres-runtime` (control-plane) | `provision-control-api-runtime-roles.sh` | `connection-string` DSN for least-privilege DB roles the migrations created | control-api, trace-maintenance-worker, WRC |
| `gfs-controller-db`, `gfs-controller-reader-db` (gfs) | `provision-gfs-runtime.sh` (via the GFS credential scripts) | `connection-string` | gfsc writer / reader |
| ConfigMap `mcp-host-config.CLERUM_AUTH_JWT_PUBLIC_KEY` (mcp-host), ConfigMap `gfs-config.jwt-public-key` (gfs) | `sync-auth-key.sh` **after every apply** | RPC public key copy | every agent pod, gfsc |
| `chatllm-api-keys` (mcp-host) | you | `openai-api-key`, `claude-api-key`, `zai-api-key`, `bailian-api-key`, `vertex-service-account-json` (any subset) | agent pods via the Host's `secretRef`; mapped by the base `clerum-model-secret-mapping` ConfigMap |
| per-channel `cc-<channel>-credentials` (channels) — or any Secret you name in the CR | you (kubectl), or Control UI / `PUT /api/v1/admin/communication-channels/<name>/credentials` ([below](#channel-credentials)) | `telegram-bot-token`, `slack-bot-token`, `slack-signing-secret`, `teams-app-password`, `email-username`, `email-password` | the Host's channel-reader, via `CommunicationChannel.spec.credentialsSecretRef` |
| `cloudflared-credentials` (ingress) | you (Cloudflare option) | `credentials.json` | cloudflared |

### Handling secret values in this guide

Every command below keeps secret values out of process arguments (visible in
`ps` and shell history) and out of the `kubectl.kubernetes.io/last-applied-configuration`
annotation (which `kubectl apply` writes with a full copy of the object):

- values are typed with `read -rs` or generated into files under a
  `umask 077` temp directory, and passed with `--from-file`, `--patch-file`
  or `curl --data @file`;
- first creation uses `kubectl create secret` (writes no annotation), later
  changes use `kubectl patch --type=merge --patch-file`; never
  `kubectl apply` a Secret;
- the temp directory is removed right after (`rm -rf "$D"`; use `shred -u`
  on Linux or `rm -P` on macOS where your policy requires overwriting) and
  the shell variable is `unset`.

Check any Secret you created by hand carries no copy of itself (prints nothing):

```bash
kubectl --context "$CONTEXT" -n mcp-host get secret chatllm-api-keys \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}'
```

(The public bootstrap scripts, `gen-jwt-keys.sh` included, write their
Secrets with `create --dry-run | apply` on your workstation, so *those*
Secrets do carry the annotation; the check applies to Secrets you create.)

### Generating the keys — bootstrap only, once

```bash
# strong admin bootstrap hash (otherwise a non-bcrypt placeholder is written);
# needs the non-stdlib bcrypt package (python3 -m pip install bcrypt) — or use
# the htpasswd line instead (prompts twice; `$2y$` is accepted by control-api)
ADMIN_HASH=$(python3 -c 'import bcrypt,getpass; print(bcrypt.hashpw(getpass.getpass("admin password: ").encode(), bcrypt.gensalt(12)).decode())')
# ADMIN_HASH=$(htpasswd -nBC 12 '' | cut -d: -f2)
ADMIN_BOOTSTRAP_PASSWORD_HASH="$ADMIN_HASH" CONTEXT="$CONTEXT" bash deploy/scripts/gen-jwt-keys.sh
unset ADMIN_HASH
```

Either form keeps the password off the command line; control-api verifies
`$2a$`, `$2b$` and `$2y$` hashes alike. The hash is consumed once, by the
baseline schema migration that seeds the admin row.

`gen-jwt-keys.sh` is a **bootstrap generator, not a rotation tool**. Every
run regenerates *everything* it owns: the four RSA pairs, the desktop/cookie
secrets, the `control-postgres` password (back to `postgres/postgres`) — and
the two **data-encryption keys** in `control-api-secrets`. Those encrypt
records in Postgres (OAuth grants, dynamically registered OAuth clients,
the Marketplace/registry connection keypair, the hosted-registration
credential, LLM subscription connections, approval prompt history); with a new key that ciphertext is unreadable, and
v0.11.0 ships no re-encryption. **Never re-run it on a cluster that has
data.** Rotate individual keys with the per-key procedures under
[Key rotation](#key-rotation-key-by-key). If `mcp-host-config` does not exist
yet (first install, before the overlay apply) it prints a warning; the sync
after the apply covers it. The generator passes values on its own command
line internally; run it from a workstation you control.

**Back up `control-api-secrets` immediately** — its encryption keys cannot be
regenerated, and losing them loses every stored credential listed above:

```bash
umask 077; D=$(mktemp -d)
kubectl --context "$CONTEXT" -n control-plane get secret control-api-secrets -o json > "$D/control-api-secrets.json"
# upload $D/control-api-secrets.json to your secret manager (it holds private keys), then:
rm -rf "$D"
```

JSON, so the [recovery](#recovery-after-an-accidental-re-run-of-gen-jwt-keyssh)
patches can be cut from it with `jq`. Do the same for every `gen-jwt-keys.sh`
Secret and ConfigMap in the table once the install is complete (step C6 in
[07](07-deploy-sequence-and-verification.md)).

Immediately after the first run, before Postgres has ever started, replace
the generated DB password (store it in your secret manager first):

```bash
PGPASS=$(openssl rand -hex 24)
PGPASS="$PGPASS" jq -n '{stringData:{POSTGRES_PASSWORD:env.PGPASS}}' | \
  kubectl --context "$CONTEXT" -n control-plane patch secret control-postgres --type=merge --patch-file /dev/stdin
unset PGPASS
```

(`jq` reads the value from its environment, so it never appears in a process
argument list and is JSON-escaped. The Postgres image initialises the
superuser password from this Secret on first start with an empty PVC.
Changing it later requires `ALTER USER` inside the database as well.)

### Inter-service tokens

**First run only** — outside minikube the script **fails closed** without a
member-registration HMAC (`ERROR: CONTROL_API_MEMBER_REGISTRATION_HMAC_SECRET
is required when no existing control-api Secret value is present`); hosted
invitation mode ignores the value, but it must exist:

```bash
CONTROL_API_MEMBER_REGISTRATION_HMAC_SECRET=$(openssl rand -hex 32) \
  CONTEXT="$CONTEXT" bash deploy/scripts/apply-inter-service-tokens.sh
CONTEXT="$CONTEXT" bash deploy/scripts/apply-workflow-approval-bot-secret.sh
```

**Every later run** — no env vars:

```bash
CONTEXT="$CONTEXT" bash deploy/scripts/apply-inter-service-tokens.sh
CONTEXT="$CONTEXT" bash deploy/scripts/apply-workflow-approval-bot-secret.sh
```

- Each token is resolved env var -> existing Secret -> freshly generated. An
  env var therefore **wins over the stored value**: passing
  `CONTROL_API_MEMBER_REGISTRATION_HMAC_SECRET` (or any `CONTROL_API_INTERNAL_TOKEN_*`
  override) on a later run rotates that token. Without env vars re-runs never
  rotate anything.
- Re-run it **after every overlay apply**: the base re-applies a placeholder
  `webhook-proxy-secrets` value, and the script also rolls the consumers that
  read tokens at startup.

### Runtime database roles

After the migration Job has run (it creates the roles) and before control-api
rolls out:

```bash
CONTEXT="$CONTEXT" ALLOWED_CONTEXTS="$CONTEXT" bash deploy/scripts/provision-control-api-runtime-roles.sh
```

It waits for `control-postgres`, sets a password on `control_api_runtime`,
`trace_maintenance_runtime` and `workflow_recipes_runtime` (preserving an
existing valid one), and patches the three `*-postgres-runtime` Secrets with
DSNs. Without it `control-api`, `trace-maintenance-worker` and
`workflow-recipes` sit in `CreateContainerConfigError` (missing Secret key).

### JWT public-key sync (after every apply)

The overlay apply resets `mcp-host-config.CLERUM_AUTH_JWT_PUBLIC_KEY` and
`gfs-config.jwt-public-key` to their committed (empty) values. Immediately
after **every** apply:

```bash
GFS_REMOTE_RECONCILE_AUTHORIZED=true ALLOWED_CONTEXTS="$CONTEXT" \
  bash scripts/minikube/sync-auth-key.sh --context "$CONTEXT"
```

The two env vars are the script's explicit authorisation for a non-local
context (it refuses remote clusters otherwise). It copies the key from
`rpc-proxy-secrets`, restarts the ConfigMap consumers, and records a
`clerum.io/auth-key-applied-sha256` annotation only after the consumers prove
they loaded it. `provision-gfs-runtime.sh` runs the same sync itself (with
`--require-gfs`) unless you pass `--skip-auth-sync`. The split used in
[07](07-deploy-sequence-and-verification.md): on a **first install** let
`provision-gfs-runtime.sh` do the sync (it syncs the key *before* it applies the
instances that create the consumers, so the first pods start with it);
on **upgrades** run the direct sync immediately after the apply and pass
`--skip-auth-sync` to the GFS script, which is what Evenfire's CD does.

### LLM keys and the first Host

One file per key, file name = Secret key; include only the providers you have
(agent pods read the Secret through the API, so absent keys are fine, but the
key mapped for the Host's `model.provider` must exist):

```bash
umask 077; D=$(mktemp -d)
read -rsp 'OpenAI API key: ' K; printf '%s' "$K" > "$D/openai-api-key"; unset K; echo
read -rsp 'Anthropic API key (empty to skip): ' K; [ -n "$K" ] && printf '%s' "$K" > "$D/claude-api-key"; unset K; echo
kubectl --context "$CONTEXT" -n mcp-host create secret generic chatllm-api-keys --from-file="$D"
rm -rf "$D"
```

Add or rotate a single key later with a merge patch built the same way
(`jq --rawfile` reads the value from the file and JSON-escapes it; it is
never typed on a command line):

```bash
umask 077; D=$(mktemp -d); read -rsp 'new key: ' K; printf '%s' "$K" > "$D/v"; unset K; echo
jq -n --rawfile v "$D/v" '{stringData:{"claude-api-key":$v}}' | \
  kubectl --context "$CONTEXT" -n mcp-host patch secret chatllm-api-keys --type=merge --patch-file /dev/stdin
rm -rf "$D"
```

Bedrock is not supported through this mapping for workflow recipes.

### Channel credentials

A `CommunicationChannel` carries no token. Its channel-reader resolves
credentials from the Secret named in `spec.credentialsSecretRef.name` (in the
`channels` namespace); without that reference the pod is Ready but starts no
Telegram/Slack/email adapter. Three ways to set it, all ending in the same
object shape:

**a. kubectl, before applying the instance** (fits the install order in
[07](07-deploy-sequence-and-verification.md)):

```bash
umask 077; D=$(mktemp -d)
read -rsp 'Telegram bot token: ' K; printf '%s' "$K" > "$D/telegram-bot-token"; unset K; echo
kubectl --context "$CONTEXT" -n channels create secret generic cc-default-channel-credentials --from-file="$D"
rm -rf "$D"
```

and in `instances/communicationchannel.yaml` uncomment
`credentialsSecretRef: { name: cc-default-channel-credentials }` before
`kubectl apply -f instances/`.

**b. Control UI** (later, or to rotate): *Communication Channels ->* the
channel *-> Edit -> Channel credentials*. control-api creates
`cc-<channel>-credentials` and sets the reference itself; if the CR already
names a Secret, it patches that one.

**c. The same API from a script** — admin session cookie, bodies from files:

```bash
umask 077; D=$(mktemp -d)
read -rsp 'admin password: ' ADMIN_PASSWORD; echo
ADMIN_PASSWORD="$ADMIN_PASSWORD" jq -n --arg u '<ADMIN_USERNAME>' '{username:$u,password:env.ADMIN_PASSWORD}' > "$D/login.json"; unset ADMIN_PASSWORD
read -rsp 'Telegram bot token: ' K; echo
K="$K" jq -n '{"telegram-bot-token":env.K}' > "$D/creds.json"; unset K
kubectl --context "$CONTEXT" -n control-plane port-forward svc/control-api 8090:8090 >/dev/null 2>&1 & PF=$!; sleep 2
curl -sS -c "$D/jar" -X POST http://127.0.0.1:8090/api/v1/admin/auth/login \
  -H 'Content-Type: application/json' --data @"$D/login.json" >/dev/null
curl -sS -b "$D/jar" -X PUT http://127.0.0.1:8090/api/v1/admin/communication-channels/default-channel/credentials \
  -H 'Content-Type: application/json' --data @"$D/creds.json"
kill $PF; rm -rf "$D"
```

The body is a map of the allowed keys listed in the inventory; the response
names the Secret and the keys written, never values. Afterwards:

```bash
kubectl --context "$CONTEXT" -n channels get communicationchannel default-channel \
  -o jsonpath='{.spec.credentialsSecretRef.name}'    # cc-default-channel-credentials
```

HCC stamps a `clerum.io/credentials-revision` annotation on the channel-reader
pod template and rolls it whenever the Secret content changes; no manual
restart. One Secret may serve several channels of the same Host.

## Admin account bootstrap — before any public DNS

The platform exposes `POST /api/v1/admin/auth/setup` on control-api, which is
**unauthenticated until it has been used once**. Claim it over a port-forward
before the UIs are reachable from the internet:

```bash
umask 077; D=$(mktemp -d)
read -rsp 'admin password (8-256 chars): ' ADMIN_PASSWORD; echo
ADMIN_PASSWORD="$ADMIN_PASSWORD" jq -n --arg u '<ADMIN_USERNAME>' --arg e '<ADMIN_EMAIL>' \
  '{username:$u,email:$e,password:env.ADMIN_PASSWORD}' > "$D/setup.json"; unset ADMIN_PASSWORD
kubectl --context "$CONTEXT" -n control-plane port-forward svc/control-api 8090:8090 >/dev/null 2>&1 & PF=$!; sleep 2
curl -sS -X POST http://127.0.0.1:8090/api/v1/admin/auth/setup \
  -H 'Content-Type: application/json' --data @"$D/setup.json"
kill $PF; rm -rf "$D"
```

That creates the admin with a bcrypt hash and (with
`CONTROL_API_DESKTOP_GFS_OPERATOR_LINKING_ENABLED=true`) the linked desktop
workspace. Prefer it over relying on `ADMIN_BOOTSTRAP_PASSWORD_HASH` alone,
which seeds the row but leaves the account without a first-login record.

## SharedFileSystem storage

A `SharedFileSystem` becomes a PVC created by HCC with
`spec.storageClassName` (cluster default when unset) and `spec.accessModes`
defaulting to `ReadWriteOnce`: its `workspace-files-controller` is single-replica
and the consuming agent pods co-locate with it, so the same `<STORAGE_CLASS_RWO>`
class as everything else works. ReadWriteMany classes and bucket-backed
mounts (GKE's Cloud Storage FUSE CSI driver needs a static PV and a pod
annotation HCC does not set) are **not supported in v0.11.0**. Nothing in
the platform needs Workload Identity.

## Backup

- Back up `control-postgres-data` (everything: users, invitations, approvals,
  encrypted OAuth grants, hosted-registration credential) and the GFS PVC.
- Export every Secret and ConfigMap in the table above to your secret manager
  after the first install (the `umask 077` / `-o json` pattern above), all at
  the same moment; `gen-jwt-keys.sh` output cannot be regenerated identically,
  and a database restore is only useful together with the
  `control-api-secrets` that encrypted it.

### Recovery after an accidental re-run of `gen-jwt-keys.sh`

The re-run left a *consistent new* set of signing keys: every private half
**and** its public half were regenerated together (`rpc-proxy-secrets`,
`external-rest-api-secrets`, `control-api-public-key`, both
`clerum-wrc-public-key` ConfigMaps, `mcp-host-config`), so restoring the whole
backed-up `data:` map of `control-api-secrets` would pair *old* private keys
with *new* public keys and break every session, RPC and admin JWT. Restore
**only the two data-encryption keys**, then treat the rest as a rotation of
all signing keys at once:

```bash
umask 077; D=$(mktemp -d)
# 1. $D/control-api-secrets.json = the bootstrap backup, fetched from your secret manager
jq '{data: {CONTROL_API_OAUTH_ENCRYPTION_KEY: .data.CONTROL_API_OAUTH_ENCRYPTION_KEY,
            TRACING_APPROVAL_PROMPT_HISTORY_ENCRYPTION_KEY: .data.TRACING_APPROVAL_PROMPT_HISTORY_ENCRYPTION_KEY}}' \
  "$D/control-api-secrets.json" > "$D/enc.json"
kubectl --context "$CONTEXT" -n control-plane patch secret control-api-secrets --type=merge --patch-file "$D/enc.json"
# 2. the generator reset control-postgres to postgres/postgres; put the real password back
#    (from your secret manager, as when you set it — the database itself still has it)
read -rsp 'Postgres password: ' PGPASS; echo
PGPASS="$PGPASS" jq -n '{stringData:{POSTGRES_PASSWORD:env.PGPASS}}' > "$D/pg.json"; unset PGPASS
kubectl --context "$CONTEXT" -n control-plane patch secret control-postgres --type=merge --patch-file "$D/pg.json"
rm -rf "$D"
# 3. restart every signing-key consumer (the generator only restarted mcp-host);
#    host-context-controller is Recreate and reports Ready only after its fleet
#    reconciliation (15-20 min, see 08) — do not restart it a second time
for d in control-api control-ui workflow-recipes host-context-controller codex-llm-proxy grok-llm-proxy; do
  kubectl --context "$CONTEXT" -n control-plane rollout restart deploy/$d; done
kubectl --context "$CONTEXT" -n rpc-proxy rollout restart deploy/rpc-proxy
kubectl --context "$CONTEXT" -n profiles  rollout restart deploy/external-rest-api
# 4. gfs-config is stale (the generator re-syncs mcp-host-config only)
GFS_REMOTE_RECONCILE_AUTHORIZED=true ALLOWED_CONTEXTS="$CONTEXT" bash scripts/minikube/sync-auth-key.sh --context "$CONTEXT"
```

Then confirm an old record decrypts (open an existing recipe OAuth grant, or
check the Marketplace connection still shows connected; no
`registry_connection_state_unreadable` in the control-api log). Expect the
effects of the signing-key rows in the [rotation table](#key-rotation-key-by-key):
users and admins log in again, running recipe pods lose their tokens. The
Postgres container keeps running with its real password (the image reads the
Secret only when initialising an empty volume), but the migration Job of the
next deploy reads `POSTGRES_PASSWORD` from the Secret, which is why step 2 is
not optional. The regenerated admin bootstrap hash is harmless: the baseline
migration that consumes it already ran. Records written *between* the re-run
and the restore were encrypted with the lost key.

Alternative, only with a complete, simultaneous C6 snapshot: restore the
`data:` map of everything the generator writes — Secrets `control-api-secrets`,
`control-ui-secrets`, `control-postgres`, `inter-service-tokens`,
`clerum-wrc-signing-key` (control-plane), `rpc-proxy-secrets` (rpc-proxy),
`external-rest-api-secrets` (profiles); ConfigMaps `clerum-wrc-public-key`
(control-plane **and** sandbox-recipes) and `control-api-public-key`
(control-plane) — each with `jq '{data: .data}' <snapshot> > patch.json` and
`kubectl patch ... --type=merge --patch-file patch.json` (a merge patch
never deletes keys, so a snapshot predating `apply-inter-service-tokens.sh`
is still safe), then steps 3 and 4 above (the sync restores
`mcp-host-config` from `rpc-proxy-secrets`). Mixing snapshots from
different moments reintroduces the mismatch.

## Key rotation, key by key

Evenfire has not exercised these procedures on its reference cluster; do them
on a non-production cluster first. Two families, with opposite rules:

**Signing keys — rotatable.** New pair with `openssl`, patch the private and
public halves, restart the consumers, users re-authenticate. No stored data
depends on them.

| Key | Private half | Public half | Restart | Effect |
|---|---|---|---|---|
| session RSA | `control-api-secrets.CONTROL_API_SESSION_JWT_PRIVATE_KEY` (control-plane) | `external-rest-api-secrets.EXTERNAL_REST_API_JWT_PUBLIC_KEY` (profiles) | `control-api`, `external-rest-api` | every end-user / Desktop App session invalid; users log in again |
| RPC RSA | `control-api-secrets.CONTROL_API_RPC_JWT_PRIVATE_KEY` | `rpc-proxy-secrets.RPC_PROXY_JWT_PUBLIC_KEY` (rpc-proxy), then **`sync-auth-key.sh`** copies it into `mcp-host-config` / `gfs-config` and rolls agents and gfsc | `control-api`, `rpc-proxy`, then the sync | RPC tokens live 300 s and are re-minted from a valid session; streams reconnect |
| admin RSA | `control-api-secrets.CONTROL_API_ADMIN_JWT_PRIVATE_KEY` | ConfigMap `control-api-public-key.CONTROL_API_PUBLIC_KEY_PEM` (control-plane) | `control-api`, `workflow-recipes`, `host-context-controller`, `codex-llm-proxy`, `grok-llm-proxy` | admins log in again; HCC verifies agent runtime tokens with this key, so agent pods may be unready until HCC re-mints them — **verify** the recovery time on your cluster |
| WRC RSA | `clerum-wrc-signing-key.private.pem` (control-plane) | `clerum-wrc-signing-key.public.pem` **and** ConfigMap `clerum-wrc-public-key.CLERUM_WRC_SIGNING_PUBLIC_KEY` in control-plane and sandbox-recipes | `workflow-recipes`; running recipe pods | in-flight recipe runs lose their tokens: drain running workflows first |
| service tokens | `apply-inter-service-tokens.sh` with the matching env var set (it rolls the consumers) | | | |
| desktop API token | same value in `rpc-proxy-secrets.RPC_PROXY_DESKTOP_API_TOKEN` and `inter-service-tokens.desktop-api-token` | | `rpc-proxy`, `host-context-controller`, desktop Host pods | |
| CSRF / cookie secrets | `control-ui-secrets`, `rpc-proxy-secrets.RPC_PROXY_*_COOKIE_SECRET` | | `control-ui` / `rpc-proxy` | browser sessions re-established |
| `CONTROL_API_OAUTH_STATE_HMAC_SECRET` | `control-api-secrets` | | `control-api` | only OAuth authorizations in flight fail; nothing stored |

Example, the RPC pair (the other pairs differ only in key names):

```bash
umask 077; D=$(mktemp -d)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$D/rpc-private.pem" 2>/dev/null
openssl rsa -in "$D/rpc-private.pem" -pubout -out "$D/rpc-public.pem" 2>/dev/null
python3 - "$D" <<'PY'    # merge patches built from the files; no key on a command line
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
(d / 'priv.json').write_text(json.dumps({"stringData": {"CONTROL_API_RPC_JWT_PRIVATE_KEY": (d / 'rpc-private.pem').read_text()}}))
(d / 'pub.json').write_text(json.dumps({"stringData": {"RPC_PROXY_JWT_PUBLIC_KEY": (d / 'rpc-public.pem').read_text()}}))
PY
kubectl --context "$CONTEXT" -n control-plane patch secret control-api-secrets --type=merge --patch-file "$D/priv.json"
kubectl --context "$CONTEXT" -n rpc-proxy    patch secret rpc-proxy-secrets   --type=merge --patch-file "$D/pub.json"
rm -rf "$D"
kubectl --context "$CONTEXT" -n control-plane rollout restart deploy/control-api
kubectl --context "$CONTEXT" -n rpc-proxy    rollout restart deploy/rpc-proxy
GFS_REMOTE_RECONCILE_AUTHORIZED=true ALLOWED_CONTEXTS="$CONTEXT" bash scripts/minikube/sync-auth-key.sh --context "$CONTEXT"
```

For a ConfigMap half use `{"data": {...}}` instead of `stringData`.

**Data-encryption keys — do not rotate.** Both live in `control-api-secrets`
and v0.11.0 ships no re-encryption or dual-key read:

| Key | Encrypts | Rotating it means |
|---|---|---|
| `CONTROL_API_OAUTH_ENCRYPTION_KEY` (AES-256-GCM) | recipe and MCP server OAuth grants, dynamically registered MCP OAuth client credentials, the Marketplace/registry connection keypair and client secret, the hosted-registration credential, LLM subscription connections and their OAuth state | every one of those records fails to decrypt (control-api logs `registry_connection_state_unreadable` at boot); users re-consent, the registry Connect flow must be redone. Unsupported |
| `TRACING_APPROVAL_PROMPT_HISTORY_ENCRYPTION_KEY` + `TRACING_APPROVAL_PROMPT_HISTORY_KEY_VERSION` (`v1`, ConfigMap `control-api-config`) | captured approval prompts (governed history) | the only knob is bumping the version together with a new key: history captured under the old version reads as `unavailable` — loss by design, not migration |

If a compromise forces a rotation anyway: keep the previous key in your
secret manager, back up `control-api-secrets` and Postgres first, rotate,
restart control-api, and verify what still decrypts before telling users to
re-consent.
