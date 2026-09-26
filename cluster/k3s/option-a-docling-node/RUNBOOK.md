# On-demand docling node (`docling-1`, cx33)

**Status (2026-09-25):** set up and verified. Snapshot of `docling-service:38835af` baked (auto-sized parallel chunks); `up` → HTTPS health, 401 without token, egress lock → `down` all checked. docling-1 is down (no server billing).
Chosen over resizing portfolio (cx series out of stock for migration; a resize
is a power-off). Scheduled cx33↔cx43 resizing is on hold — see
[Option B rescale](../OPTION-B-RESCALE.md).

`docling-1` is a second Hetzner Cloud server (cx33: 4 vCPU / 8 GB, hel1; `DOCLING_NODE_TYPE` overrides). It
joins the portfolio k3s cluster as an agent over a private network, runs only
docling-service, and exists only while you need it. `docling-node.sh` drives
everything; every mutating step accepts `--dry-run`.

```
                 internet
                    │  docling.saliltrehan.com (A → 89.167.109.165, fixed)
        ┌───────────▼────────────┐   k3s-net 10.0.0.0/16   ┌──────────────────┐
        │ portfolio (cx33)       │◄───────────────────────►│ docling-1 (cx33) │
        │ traefik, worker, infra │  flannel VXLAN, kubelet │ docling-service  │
        │ docling-service-local  │                         │ (on demand)      │
        │ (replicas 0 unless cx43)                         └──────────────────┘
        └────────────────────────┘
```

## Costs (hel1, 2026-09-25)

| Item | When billed | Price |
|---|---|---|
| `docling-1` cx33 + primary IPv4 | while the server **exists** (off still bills) | €0.0136 + €0.0008 = **€0.0144/h** |
| docling snapshot | while kept | €0.0143/GB/month (~8–12 GB → ~€0.15/mo) |
| private network, firewalls, DNS record | — | free |

## Files

| File | Purpose |
|---|---|
| `docling-node.sh` | `setup`, `bake`, `up`, `down`, `status`, `local on\|off` |
| `server-private-net.yaml` | k3s drop-in for portfolio: node-ip/flannel on the private NIC, public IP kept as ExternalIP and cert SAN |
| `cloud-init-docling-agent.yaml` | first-boot user-data for `bake`: joins as agent, builds the image from the public repo, imports it into containerd, removes docker |
| `apps/pageindex-mcp/docling-service-deployment.yaml` | two Deployments behind one Service: `docling-service` (pinned to docling-1) and `docling-service-local` (portfolio, replicas 0) |
| `apps/pageindex-mcp/docling-service-public.yaml` | Certificate, IngressRoute + rate limit, egress NetworkPolicy |

## 1. One-time setup (run on portfolio as root)

```bash
cd /root/hetzner-deployment-service/cluster/k3s/option-a-docling-node
./docling-node.sh setup --dry-run     # review
./docling-node.sh setup               # asks before the firewall change and the k3s restart
```

It is idempotent. What it changes:

- **SSH key** `/root/.ssh/docling_node`, uploaded as `portfolio-docling`. SSH to docling-1 goes over the private network only.
- **Network** `k3s-net` 10.0.0.0/16 (subnet 10.0.0.0/24). Portfolio attaches at 10.0.0.2; docling-1 always gets 10.0.0.3. No overlap with pods (10.42/16) or services (10.43/16).
- **firewall-1** (portfolio) is narrowed from `tcp 22-9000` to tcp 22, 80, 443, 3001 (SyncHub) and 6443 (GitHub Actions deploy via `KUBECONFIG_B64`), plus ICMP. The old rules are saved to `/root/firewall-1.before.<timestamp>.json`. Nothing that listens today loses access: 10250 and 8472/udp were already outside the old rule.
- **docling-node-fw** (docling-1): ICMP only. Kubelet, flannel and SSH all ride the private net, which Hetzner firewalls do not filter.
- **DNS** `docling.saliltrehan.com` A → 89.167.109.165, TTL 300, in the Hetzner-hosted `saliltrehan.com` zone.
- **k3s restart on portfolio** with `20-private-net.yaml`: the API is down for ~30–90 s, containers keep running (`KillMode=process`). The datastore is sqlite/kine, so the node-ip change is safe.

Verify:

```bash
kubectl get node portfolio -o wide        # INTERNAL-IP 10.0.0.2, EXTERNAL-IP 89.167.109.165
kubectl -n kube-system get svc traefik    # EXTERNAL-IP still 89.167.109.165
curl -sI https://mem.saliltrehan.com | head -1
```

Then apply the manifests (or let the deploy workflow do it after the branch merges):

```bash
cd /root/hetzner-deployment-service
kubectl apply -n pageindex-mcp -f apps/pageindex-mcp/service.yaml \
  -f apps/pageindex-mcp/docling-service-deployment.yaml \
  -f apps/pageindex-mcp/docling-service-public.yaml
```

`docling-service` sits at 0 replicas until `up` sizes it to docling-1 and scales it to 1; `down` scales it back to 0.

