# 00 — Prerequisites

## GCP project and cluster

Two decisions that are easy to conflate:

1. **Application edge** — how user traffic reaches the five public hostnames.
   With Evenfire's choice (Cloudflare Tunnel) the *application* has no public
   LoadBalancer and no public IP ([03](03-ingress-and-hostnames.md)).
2. **Cluster and node exposure** — whether nodes carry external IPs, whether
   the Kubernetes API answers the internet, and what the VPC firewall admits.
   The edge choice does nothing about this; only the cluster-creation flags
   and the VPC below do.

Evenfire's reference clusters are **GKE Standard**, zonal, VPC-native
(`--enable-ip-alias`), one node pool. A minimal command with that cluster
shape is:

```bash
gcloud services enable container.googleapis.com artifactregistry.googleapis.com compute.googleapis.com \
  --project=<GCP_PROJECT_ID>

gcloud container clusters create <CLUSTER_NAME> \
  --project=<GCP_PROJECT_ID> --zone=<ZONE> \
  --num-nodes=1 --machine-type=<MACHINE_TYPE> \
  --disk-type=pd-ssd --disk-size=100 \
  --release-channel=stable \
  --enable-ip-alias \
  --enable-network-policy \
  --network=default \
  --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring
```

That command leaves decision 2 at GKE's defaults: nodes get **external
IPs**, the API endpoint is **public**, and the `default` VPC ships
`default-allow-ssh` / `-rdp` / `-icmp` from `0.0.0.0/0`. The recommended
hardening is a private-node cluster. **Verify every flag against
`gcloud container clusters create --help` on your gcloud/GKE version** —
private-cluster flags have changed across releases:

```bash
# Private nodes have no route to the internet: Cloud NAT provides the outbound
# HTTPS the platform needs (LLM/chat/OAuth providers, the plugin registry,
# image pulls) and cloudflared's outbound 7844 if you use the tunnel.
gcloud compute routers create <CLUSTER_NAME>-router --network=default --region=<REGION> --project=<GCP_PROJECT_ID>
gcloud compute routers nats create <CLUSTER_NAME>-nat --router=<CLUSTER_NAME>-router --region=<REGION> \
  --project=<GCP_PROJECT_ID> --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges

gcloud container clusters create <CLUSTER_NAME> \
  --project=<GCP_PROJECT_ID> --zone=<ZONE> \
  --num-nodes=1 --machine-type=<MACHINE_TYPE> --disk-type=pd-ssd --disk-size=100 \
  --release-channel=stable --enable-ip-alias --enable-network-policy --network=default \
  --enable-private-nodes --master-ipv4-cidr=<CONTROL_PLANE_CIDR> \
  --enable-master-authorized-networks --master-authorized-networks=<OPERATOR_CIDR> \
  --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring
```

- `--enable-private-nodes`: no external IPs on nodes. `--master-ipv4-cidr`
  (an unused RFC 1918 `/28`) is required by GKE versions that peer the control
  plane into your VPC; versions with a PSC-based control plane may not accept
  it — that is the flag most likely to differ, check the help text.
- `--enable-master-authorized-networks`: the public API endpoint answers only
  `<OPERATOR_CIDR>` (your office/VPN egress and your CI runners' egress; a
  comma-separated list is accepted). Add `--enable-private-endpoint` to
  remove the public endpoint entirely — then every `kubectl` in this guide,
  CI included, must run inside the VPC (bastion, VPN, Interconnect).
- Firewall: audit the `default` VPC and delete or restrict
  `default-allow-ssh`, `default-allow-rdp`, `default-allow-icmp`. With
  private nodes, SSH (if you need it at all) goes through IAP TCP forwarding
  from `35.235.240.0/20`, not from the internet.
- `<REGION>` is the region of `<ZONE>` (the router is regional).

Observable checks after creation:

```bash
# 1. no node has an external IP (last column empty)
gcloud compute instances list --project=<GCP_PROJECT_ID> --filter="name~^gke-<CLUSTER_NAME>" \
  --format="table(name,networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)"
# 2. private nodes / endpoint / authorized networks are what you intended
gcloud container clusters describe <CLUSTER_NAME> --zone=<ZONE> --project=<GCP_PROJECT_ID> \
  --format='yaml(privateClusterConfig,masterAuthorizedNetworksConfig,controlPlaneEndpointsConfig)'
# 3. nothing admits 0.0.0.0/0 on ingress except rules you can explain (GKE's own gke-* rules are scoped to node tags)
gcloud compute firewall-rules list --project=<GCP_PROJECT_ID> \
  --format="table(name,network.basename(),direction,sourceRanges.list(),allowed[].map().firewall_rule().list())"
# 4. NAT works: any HTTP status (even 401) proves egress; a timeout means no NAT
kubectl --context "$CONTEXT" -n default run egress-check --rm -i --restart=Never \
  --image=curlimages/curl:8.7.1 -- -sS -m 10 -o /dev/null -w '%{http_code}\n' https://ghcr.io/v2/
```

