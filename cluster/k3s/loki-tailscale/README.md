# loki-tailscale: Loki push endpoint for the Mac, Tailscale only

RFC-052 D2, task 1.9. **Operator step.** Claude prepares these files. A human runs them on portfolio.

The Mac's Grafana Alloy (task 1.10) ships `~/docling-service/logs/service.log` to Loki at:

```
http://100.120.146.20:31100/loki/api/v1/push      # portfolio's tailscale0 address
```

Loki has **no auth**, so the NodePort must be reachable only through `tailscale0`.

| File | What it is |
|---|---|
| `loki-tailscale-service.yaml` | NodePort Service `infra/loki-tailscale`, 31100 → `loki:3100`. **Not** in `apps/infra/`, so `deploy.yml` never applies it before the guard exists. |
| `apply-firewall.sh` | Host guard. Adds `raw/PREROUTING -p tcp --dport 31100 -j LOKI-TAILSCALE`; that chain ACCEPTs `-i tailscale0` and DROPs everything else, for both iptables and ip6tables. Idempotent. Has `--dry-run`, `--check`, `--remove`, `--persist` and `--unpersist` modes. |

The rule lives in the `raw` table on purpose. kube-proxy DNATs NodePort traffic in `nat/PREROUTING` straight to the pod IP, so a `filter/INPUT` rule would never see it. `raw/PREROUTING` runs before any NAT.

The public Hetzner Cloud firewall does **not** list 31100 and must stay that way. The host rule is the second, independent layer, and it is the only layer that covers the private network (`enp7s0`) and pod traffic.

## Apply (in this order)

```bash
cd /root/hetzner-deployment-service/cluster/k3s/loki-tailscale

sudo ./apply-firewall.sh --dry-run     # review the exact iptables commands
sudo ./apply-firewall.sh               # apply; ends with a --check
sudo ./apply-firewall.sh --persist     # re-apply at boot, before k3s.service
sudo ./apply-firewall.sh --check       # expect: every line "ok" (Service "not applied yet")

kubectl apply -f loki-tailscale-service.yaml
sudo ./apply-firewall.sh --check       # now also: "ok Service infra/loki-tailscale nodePort 31100"
```

iptables rules do not survive a reboot. Without `--persist`, a reboot leaves the port open on the private network and pod interfaces, guarded only by the cloud firewall for public traffic. The unit runs the script from this checkout. If the repo moves, run `--persist` again.

## Prove it

### 1. Open over Tailscale (from the Mac)

```bash
curl -s -m 5 http://100.120.146.20:31100/ready          # expect: ready
```

### 2. Closed publicly: the external probe

Run this from any machine that is **not** on the tailnet, such as a phone hotspot laptop or another cloud VM. Get portfolio's public IP on portfolio with `ip -4 -br addr show eth0`.

```bash
PUB=<portfolio public IPv4>
nc -vz -w 5 "$PUB" 31100                                  # expect: timeout (filtered), never "succeeded"
curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$PUB:31100/ready"   # expect: 000
nmap -Pn -p 31100 "$PUB"                                  # expect: 31100/tcp filtered
```

### 3. The host rule itself works, not just the cloud firewall

The cloud firewall drops public traffic before it reaches the host. A clean public probe therefore does not exercise this rule. Probe over an interface the cloud firewall does not filter, such as the pod network, and watch the DROP counter:

```bash
PRIV=$(ip -4 -br addr show enp7s0 | awk '{print $3}' | cut -d/ -f1)
sudo iptables -t raw -L LOKI-TAILSCALE -v -n               # note the DROP pkts count
kubectl -n infra run nodeport-probe --rm -i --restart=Never --image=busybox:1.36 -- \
  sh -c "nc -zv -w 5 $PRIV 31100; echo exit=\$?"          # expect: timeout, exit=1
sudo iptables -t raw -L LOKI-TAILSCALE -v -n               # DROP pkts went up
```

## Roll back

```bash
kubectl delete -f loki-tailscale-service.yaml               # close the port first
sudo ./apply-firewall.sh --unpersist
sudo ./apply-firewall.sh --remove
```

Never run `--remove` while the Service exists. It re-opens 31100 on every interface.
