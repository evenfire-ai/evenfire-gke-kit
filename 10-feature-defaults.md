# 10 — Feature defaults and adoption

The GKE overlay enables the profile below on the supported `v0.12.0` public
base and matching images. These are deployment defaults; connecting accounts,
assigning models, provisioning storage and confirming NetworkPolicy
enforcement are still installation steps.

## ENV map

Every value is a string. ConfigMap locations are `namespace/name`; Deployment
variables are explicit `env[]` entries on the named container.

| Feature | ENV and default | Owner |
|---|---|---|
| Codex subscription admission | `CONTROL_API_CODEX_SUBSCRIPTION_ENABLED="true"` | ConfigMap `control-plane/control-api-config` |
| Codex execution | `CODEX_LLM_PROXY_EXECUTION_ENABLED="true"` | ConfigMap `control-plane/codex-llm-proxy-config` |
| Codex Host provider | `MCP_HOST_CODEX_SUBSCRIPTION_ENABLED="true"` | ConfigMap `mcp-host/mcp-host-config` |
| Grok subscription admission | `CONTROL_API_GROK_SUBSCRIPTION_ENABLED="true"` | ConfigMap `control-plane/control-api-config` |
| Grok execution | `GROK_LLM_PROXY_EXECUTION_ENABLED="true"` | ConfigMap `control-plane/grok-llm-proxy-config` |
| Grok recipes | `WRC_GROK_SUBSCRIPTION_ENABLED="true"` | Deployment/container `control-plane/workflow-recipes`, `patches/dynamic-images.yaml` |
| Subscription catalog refresh | `SUBSCRIPTION_CATALOG_SYNC_CRON_ENABLED="true"`, `SUBSCRIPTION_CATALOG_SYNC_INTERVAL_MS="21600000"` (six hours) | ConfigMap `control-plane/control-api-config` |
| GFS upload v2 | `CONTEXT_MAPPER_GFSC_UPLOAD_V2_ENABLED="true"` | Deployment/container `control-plane/host-context-controller`, `patches/gfs-upload-storage-floor.yaml` |
| Codex/Grok MCP tool presentation | `CODEX_TOOL_PRESENTATION="auto"` | ConfigMap `mcp-host/mcp-host-config` |
| Native tool presentation | `CLERUM_NATIVE_TOOL_PRESENTATION="auto"` | ConfigMap `mcp-host/mcp-host-config` |
| Periodic NetworkPolicy reconciliation | `CONTEXT_MAPPER_NETPOL_RESYNC_SEC="3600"` | Deployment/container `control-plane/host-context-controller`, `patches/dynamic-images.yaml` |
| Periodic namespace-default reconciliation | `CONTEXT_MAPPER_NETPOL_DEFAULTS_RESYNC_SEC="300"` | Same |
| Core database pool | `CORE_POOL_MAX="24"`, `CORE_POOL_CONNECTION_TIMEOUT_MS="3000"` | ConfigMap `control-plane/control-api-config` |
| Host task ceiling | `CLERUM_AGENT_MAX_TASK_DURATION="86400000"` (24 hours) | ConfigMap `mcp-host/mcp-host-config` |
| Host tool-call ceiling | `CLERUM_AGENT_MAX_TOOL_CALLS="100"` | Same; retained when extending task duration |

HCC sets `MCP_HOST_GROK_SUBSCRIPTION_ENABLED="true"` only on eligible Grok
Hosts. Do not add it to the shared Host ConfigMap. This keeps provider
construction aligned with the Host's execution scope and egress projection.
The gate does not replace a connected account or authorization for a call.

The two presentation modes are independent. `auto` uses the runtime's tool
discovery policy; it does not grant access to additional tools or providers.
The shell, tool and MCP timeouts remain their existing template values.

The core database pool is **per Control API pod** and assumes control-api's
single replica, which v0.12.0 requires (07, upgrade step 5). Before raising
any pool, include the other
Control API pools, WRC, trace maintenance, GFS writer/readers and PostgreSQL
reserved/maintenance connections in the total connection budget. Raising
this pool does not make PostgreSQL capacity unlimited.

## Connect subscriptions

After Phase B:

1. Open **Control UI -> Secrets -> LLM Subscriptions**. Create a named
   ChatGPT or Grok connection and complete the device-code sign-in.
2. Sync the connection's catalog and select its enabled/default models.
3. In an agent's **Models & creds** tab, choose the subscription provider,
   connection and model. For recipes, select the connection in the recipe
   editor. A Host without its `connectionRef` cannot execute a subscription.
4. Run a small request with the assigned agent or recipe. Check the result
   before declaring the provider ready for users.

The six-hour cron refreshes the catalog of each connected subscription. Each
tick contacts the provider per connection; it is separate from automatic
access-token refresh and from the API-provider discovery catalog. The code
rejects a subscription catalog interval below 15 minutes.

Keep Control API, proxy and runtime gates coherent if you disable a provider.
Grok recipes also require the WRC gate; HCC owns the per-Host Grok gate.

## EvenDrive

EvenDrive uses GFS; there is no general `EVENDRIVE_ENABLED` variable. Phase B10
must provision the GFS instance and database credentials, and the JWT key sync
must complete. The template keeps
`CONTROL_API_DESKTOP_GFS_OPERATOR_LINKING_ENABLED="true"` for explicit Control
Admin to Desktop operator linking; this is separate from upload v2.

HCC projects the upload profile into the generated GFS workloads. The writer
receives `GFS_UPLOAD_V2_ENABLED="true"`. The product file limit is **200 MiB**,
with preferred 8 MiB chunks and a 16 MiB maximum chunk size. The 1 GiB protocol
ceiling does not override that product limit. Fill the instance's StorageClass
and volume size for your cluster; the upload flag does not create storage.

Use Phase C10 to verify listing, a small upload/download, and a multi-chunk
upload. Deployment readiness and a declared ENV value alone are not proof of
an authenticated file transfer.

## Adopting the profile on an existing install

Update your copied overlay as well as the image/base release pair. In
particular, include `configmaps/grok-llm-proxy-config.yaml` in
`patchesStrategicMerge` and copy all coordinated gates from the ENV map.
Changes in this repository do not update an overlay you copied earlier.

Render and run the [offline checks](02-assembly-and-overlay-structure.md#render-and-verify-no-cluster-needed),
then run Phase B in order. B11 restarts and waits for both subscription proxies
before restarting Control API. ConfigMap-only edits do not change the ENV of
an existing process.

New/recreated HCC-managed Host pods load the updated Host ConfigMap. Existing
pods can retain the previous Codex gate, presentation mode and task limits
until they are recreated. Verify adoption per Host through its normal
recreation or stateless wake; a ConfigMap read does not certify the whole
fleet. Avoid a bulk Host restart as part of this upgrade procedure.

The profile retains `REGISTRY_CONNECTION_MODE="self-hosted"` and hosted member
registration. Complete Marketplace Connect and member enrollment as described
in Phase C. It also retains WRC's NetworkPolicy `required` posture and
`CONFIRMED="false"` until the operator proves enforcement on this cluster.
Periodic HCC reconciliation does not replace that proof.
