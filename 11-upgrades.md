# 11 — Upgrading an existing install

Use this page when a cluster already runs Evenfire and you are moving it to a
newer release. A first install starts at the [README](README.md#install-path).
Step names (A1, B5, C6, ...) are the steps of the deploy sequence in
[07](07-deploy-sequence-and-verification.md).

## Find where you are

| You need | How |
|---|---|
| the platform release the cluster runs | `kubectl --context "$CONTEXT" -n control-plane get deploy control-api -o jsonpath='{.spec.template.spec.containers[0].image}'` prints the image; its tag is the release (for example `v0.10.0`) |
| the kit tag your overlay came from | the `gke-kit-vX.Y.Z` tag you copied `overlay-template/` from; `NOTICE.md` in that kit checkout names it |
| the target | the newest `gke-kit-vX.Y.Z` tag of this kit, and the platform release its `NOTICE.md` names |

Then read the notes below for every release after yours, up to the target.

## Skipping releases

You can move more than one release in a single upgrade: a v0.10.x cluster can
go straight to v0.12.0. Apply the notes of **every** release in between,
oldest first, as one change:

- **CRDs:** apply them once, from the target release. They include every
  earlier change.
- **Overlay:** compare from the kit tag you installed from to the target,
  for example `git diff gke-kit-v0.10.0 gke-kit-v0.12.0 -- overlay-template/`,
  and make every change the notes mark as required.
- **Phase B:** once, at the target release. B2 applies every schema migration
  in between.
- **Behaviour changes and rollback rules:** those of every release in between
  apply.

[From v0.10.0 to v0.12.0 in one deploy](#from-v0100-to-v0120-in-one-deploy)
puts the two notes together.

## Every upgrade

Before any upgrade, take the C6 snapshot ([06 › Backup](06-secrets-keys-rbac-crds.md#backup)):
Secrets, ConfigMaps and the Postgres disk. A release can run schema
migrations, which rolling the images back does not undo. When the upgrade
note says the release changes Host volumes in place (v0.12.0 does), also take
a PD snapshot of each Host workspace PVC.

1. Bump the tag ([05](05-images-registry-and-pinning.md)); re-assemble at the new tag
   (fresh public tree + your unchanged overlay), then run the upstream-drift
   checks in [02 › Keeping the overlay honest](02-assembly-and-overlay-structure.md#keeping-the-overlay-honest-over-time)
   (DNS patch targets, overlay-owned ConfigMaps, new Deployments).
   Also compare your overlay with this kit's template: in your kit clone,
   `git diff gke-kit-<old> gke-kit-<new> -- overlay-template/` lists every
   template change since the kit tag you installed from, and the upgrade note
   below says which ones are required.
2. A1 (CRDs, re-apply) and A3 (RBAC) again if the release changed them.
3. Phase B in full. Always read the B6 diff: expect the two JWT ConfigMaps to
   show their key being replaced/blanked (B8 restores them — do not "fix" the
   diff), image tags, and whatever the release notes announce.
4. HCC rolls out before WRC by itself (`Recreate` + `replicas: 1`); if WRC
   reports `ExternalEgressReady` not fresh during the window, it is waiting
   for HCC to reconcile existing `McpServer`s — it clears on its own.

## From v0.10.0 to v0.12.0 in one deploy

This combines [v0.10.0 to v0.11.0](#upgrading-from-v0100-to-v0110) and
[v0.11.0 to v0.12.0](#upgrading-from-v0110-to-v0120); each step names the
note it comes from.

1. **Back up**, as under [Every upgrade](#every-upgrade): the C6 snapshot and
   a PD snapshot of each Host workspace PVC.
2. **With v0.10.x still running**, from a v0.12.0 clone: run
   `host-layout-merge.sh inventory` until `UPGRADE_BLOCKERS=0`, and copy the
   history out of any desktop Host (v0.12.0 note, steps 1 and 2).
3. **Update your overlay** from
   `git diff gke-kit-v0.10.0 gke-kit-v0.12.0 -- overlay-template/`:
   - add `RPC_PROXY_ARTIFACT_DOWNLOAD_TIMEOUT_MS: "300000"` to
     `configmaps/rpc-proxy-config.yaml` (v0.11.0 note, step 2);
   - remove `STDIO_BRIDGE_IMAGE` and add
     `patches/hcc-workspace-layout-merge.yaml` with `"true"` (v0.12.0 note,
     step 4);
   - set every Desktop App URL: the `CONTROL_API_DESKTOP_*` keys in
     `configmaps/control-api-config.yaml` and the public URLs in
     `patches/external-rest-api-public-urls.yaml` (v0.12.0 note, step 4;
     [03 › The Desktop App](03-ingress-and-hostnames.md#the-desktop-app));
   - optionally, the feature defaults in [10](10-feature-defaults.md).

   Render; the value gate in
   [02](02-assembly-and-overlay-structure.md#render-and-verify-no-cluster-needed)
   must print `values ok`.
4. **CRDs from v0.12.0 (A1)**, before Phase B. They carry both releases'
   changes; no RBAC change, so A3 is not needed.
5. **Phase B in full, at v0.12.0.** Run B4 first if `control-api`,
   `control-postgres` or `host-context-controller` still carry
   `RollingUpdate`. Read the B6 diff against both notes. Every running Host
   restarts once and merges on that start.
6. **After B13:**
   - Desktop App users who already added the environment remove it and add
     `https://api.<BASE_DOMAIN>` again; re-send pending invitations
     ([03 › The Desktop App](03-ingress-and-hostnames.md#the-desktop-app),
     "After correcting a wrong value").
   - Run `host-layout-merge.sh verify`, then turn the merge switch off in a
     separate deploy (v0.12.0 note, step 7).
7. **Tell your users** about the v0.12.0 behaviour changes (v0.12.0 note,
   step 6).
8. **Rollback rules from both notes:** never roll control-api back to v0.10.x
   once the new release has served logins (v0.11.0 note, step 4); before
   rolling HCC back, set the merge switch to `"true"` and deploy that first
   (v0.12.0 note, step 8). The general rules are in
   [07 › Rollback](07-deploy-sequence-and-verification.md#rollback).

## Release notes, newest first

### Upgrading from v0.11.0 to v0.12.0

v0.12.0 gives every Host one storage layout on its workspace PVC
(evenfire-ai/evenfire#1111). On v0.10.x and v0.11.x, a Host that ran
stateless had its PVC split into `state/` (the conversation database) and
`workspace/` (the agent's files). v0.12.0's HCC renders a
`workspace-layout-merge` init container that moves a split tree back to the
PVC root on the Host's next start, once; on any other tree it exits 0 and
changes nothing. The steps below wrap that; the product reference is
`docs/deploy/host-pvc-layout-upgrade.md` in the clone.

1. **Inventory Host storage, with your current release (v0.10.x or v0.11.x)
   still running.** From the v0.12.0
   clone (the script is new in this release and needs `jq`):

   ```bash
   bash deploy/scripts/host-layout-merge.sh inventory --context "$CONTEXT"
   # expected: exit 0, UPGRADE_BLOCKERS=0 (PRE_825=yes is normal before the upgrade)
   ```

   It only reads, except for one short-lived Pod per Host PVC (claim mounted
   read-only, no service-account token, deleted after its log is read).
   Repair every `WILL_REFUSE_F<n>` line first (*Repairs* in the upstream note)
   and re-run until `UPGRADE_BLOCKERS=0`: a refused Host stays in
   `Init:Error` after the upgrade, and B13 fails on it because `mcp-host` is a
   gating namespace. `WILL_MERGE` and `WILL_SUPERSEDE` need nothing.
2. **Desktop Hosts: copy their history out first.** A desktop Host
   (`spec.desktop`) kept its conversation database inside the container,
   outside the PVC, so the first v0.12.0 rollout loses it. `inventory` prints
   `DESKTOP_HOSTS=<n>`; for each one, copy `/workspace/state.db*` (the
   database and its `-wal` / `-shm` files) out of the running Pod with
   `kubectl --context "$CONTEXT" -n mcp-host cp` before step 5.
3. **CRDs first (A1), before Phase B.** `mcpservers.clerum.io` gains the
   optional, immutable `spec.oauth.asProfile` (`entra-v2`, accepted only with
   a Microsoft Entra ID tenant issuer); `hosts`, `globalfilesystems` and
   `llmhooks` change descriptions only. No RBAC, ServiceAccount or namespace
   change: A3 is not needed.
4. **Overlay changes, all in the template.** Two come with the release.
   Remove `STDIO_BRIDGE_IMAGE`
   from the HCC block of `patches/dynamic-images.yaml` (no release reads it
   and the base no longer sets it; keep `CONTEXT_MAPPER_STDIO_BRIDGE_IMAGE`).
   Add `patches/hcc-workspace-layout-merge.yaml` with the value `"true"` and
   list it under `patches:`. **Never set it to `"false"` in the upgrade
   deploy**: without the init, a split Host starts on an empty database and
   reports no error.

   The template also changed since `gke-kit-v0.11.0`
   (`git diff gke-kit-v0.11.0 gke-kit-v0.12.0 -- overlay-template/`; from
   v0.10.0, diff from `gke-kit-v0.10.0` instead):
   - **Desktop App URLs, required.** `configmaps/control-api-config.yaml`
     now sets `CONTROL_API_DESKTOP_EXTERNAL_REST_API_BASE_URL`,
     `CONTROL_API_DESKTOP_RPC_PROXY_BASE_URL` and `CONTROL_API_DESKTOP_APP_NAME`,
     and `patches/external-rest-api-cors.yaml` is now
     `patches/external-rest-api-public-urls.yaml` (an overlay that keeps the
     old file name works unchanged). Any of these keys missing from your
     overlay hands the Desktop App a `127.0.0.1` URL. The value gate (B5)
     must print `values ok`. If users already connected with wrong values,
     follow "After correcting a wrong value" in
     [03 › The Desktop App](03-ingress-and-hostnames.md#the-desktop-app).
   - **Feature defaults, optional.** LLM subscriptions (Codex, Grok), GFS
     upload v2 and the control-api pool size: adopt them as described in
     [10](10-feature-defaults.md).
5. **Phase B in full.** B2 applies one schema migration,
   `workflow_schedules.concurrency_policy` (default `Forbid`); it waits at
   most 60 s for the table lock, then the Job fails and retries. The B6 diff
   shows, besides tags and the JWT ConfigMap lines: the base nginx gateways
   moving from `nginx:1.30.1-alpine` to `nginx:1.30.6-alpine`, a new public
   route in `profile-control-funnel-nginx` for the OAuth client metadata
   document ([03](03-ingress-and-hostnames.md)), `webhook-proxy`'s port 9090
   renamed from `metrics` to `health`, and, on `host-context-controller`,
   `STDIO_BRIDGE_IMAGE` removed and `CONTEXT_MAPPER_WORKSPACE_LAYOUT_MERGE`
   added. **Every running Host restarts once** (its pod template gains the
   init container) and merges on that start; suspended Hosts merge on their
   next wake. The mcp-host images are larger in this release (fonts for the
   document tools), so the first pull on each node takes longer. After the
   upgrade each Host gets one 401 on its control token and renews it; that
   log line is expected. control-api must stay at one replica with the
   `Recreate` strategy, as the base sets (the OAuth broker binds tokens to
   it); the template changes neither.
6. **Behaviour changes to tell your users about.**
   - **Scheduled workflow runs no longer overlap.**
     `spec.triggers.schedule.concurrencyPolicy` was accepted but not enforced
     before. v0.12.0 enforces its default, `Forbid`: a scheduled tick is
     skipped while a run of the same recipe is still pending or running.
     Recipes that relied on overlapping runs must set
     `concurrencyPolicy: Allow` (`Replace` behaves like `Allow`).
   - **Chat-generated files are per user** (evenfire-ai/evenfire#931).
     Files written before v0.12.0 to the shared `<workspace>/outputs` are no
     longer listed or served. They stay on the Host's PVC, and mcp-host logs
     how many there are at startup. To give one back to its owner, move it
     into `<workspace>/users/<key>/.clerum-outputs/` (mode `700`), where
     `<key>` is `printf 'rpc:%s' "$USER_ID" | shasum -a 256 | cut -c1-16`.
   - **A user's OAuth token on a Host needs direct access.** Context
     membership alone no longer grants it: the user must enter that Host
     directly or through an active team.
   - **New invitations expire after 7 days**, including desktop and Control
     Admin invitations and setup resends. Invitations sent before the
     upgrade keep their expiry.
7. **After B13: verify, then turn the switch off in a separate deploy.**

   ```bash
   bash deploy/scripts/host-layout-merge.sh verify --context "$CONTEXT"
   # turn off only on: exit 0, HOST_LAYOUT_VERIFY=PASS and ORPHAN_SPLIT=0
   ```

   `HOST_LAYOUT_VERIFY=PRE_825` or a non-zero `template_stale` right after
   the upgrade means HCC has not reconciled that Host yet (its first full
   reconcile can take 15–20 min): wait and run `verify` again.
   `SPLIT` is a Host that has not started since the upgrade (typically a
   suspended one): wake it once, for example by opening one of its chats, and
   run `verify` again. `ORPHAN_SPLIT` above 0 is a split PVC whose Host was
   deleted; a Host created later under that name would reuse the PVC, so
   delete it or recreate the Host while the switch is still `"true"`.
   `UNKNOWN`, `UNREADABLE` and `UNVERIFIED` never count as merged. Then set
   `"false"` in `patches/hcc-workspace-layout-merge.yaml`, re-render and run
   Phase B; every running Host restarts once more. While the switch is on, the
   init runs at every Host start, and an agent-created `state/state.db*`
   entry on a stateful Host can trigger a merge or a refusal; turning it off
   closes that window.
8. **Rolling HCC back to v0.11.x or older:** if the switch is already
   `"false"`, set it back to `"true"` and deploy that first. The init in those
   releases re-splits stateless trees, and only a roll-forward with the merge
   rendered brings them back to the PVC root.

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
