# 09 — Values checklist

Every `<PLACEHOLDER>` used in this guide and in [overlay-template/](overlay-template/).
Collect them before touching the overlay; the detect script fills the three
CIDR rows for you.

| Placeholder | What it is | Where it is used | How to discover / decide |
|---|---|---|---|
| `<GCP_PROJECT_ID>` | GCP project hosting the cluster | gcloud commands, `<DEPLOY_SA_EMAIL>`, context name | `gcloud projects list` |
| `<REGION>` / `<ZONE>` | Artifact Registry and Cloud Router/NAT location / cluster zone | AR path, gcloud commands, `TRACING_CLUSTER_LOCATION` | `gcloud compute zones list` (`<REGION>` is the zone's region) |
| `<CONTROL_PLANE_CIDR>` | `/28` for the GKE control plane (private-node variant; **verify** your GKE version still takes `--master-ipv4-cidr`) | cluster creation ([00](00-prerequisites.md)) | an unused RFC 1918 block, e.g. `172.16.0.0/28`; must not overlap your VPC subnets |
| `<OPERATOR_CIDR>` | networks allowed to reach the Kubernetes API | `--master-authorized-networks` ([00](00-prerequisites.md)) | your office/VPN egress and CI runner egress, comma-separated |
| `<CLUSTER_NAME>` | GKE cluster name | gcloud commands, `TRACING_CLUSTER_NAME`, context name | your choice; `gcloud container clusters list` |
| `<MACHINE_TYPE>` | node machine type | cluster creation | indicative start: `e2-standard-8` ([00](00-prerequisites.md)) |
| `$CONTEXT` | kubeconfig context | every script (`CONTEXT`, `ALLOWED_CONTEXTS`, `--context`) | `gke_<GCP_PROJECT_ID>_<ZONE>_<CLUSTER_NAME>` after `gcloud container clusters get-credentials`; confirm with `kubectl config get-contexts` |
| `<OVERLAY_NAME>` | directory name under `deploy/overlays/` | all paths, `verify-networkpolicies.sh --overlay`, `OVERLAY=` for the preflight | your choice, e.g. `gke-prod` |
| `<RELEASE_TAG>` | public repo git tag to assemble | `git clone --branch` | agree with Evenfire; `git ls-remote --tags https://github.com/evenfire-ai/evenfire.git` |
| `<IMAGE_TAG>` | image tag | `kustomization.yaml` `newTag`, `patches/dynamic-images.yaml` | equals `<RELEASE_TAG>` |
| `<REGISTRY_PATH>` | registry prefix images are pulled from | `kustomization.yaml` `newName`, `patches/dynamic-images.yaml`, `patches/hcc-allowed-image-prefixes.yaml`, `CONTROL_API_ALLOWED_IMAGE_PREFIXES`, `WRC_ALLOWED_COORDINATOR_IMAGE_PREFIXES` | `ghcr.io/evenfire-ai` (public) or `<REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/<AR_REPO>` (mirror) |
| `<OLD_TAG>` / `<NEW_TAG>` | current and target release tags during an upgrade | the tag-bump `sed` in [05](05-images-registry-and-pinning.md) | `<IMAGE_TAG>` before / after; release notes |
| `<POOL>` / `<CURRENT>` | node pool and its current GKE version | the node-recreating upgrade when enabling Calico on an existing cluster ([04](04-network-policies-and-cni.md)) | `gcloud container node-pools list --cluster=<CLUSTER_NAME> --zone=<ZONE>` (`NAME`, `NODE_VERSION`) |
| `<AR_REPO>` | Artifact Registry repository name | AR path | `gcloud artifacts repositories list --location=<REGION>` |
| `<DEPLOY_SA_EMAIL>` | service account CI deploys with | `rbac-e2e-compat.yaml`, WIF binding | `gcloud iam service-accounts list` |
| `<BASE_DOMAIN>` | DNS zone for the five public hostnames | all `https://` values ([03](03-ingress-and-hostnames.md) table — including the four Desktop App URLs in `configmaps/control-api-config.yaml` and `patches/external-rest-api-public-urls.yaml`), cloudflared routes | your DNS; the five names must resolve publicly; keep the `app.`/`profile.`/`api.`/`rpc.`/`webhook.` prefixes ([03](03-ingress-and-hostnames.md#the-five-hostnames)) |
| `<APP_NAME>` | product name shown to users | `CONTROL_API_CONTROL_UI_APP_NAME`, `CONTROL_API_DESKTOP_APP_NAME`, `EXTERNAL_REST_API_DESKTOP_APP_NAME` | your choice |
| `<ENV_NAME>` | environment label on traces | `TRACING_ENVIRONMENT` | e.g. `prod` |
| `<STORAGE_CLASS_RWO>` | ReadWriteOnce StorageClass | `patches/storage-class.yaml`, `patches/workflow-output-storageclass.yaml`, `CONTEXT_MAPPER_HOST_WORKSPACE_STORAGE_CLASS`, `instances/globalfilesystem.yaml` | `kubectl --context "$CONTEXT" get storageclass` — `standard-rwo` on GKE |
| `<GFS_SIZE>` | Global File System volume size | `instances/globalfilesystem.yaml` | capacity planning (indicative 100–500Gi); expandable later only if the class allows expansion |
| `<K8S_API_CLUSTER_IP>` | `kubernetes` Service ClusterIP | `patches/k8s-api-ip*.yaml`, `CONTEXT_MAPPER_K8S_API_CIDRS` | `kubectl --context "$CONTEXT" get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}'` (script) |
| `<K8S_API_ENDPOINT_IP>` | API-server endpoint behind the ClusterIP | same | `kubectl --context "$CONTEXT" get endpoints kubernetes -n default -o jsonpath='{.subsets[*].addresses[*].ip}'` (script; may be several) |
| `<KUBE_DNS_CLUSTER_IP>` | kube-dns Service ClusterIP | `patches/nodelocal-dns-egress-rule.yaml`, `CONTEXT_MAPPER_NODELOCAL_DNS_CIDR` | `kubectl --context "$CONTEXT" -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}'` (script) |
| NodeLocal DNSCache on? | informational | decides whether the DNS ipBlock matters (harmless either way) | `gcloud container clusters describe <CLUSTER_NAME> --zone=<ZONE> --format='value(addonsConfig.dnsCacheConfig.enabled)'` |
| CNI / enforcement | informational, mandatory to know | [04](04-network-policies-and-cni.md) | `gcloud container clusters describe <CLUSTER_NAME> --zone=<ZONE> --format='value(networkPolicy.enabled,networkPolicy.provider,networkConfig.datapathProvider)'` |
| `<LLM_PROVIDER>` / `<LLM_MODEL>` | first Host's model | `instances/host.yaml` | one of `openai`, `claude`, `zai`, `bailian`, `vertex` (keys of the base `clerum-model-secret-mapping` ConfigMap) and a model that provider serves |
| LLM API key(s) | provider credentials | `mcp-host/chatllm-api-keys` Secret (created with `--from-file` from `read -rs` input, [06](06-secrets-keys-rbac-crds.md)) | from the provider |
| `<ADMIN_USERNAME>` / `<ADMIN_EMAIL>` | first admin | `POST /api/v1/admin/auth/setup` body, `/admin/auth/login` | your choice |
| admin password | first admin; also hashed into `ADMIN_BOOTSTRAP_PASSWORD_HASH` | typed via `read -rs` / `getpass`, never on a command line ([06](06-secrets-keys-rbac-crds.md)) | your choice; 8–256 chars |
| `CONTROL_API_MEMBER_REGISTRATION_HMAC_SECRET` | required by the token script outside minikube | `apply-inter-service-tokens.sh` **first run only** (A4b); passing it again rotates the value | `$(openssl rand -hex 32)` inline |
| Postgres password | superuser password | `control-postgres` Secret, patched via `--patch-file /dev/stdin` right after `gen-jwt-keys.sh` | `openssl rand -hex 24`; store it in your secret manager |
| `<TELEGRAM_USER_ID>` | allowed chat user ids | `instances/communicationchannel.yaml` | from the provider; optional |
| chat bot token(s) | Telegram/Slack/email credentials for a channel | `channels/cc-<channel>-credentials` Secret named by `spec.credentialsSecretRef` ([06](06-secrets-keys-rbac-crds.md#channel-credentials)) | from the provider; optional |
| `<TUNNEL_NAME>` / `<TUNNEL_UUID>` | Cloudflare Tunnel (option A only) | `configmaps/cloudflared-config.yaml`, DNS CNAMEs | `cloudflared tunnel create <TUNNEL_NAME>`; `cloudflared tunnel list` |
| Cloudflare credentials JSON | tunnel bearer credential (option A) | `ingress/cloudflared-credentials` Secret | `~/.cloudflared/<TUNNEL_UUID>.json` after create |
| Google OAuth client IDs | only if you enable Google sign-in | `CONTROL_API_GOOGLE_CLIENT_ID`, `EXTERNAL_REST_API_GOOGLE_CLIENT_ID`, `NEXT_PUBLIC_GOOGLE_CLIENT_ID` (extra patch) | Google Cloud Console; otherwise leave the base placeholders |
| Health-check / proxy CIDRs | option B with a Google load balancer | edge NetworkPolicies | Google Cloud docs for your LB type (**verify**) |

## Final gate

```bash
OV=deploy/overlays/$OVERLAY_NAME
kubectl kustomize "$OV" > /tmp/rendered.yaml
# value gate: no placeholder, no base loopback default, every hostname key present
missing=""
for k in CONTROL_API_CONTROL_UI_BASE_URL CONTROL_API_DESKTOP_PROFILE_UI_BASE_URL \
    CONTROL_API_OAUTH_CALLBACK_BASE_URL CONTROL_API_DESKTOP_EXTERNAL_REST_API_BASE_URL \
    CONTROL_API_DESKTOP_RPC_PROXY_BASE_URL RPC_PROXY_CORS_ORIGIN RPC_PROXY_OAUTH_CALLBACK_BASE_URL \
    CLERUM_PROFILE_UI_URL EXTERNAL_REST_API_CORS_ORIGIN EXTERNAL_REST_API_PUBLIC_BASE_URL \
    EXTERNAL_REST_API_DESKTOP_RPC_PROXY_BASE_URL; do
  grep -qw "$k" /tmp/rendered.yaml || missing="$missing $k"
done
if [ -n "$missing" ] || grep -nE '<[A-Z_]+>|127\.0\.0\.1|localhost' /tmp/rendered.yaml \
   || grep -rnE '<[A-Z_]+>' "$OV/instances"; then
  echo "FIX the lines above${missing:+; missing hostname keys:$missing}"
else
  echo "values ok"
fi
grep -nE '(image|value): *clerum/' /tmp/rendered.yaml   # nothing
# only with base/ingress: the DNS target is silently skipped if left commented,
# leaving cloudflared unable to resolve its upstreams under enforcement
if grep -qE '^ *- \.\./\.\./base/ingress' "$OV/kustomization.yaml"; then
  CIDR=$(grep -o 'cidr: [0-9.]*/32' "$OV/patches/nodelocal-dns-egress-rule.yaml" | head -1)
  [ -n "$CIDR" ] && grep -A40 'name: allow-dns-egress-ingress' /tmp/rendered.yaml | grep -q "$CIDR" && echo ok || echo MISSING
fi
```