## 2. Bake the image (once per docling-service version)

```bash
./docling-node.sh bake <full pageindex commit sha>
```

Creates docling-1 from ubuntu-24.04, builds `services/docling-service/Dockerfile`
at that commit **on the node** (~15–30 min on 2 vCPU), imports the image into
the agent's containerd as `docling-service:<sha7>`, points both Deployments at
it, snapshots the server (label `docling-node=snapshot`, older one deleted) and
deletes the server. No registry or pull secret is involved.

The model download uses `HF_TOKEN` from `pageindex-mcp-secrets` when it is
set (anonymous otherwise, which is slower and rate-limited). `bake` hands it to
the node over SSH on the private network into `/run/hf_token` (tmpfs), and the
Dockerfile reads it as a BuildKit secret: it is not in user-data, the image
layers or the snapshot. The running service never needs it (models are baked
in, runtime is offline). Once
`build-push-docling-service.yml` publishes to GHCR from master, the deploy
workflow switches the Deployments to the GHCR tag instead.

## 3. Day to day

```bash
./docling-node.sh up       # ~3-5 min: server from snapshot, join, pod Ready, https health
./docling-node.sh status   # server, node, pods, snapshot size and cost
./docling-node.sh down     # drain, delete node + server; billing stops
```

While up, `https://docling.saliltrehan.com` answers from anywhere with
`Authorization: Bearer <DOCLING_SERVICE_BEARER_TOKEN from pageindex-mcp-secrets>`.
The service refuses to start without that token.

## 4. The portfolio copy

```bash
./docling-node.sh local on    # refuses unless portfolio has >=16 GB (cx43)
./docling-node.sh local off
```

`on` copies the image from docling-1 over the private net if portfolio lacks
it, so run it while docling-1 is up (or once the GHCR image exists).

## Things to know

- **Sizing is automatic.** `up` gives the docling pod the node's allocatable
  CPU and memory (minus 256Mi), whatever server type it got. The service then
  reads its cgroup limits and, per request, picks the number of parallel chunk
  processes, threads per process and chunk size
  (`pageindex_mcp/converters/docling_resources.py`). There are no thread or
  page env values to tune. On a cx33 a large PDF runs as 4 processes x 1
  thread, 10-page chunks: TableFormer (~99% of the time on table-dense
  pages) keeps one process at ~1.7 cores whatever its thread count, so 4 x 1
  was 3x faster than 1 x 4 on the same pages. `DOCLING_NODE_TYPE` with more
  vCPUs and RAM scales it without other changes.

- **The worker is switched (2026-09-25).** The live `pageindex-mcp-config` has
  `DOCLING_SERVICE_URL=http://docling-service:8080` (and the default of 2
  worker jobs). **Conversions fail while no copy is running**: run
  `docling-node.sh up` before ingesting, `down` after. A worker fallback to
  local conversion when the service is unreachable is not built.
- **Host-side tooling** (`make env DOCLING=remote` in pageindex) uses
  `https://docling.saliltrehan.com` from `env/remote.env`, with the same token.
- **G1 comparison.** The post arm then runs on extra hardware (docling-1). Say
  so in the G1 report: the result measures "offload to a dedicated node".
- **Egress lock.** docling pods may reach DNS, public IPs and traefik only —
  not cluster IPs, the private net, or the metadata service (which holds the
  k3s join token in docling-1's user-data). Check after the first `up`:
  `kubectl -n pageindex-mcp exec deploy/docling-service -- curl -m 5 -s http://169.254.169.254/ || echo blocked`.
  This relies on k3s's built-in network-policy controller (on by default).
- **PII (HR3).** The public hostname is for your own tooling. The in-cluster
  worker uses the Service, so its documents never take the public route.
- **Presigned downloads** from docling-1 go to `infra.saliltrehan.com` over the
  public internet (TLS), as with any external caller.
- **Nothing else runs on docling-1**: the `dedicated=docling:NoSchedule` taint
  keeps the traefik svclb and promtail DaemonSets off it, so docling logs are
  in `kubectl logs`, not Loki.
- **Snapshot contents** include the k3s node token (in
  `/etc/rancher/k3s/config.yaml`). Snapshots are private to the project;
  rotate with `k3s token rotate` if one is ever shared.

## Teardown of everything

```bash
./docling-node.sh down
hcloud image list -t snapshot -l docling-node=snapshot     # then: hcloud image delete <id>
kubectl -n pageindex-mcp delete -f apps/pageindex-mcp/docling-service-public.yaml
rm /etc/rancher/k3s/config.yaml.d/20-private-net.yaml && systemctl restart k3s
hcloud server detach-from-network portfolio --network k3s-net
hcloud network delete k3s-net && hcloud firewall delete docling-node-fw
jq .rules /root/firewall-1.before.*.json > /tmp/fw.json && hcloud firewall replace-rules firewall-1 --rules-file /tmp/fw.json
# and delete the docling A record in the saliltrehan.com zone (Cloud Console → DNS)
```
