# Networking: Self-Hosted Kubernetes on Azure VMSS Flex

The single most painful area for self-hosted K8s on Azure. Read this **before** you spend hours debugging kubeadm timeouts.

## TL;DR

- **Azure Standard Load Balancer has a "hairpin" restriction**: a VM in the LB backend pool cannot reach the LB frontend IP from itself. This breaks `kubeadm init` and `kubeadm join` on control-plane nodes unless you work around it.
- **Workaround**: on every control-plane node, before running `kubeadm init`/`kubeadm join`, redirect the LB IP to localhost. This repo uses an `iptables` NAT rule (`/etc/hosts` is insufficient — it doesn't help with literal-IP URLs).
- **Pod networking** uses Calico VXLAN with pod CIDR `192.168.0.0/16`, completely separate from the Azure VNet's `10.0.0.0/16`.
- **NodePort traffic** works on any worker IP; Service-type-LoadBalancer requires a separate Azure LB you set up yourself (this repo doesn't ship one).

---

## Azure Standard LB hairpin: the single biggest gotcha

### What it is

Azure Standard Load Balancer does **not** support "loopback" or "hairpin" traffic. When a VM that is in an SLB's backend pool tries to send a packet to that SLB's **frontend IP**, the packet is silently dropped. The connection times out.

This isn't a bug — it's documented Azure SLB behavior, and the same restriction exists on AWS NLB and GCP TCP LB. Cloud LBs are designed for ingress, not for backend VMs to talk to themselves.

### Why this breaks kubeadm

`kubeadm init --control-plane-endpoint <LB_IP>:6443` writes that LB IP into:

- `/etc/kubernetes/kubelet.conf` — the kubelet uses this URL to register with apiserver
- `/etc/kubernetes/admin.conf` — `kubectl` on the node uses this URL
- The CA-signed apiserver cert's SAN list (we add it explicitly via `--apiserver-cert-extra-sans`)
- The static-pod manifest for `kube-controller-manager`

After `kubeadm init` finishes, the local kubelet on CP1 tries to talk to `https://<LB_IP>:6443/...`. The packet goes to the LB; the LB sees that the source VM is in the backend pool; **the packet is dropped**.

Result: kubelet times out, `kubeadm init`'s `wait-control-plane` phase fails, the cluster never finishes initializing.

### Why a bash deployment sometimes appears to work

If the kubelet's first connection attempt happens **before** the LB rule has activated the VM as a backend (the health probe needs 2 successful checks at 5-second intervals = 10s minimum), the kubelet gets a TCP RST instead of a timeout, retries, and eventually catches the local apiserver static pod listening on `0.0.0.0:6443`. By the time the LB has the VM marked healthy and the hairpin restriction kicks in, kubelet has already cached a working connection.

This is **timing-dependent and not reliable**. We saw two CLI deployments pass on first try this way; we also saw a Terraform deployment fail because cloud-init had everything ready faster, so kubelet hit the LB rule sooner.

### The fix

Add an iptables NAT rule on every control-plane node, **before** running `kubeadm init` or `kubeadm join`:

```bash
sudo iptables -t nat -A OUTPUT -p tcp -d <LB_PUBLIC_IP> --dport 6443 -j DNAT --to-destination 127.0.0.1:6443
```

This rewrites outgoing TCP traffic destined for `<LB_PUBLIC_IP>:6443` to point at `127.0.0.1:6443` (the local apiserver static pod). It's transparent to kubelet, kubectl, kubeadm, and any other client — they think they're hitting the LB.

To persist across reboots, use `iptables-persistent` or systemd:

```bash
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

### Why `/etc/hosts` is NOT sufficient

You might think mapping the LB IP to `127.0.0.1` in `/etc/hosts` would work. It does **not**, because:

- `/etc/hosts` only resolves **hostnames** to IPs
- The kubeconfig has `server: https://<LB_IP>:6443` — a literal IP, no hostname to resolve
- Linux skips DNS/hosts lookup entirely when the URL contains an IP literal

`/etc/hosts` would only help if you used a hostname (e.g. `api.cluster.local`) in `--control-plane-endpoint` and added that hostname to `/etc/hosts` on every node. That's a valid alternative architecture but requires more setup.

### Workers don't need this

Workers (VMs in `snet-workers`) are **not in the LB backend pool**, so they can reach the LB IP normally. The iptables NAT rule is only required on control-plane nodes.

---

## NSG rules

These are the minimum NSG inbound rules required. All are applied to both subnets (CP and worker).

| Rule | Priority | Port(s) | Source | Purpose |
|---|---|---|---|---|
| `allow-ssh` | 100 | TCP 22 | `*` (tighten in prod) | Operator SSH; node management |
| `allow-apiserver` | 110 | TCP 6443 | `*` | kube-apiserver via LB. Restrict source to operator IPs in production. |
| `allow-etcd` | 120 | TCP 2379-2380 | `10.0.1.0/24` (CP subnet) | etcd peer + client traffic; CP-only |
| `allow-kubelet` | 130 | TCP 10250 | `10.0.0.0/16` (VNet) | apiserver → kubelet calls (logs, exec, port-forward) |
| `allow-calico-vxlan` | 140 | UDP 4789 | `10.0.0.0/16` (VNet) | Calico pod-to-pod overlay traffic |
| `allow-nodeports` | 150 | TCP 30000-32767 | `*` | Kubernetes NodePort services |

> ⚠️ **In production, tighten `allow-ssh` and `allow-apiserver` to specific source CIDRs**. Default `*` opens these to the internet.

> ⚠️ **All `az network nsg rule create` commands MUST include `--direction Inbound` and `--source-address-prefix <value>`.** Without them, the CLI emits "expected one argument" errors. This is the most common copy-paste failure in older docs.

### What's NOT in the NSG (and why)

| Port | Why not |
|---|---|
| TCP 4443 (Calico Typha) | Only used if you scale Calico Typha for >250 node clusters |
| UDP 8472 (Flannel VXLAN) | Different CNI; not used here |
| BGP TCP 179 | Calico in VXLAN mode doesn't peer BGP |
| TCP 30000 + UDP 30000 (Spinnaker) | Out of scope |

---

## Pod CIDR vs VNet CIDR

Two separate IP spaces:

| Space | CIDR | Allocated by | Used by |
|---|---|---|---|
| **Azure VNet** | `10.0.0.0/16` | Azure (the VNet resource) | Node primary IPs (`10.0.1.x`, `10.0.2.x`) |
| **Pod CIDR** | `192.168.0.0/16` | Calico IPAM | Per-pod IPs (`192.168.x.x`) |

Each node gets a `/26` slice of the pod CIDR (64 pods per node max). Calico encapsulates pod-to-pod traffic in VXLAN packets (UDP/4789) so the Azure VNet only sees node-to-node traffic; it never has to route the `192.168.x.x` space.

This is intentional: it keeps the Azure VNet's address space small (no need to reserve thousands of IPs for pods) and lets pods communicate without VNet routing tables.

### Alternative: Azure CNI

Azure CNI assigns VNet IPs directly to pods. Pros: no overlay, direct routing, AKS compatibility. Cons:

- You burn a huge slice of VNet address space (one IP per pod, per node, pre-reserved)
- Each node NIC needs N secondary IP configs (where N = max-pods-per-node, default 30)
- Subnet sizing must anticipate max scale

Stick with Calico VXLAN unless you have a specific reason for Azure CNI.

---

## NodePort vs LoadBalancer Service types

### NodePort (works out-of-box)

`Service type: NodePort` opens a TCP port (30000–32767) on **every** worker. Traffic to any worker's IP on that port is forwarded to the service by kube-proxy.

```bash
kubectl expose deployment myapp --port=80 --target-port=8080 --type=NodePort
# Reach via any worker public IP: http://<worker-ip>:<assigned-port>
```

This is what our validation suite (Test 9) uses to confirm NodePort works.

### LoadBalancer (requires external setup)

`Service type: LoadBalancer` normally provisions an Azure LB on demand — but only if **cloud-controller-manager** is running. This repo's base install does **not** include CCM, so LoadBalancer services will sit in `Pending` forever.

If you need LB-backed services, install [cloud-provider-azure](https://github.com/kubernetes-sigs/cloud-provider-azure) and grant the cluster's managed identity the `Network Contributor` role on the resource group. Or front the cluster with an ingress controller (NGINX, Traefik, Contour) and expose only that via a single LB.

---

## DNS

- **CoreDNS** is installed automatically by `kubeadm init`. It listens on cluster IP `10.96.0.10:53` (the default service CIDR).
- All pods are configured to use CoreDNS for DNS resolution (kubelet writes `/etc/resolv.conf` in every pod).
- CoreDNS forwards external lookups to the **node's** upstream resolver — which in Azure is `168.63.129.16` (the Azure-provided DNS).

If your workload needs custom DNS (e.g. an internal company resolver), edit the CoreDNS ConfigMap:

```bash
kubectl -n kube-system edit configmap coredns
```

---

## When kubelet uses the LB vs localhost

After the hairpin workaround, kubelet on every node hits `<LB_IP>:6443` for its apiserver connection. On CP nodes, the iptables NAT rewrites this to `127.0.0.1:6443`, so traffic stays local. On worker nodes, the LB forwards to one of the 3 CPs.

```
kubelet on CP1   --[targets <LB_IP>:6443]--> iptables NAT --> 127.0.0.1:6443 (local apiserver)
kubelet on Worker1 --[targets <LB_IP>:6443]--> Azure SLB --> one of CP1/CP2/CP3:6443
```

The LB rule uses `SourceIP` session affinity, so a given worker tends to stick to the same CP unless that CP fails its health probe.

---

## Pod-to-pod across nodes (Calico VXLAN)

Test 6 in our validation suite proves this works. Here's what happens when pod A on Worker1 curls pod B on Worker2:

1. Pod A sends an IP packet with source `192.168.X.A`, destination `192.168.Y.B`
2. calico-node on Worker1 sees pod B's IP belongs to Worker2's `/26` slice, encapsulates the packet in VXLAN
3. The outer UDP packet (src=Worker1 VNet IP, dst=Worker2 VNet IP, dport=4789) goes through the Azure VNet
4. The NSG `allow-calico-vxlan` rule permits it
5. calico-node on Worker2 receives the VXLAN packet, decapsulates, hands the inner packet to pod B's veth

If pod-to-pod fails, the usual culprit is the NSG rule missing or pointed at the wrong source CIDR.

---

## Reading more

- [Architecture overview](architecture.md) — overall picture
- [VMSS Configuration Reference](../reference/vmss-configuration.md) — Azure-side flags
- [Common Issues](../troubleshooting/common-issues.md) — debug recipes
- [Azure SLB documentation](https://learn.microsoft.com/azure/load-balancer/load-balancer-overview)
- [Calico VXLAN](https://docs.tigera.io/calico/latest/networking/configuring/vxlan-ipip)