Notes on each choice. **All sizing values below (machine type, disk, node
count, volume sizes, the requests/limits in the template) are indicative
starting points, not requirements or a description of any Evenfire
environment.** Size for your own Host count, recipes and data, then tune from
observed usage (`kubectl top pods -A`, Cloud Monitoring).

| Choice | Indicative value | Guidance |
|---|---|---|
| Cluster mode | Standard | Autopilot has not been validated: the platform runs controllers that create pods, PVCs and NetworkPolicies at runtime, uses PodSecurity `baseline` namespaces and a few `hostPath`-free but non-default securityContexts. Assume Standard. |
| Machine type | `e2-standard-8` (8 vCPU / 32 GB) for production-like use; `e2-standard-4` for evaluation | Static platform pods request ~1 vCPU / ~1.3 GiB and have limits of ~4.3 vCPU / ~4 GiB ([resource-limits.yaml](overlay-template/patches/resource-limits.yaml)). Runtime pods come on top: each agent Host up to 2 GiB, plus its channel-reader, per-workflow coordinators, MCP servers. 8 vCPU / 32 GB is a reasonable start for a handful of Hosts and a few recipes; add nodes or a larger type as the fleet grows. |
| Disk | ~100 GB boot (pd-ssd or pd-balanced) | Data lives on PVCs (below), not on the boot disk. |
| Nodes | 1 to start | A single node is the simplest starting point. Multi-node works, but see the ReadWriteOnce notes in [02](02-assembly-and-overlay-structure.md) (workflow-output PVC) and make sure the HCC-created per-Host workspace PVCs use an RWO class that can follow the pod. |
| Node exposure | your decision | Private nodes + Cloud NAT (above). The platform needs no inbound connectivity to nodes; everything it needs is outbound 443 (and 7844 for the tunnel option). |
| Control-plane access | your decision | Authorized networks at minimum; private endpoint if your operators and CI can reach the VPC. The deploy scripts only need `kubectl` reachability. |
| Release channel | `stable` for production, `regular` for test clusters | Any supported version. |
| NetworkPolicy | `--enable-network-policy` (legacy Calico add-on) | This is what Evenfire runs and has verified. New clusters default to **GKE Dataplane V2**, which enforces NetworkPolicy natively and is the recommended choice for a fresh install; it is *expected* to work but is **not** what the reference was validated on. Details and the verification procedure are in [04](04-network-policies-and-cni.md). Pick one *before* creating the cluster: switching later recreates nodes. |
| NodeLocal DNSCache | detected at install time | If enabled (`addonsConfig.dnsCacheConfig.enabled`), the DNS ipBlock patches in the overlay are required under enforcement; the overlay ships them unconditionally, which is harmless when the cache is off. |
| Workload Identity | not required | Image pulls use the **node** service account and nothing in the platform calls Google APIs with pod identity. If you add a workload that does, see the metadata-server note in [04](04-network-policies-and-cni.md). |

### Storage

| Volume | Created by | Access mode | Suggested class |
|---|---|---|---|
| `control-postgres-data` (5Gi base) | overlay apply | RWO | `standard-rwo` (pd-balanced); `premium-rwo` for pd-ssd |
| GlobalFileSystem volume | HCC from the `GlobalFileSystem` instance | RWO | `standard-rwo`; size for your data (indicative: 100–500Gi) |
| per-Host workspace PVCs | HCC (`CONTEXT_MAPPER_HOST_WORKSPACE_STORAGE_CLASS`) | RWO | `standard-rwo` |
| `clerum-workflow-output` (legacy, 1Gi) | overlay apply | RWO on single node / RWX otherwise | `standard-rwo` or Filestore |
| optional `SharedFileSystem` PVCs | HCC | RWO (CRD default; RWX / bucket mounts not supported in v0.10.0, [06](06-secrets-keys-rbac-crds.md#sharedfilesystem-storage)) | `<STORAGE_CLASS_RWO>` |

Confirm the classes exist and allow expansion:

```bash
kubectl --context "$CONTEXT" get storageclass
kubectl --context "$CONTEXT" get storageclass standard-rwo -o jsonpath='{.allowVolumeExpansion}'
```

### Artifact Registry (optional)

Images can be pulled straight from the public registry
(`ghcr.io/evenfire-ai/<image>:<tag>`) or mirrored into your own Artifact
Registry ([05](05-images-registry-and-pinning.md)). If you mirror:

```bash
gcloud artifacts repositories create <AR_REPO> --repository-format=docker \
  --location=<REGION> --project=<GCP_PROJECT_ID>
PROJECT_NUMBER=$(gcloud projects describe <GCP_PROJECT_ID> --format='value(projectNumber)')
gcloud projects add-iam-policy-binding <GCP_PROJECT_ID> \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role=roles/artifactregistry.reader
```

`<REGISTRY_PATH>` is then `<REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/<AR_REPO>`.

## IAM

| Identity | Needs | Used for |
|---|---|---|
| You (operator) | `roles/container.admin` on the project (or cluster-admin in-cluster) | CRDs, RBAC bootstrap, key generation, first install |
| Deploy identity (CI or a dedicated SA) | `roles/container.developer`; **deliberately not** `container.roles.update` | `kubectl diff/apply` of the rendered overlay minus RBAC. Evenfire keeps RBAC out of the deployer's reach so CD cannot escalate itself; the overlay apply therefore strips `Role/ClusterRole/*Binding` and RBAC is applied by the operator ([06](06-secrets-keys-rbac-crds.md)). |
| Node service account | `roles/artifactregistry.reader` (if mirroring) | image pulls |
| GitHub Actions (if you adopt CI) | Workload Identity Federation to the deploy SA, scoped to your repo + a protected environment | [07](07-deploy-sequence-and-verification.md) |

## Workstation tooling

`gcloud` (with `gke-gcloud-auth-plugin`), `kubectl` (>= 1.27; `kubectl kustomize`
is used, no separate kustomize needed), `helm` 3, `git`, `jq`, `openssl`,
`python3` with the non-stdlib `bcrypt` package (`python3 -m pip install bcrypt`)
**or** Apache `htpasswd` (macOS ships it; `apache2-utils` on Debian/Ubuntu) —
either one hashes the admin bootstrap password ([06](06-secrets-keys-rbac-crds.md#generating-the-keys--bootstrap-only-once)),
`ruby` (several verification scripts are Ruby one-liners),
`bash` >= 4 for a couple of the Evenfire CD guards (macOS ships 3.2; the
install scripts themselves are 3.2-compatible). `docker`/`crane` only if you
mirror or build images. `cloudflared` only for the Cloudflare option.

```bash
gcloud auth login
gcloud config set project <GCP_PROJECT_ID>
gcloud container clusters get-credentials <CLUSTER_NAME> --zone=<ZONE> --project=<GCP_PROJECT_ID>
export CONTEXT="gke_<GCP_PROJECT_ID>_<ZONE>_<CLUSTER_NAME>"   # the context name gcloud writes
```

## External dependencies

| Dependency | Why | Required? |
|---|---|---|
| A DNS zone you control (`<BASE_DOMAIN>`) and TLS | the five public hostnames; invitation emails embed them, so they must resolve publicly | yes |
| Outbound HTTPS from the cluster (through Cloud NAT on private nodes) | LLM provider APIs, chat providers (Telegram/Slack/...), OAuth providers, the public image registry, the Evenfire registration hub (invitation email, `hosted` mode), the plugin registry `https://registry.evenfire.ai` (Marketplace / Connect, and plugin image pulls) | yes |
| LLM provider API key(s) | the first agent Host (`chatllm-api-keys` Secret) | at least one |
| Cloudflare account + zone | only for the Cloudflare Tunnel edge option | no |
| GitHub account | to clone the public repo at a release tag | yes |

## Pre-flight checklist

- [ ] Cluster created with the NetworkPolicy decision made ([04](04-network-policies-and-cni.md))
- [ ] Node exposure and control-plane access decided and checked (the four checks above)
- [ ] `kubectl --context "$CONTEXT" get nodes` works with an admin identity
- [ ] StorageClasses confirmed
- [ ] Image pull path decided and tested: `docker pull ghcr.io/evenfire-ai/control-api:<IMAGE_TAG>` (or your mirror)
- [ ] DNS zone and certificate strategy decided ([03](03-ingress-and-hostnames.md))
- [ ] Release tag agreed with Evenfire
- [ ] All values in [09-values-checklist.md](09-values-checklist.md) collected
