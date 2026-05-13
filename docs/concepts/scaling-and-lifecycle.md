# Scaling and Lifecycle: Self-Hosted Kubernetes on VMSS Flex

Day-2 operations: how the cluster scales, how nodes get replaced, how you upgrade, what breaks during a rolling event, and the Flex-specific quirks you need to know.

## TL;DR

- **Worker scaling**: bump `instances = N` in Terraform (or `az vmss scale --new-capacity N`). New instances come up with cloud-init bootstrap done; you still need to `kubeadm join` them.
- **Control plane scaling**: typically you don't. 3 is the standard quorum; 5 is for very large clusters. Going from 3 → 5 requires a serial `kubeadm join --control-plane` on each new instance.
- **Node replacement** (failed instance, OS upgrade): delete the VM, VMSS Flex creates a new one with cloud-init, run `kubeadm join` on the new instance. The cluster does **not** auto-join — you choreograph it.
- **K8s minor version upgrades**: sequential `kubeadm upgrade apply` on CP1 → `kubeadm upgrade node` on CP2/CP3 → drain workers and `kubeadm upgrade node` per worker. ~30-90 minutes for the full sequence.
- **Spot evictions**: 30 seconds notice via IMDS Scheduled Events. Workers running [a handler](../how-to/handle-spot-evictions.md) cordon + drain themselves; without one, pods on evicted nodes die abruptly.

---

## Scaling the worker pool

### Manual scale-up (most common)

```bash
# Terraform path — bump worker count
# In terraform.tfvars:
worker_instance_count = 6
# Then:
terraform apply
```

```bash
# CLI path
az vmss scale --resource-group rg-k8s-vmss-flex \
  --name vmss-k8s-workers --new-capacity 6
```

VMSS Flex creates the new VMs immediately. Cloud-init bootstraps them (containerd + kubeadm installed). **They are not joined to the cluster yet** — Kubernetes doesn't see them.

To join the new workers, get a fresh token from any CP and run `kubeadm join` on each new instance. The [main quickstart Step 11](../quickstart/deploy-kubeadm-vmss.md#step-11-join-the-worker-nodes-in-parallel) shows the pattern.

### Manual scale-down

```bash
# 1. Pick a worker to remove. NEVER pick CP1/2/3 — they hold etcd quorum.
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node-name>

# 2. Delete the VMSS instance
az vmss delete-instances --resource-group rg-k8s-vmss-flex \
  --name vmss-k8s-workers --instance-ids <vm-id>
```

**Order matters.** Drain before deleting the VM, otherwise pods on that worker die without RollingUpdate honoring PDBs. The deleted node still appears in `kubectl get nodes` for ~5 min after the VM is gone — kubectl-delete it to clean up.

### Automated scale (Cluster Autoscaler)

[Install Cluster Autoscaler](../how-to/configure-cluster-autoscaler.md). CA does drain-then-delete automatically based on pending pods. You configure `--nodes=<min>:<max>:vmss-k8s-workers` on the CA deployment.

**Do not also enable Azure Autoscale on the same VMSS.** It races with CA and produces unpredictable scaling.

### What Flex orchestration changes about scale

| Behavior | Uniform mode | Flex mode |
|---|---|---|
| Instance naming | Predictable indexes (`vmss-k8s-workers_0`, `_1`, …) | Stamped suffix (`vmss-k8s-workers_a832b2ab`) |
| Delete-by-index | `--instance-ids 3` works | `--instance-ids <stamped-id>` |
| Mixed VM sizes in one pool | ❌ | ✅ (use `azurerm_orchestrated_virtual_machine_scale_set` with `sku_profile`) |
| Spot + on-demand in one pool | ❌ | ✅ via priority mix |
| Per-VM lifecycle (start/stop individuals) | ❌ | ✅ each VM is a standard `Microsoft.Compute/virtualMachines` resource |

For Kubernetes node pools, **the stamped names matter**: any automation that iterates instances must enumerate via `az vm list` rather than assuming index 0..N.

---

## Scaling the control plane

### Why 3 is usually enough

etcd uses Raft consensus. The quorum table:

| etcd members | Failures tolerated |
|---|---|
| 1 | 0 (any failure = total outage) |
| 3 | 1 |
| 5 | 2 |
| 7 | 3 |

3 is the standard tradeoff. Go to 5 only if:
- You expect frequent zone-level events and need to survive 2 simultaneous failures
- You have 1000+ nodes and apiserver request load needs the extra capacity
- Your compliance baseline mandates it

**Don't run an even number** (2, 4, 6) — even-member clusters tolerate the **same** number of failures as odd-1, but cost more.

### Adding a 4th/5th CP node

```bash
# 1. Bump CP VMSS instance count to 5
az vmss scale -g rg-k8s-vmss-flex -n vmss-k8s-controlplane --new-capacity 5

# 2. On any existing CP, generate fresh CP-join material (tokens expire in 24h, certs in 2h)
JOIN=$(sudo kubeadm token create --print-join-command)
CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs 2>&1 | tail -1)

# 3. On EACH new CP instance, sequentially (NOT in parallel):
sudo iptables -t nat -A OUTPUT -p tcp -d <LB_IP> --dport 6443 \
  -j DNAT --to-destination 127.0.0.1:6443
sudo $JOIN --control-plane --certificate-key $CERT_KEY \
  --apiserver-advertise-address "$(hostname -I | awk '{print $1}')"
```

Then wait for the new etcd member to sync (~30 sec, look for `is now part of the cluster` in journal).

### Removing a CP node

This is risky. Done wrong, you lose quorum.

```bash
# 1. On any CP, remove the etcd member first
ETCD_POD=$(kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec $ETCD_POD -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list

# Find the member ID of the CP you want to remove, then:
kubectl -n kube-system exec $ETCD_POD -- etcdctl ... member remove <member-id>

# 2. On the CP being removed, run kubeadm reset
sudo kubeadm reset --force

# 3. Delete the node from Kubernetes
kubectl delete node <node-name>

# 4. Delete the VMSS instance
az vmss delete-instances -g rg-k8s-vmss-flex \
  -n vmss-k8s-controlplane --instance-ids <vm-id>
```

> ⚠️ **Never delete more than one CP at a time.** etcd quorum requires `(N/2)+1` members, so on a 3-node cluster removing 2 simultaneously means total cluster loss.

---

## Node replacement (failure + auto-repair)

VMSS Flex with [Automatic Instance Repair](https://learn.microsoft.com/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-automatic-instance-repairs) can recreate unhealthy instances automatically.

**By default this is disabled** in our quickstart's Terraform. To enable on the worker pool:

```hcl
resource "azurerm_orchestrated_virtual_machine_scale_set" "workers" {
  # ... existing config ...
  automatic_instance_repair {
    enabled      = true
    grace_period = "PT10M"      # wait 10 min after unhealthy before recreating
    action       = "Replace"     # delete + recreate (vs Restart, Reimage)
  }

  # Required: Application Health extension reporting back to VMSS
  extension {
    name                 = "AppHealthLinux"
    publisher            = "Microsoft.ManagedServices"
    type                 = "ApplicationHealthLinux"
    type_handler_version = "1.0"
    settings             = jsonencode({ protocol = "tcp", port = 10250 })
  }
}
```

The catch: **VMSS auto-repair doesn't talk to Kubernetes.** When VMSS replaces a worker, the new instance has cloud-init done but is **not joined to the cluster**. Kubernetes still has the dead node in `kubectl get nodes`, and the new VM is invisible.

To make this actually work, you need:
- A small **node-join daemon** running on each new instance that detects "I am freshly booted, not joined" → fetches a kubeadm token (from somewhere) → joins itself
- OR a controller (like Cluster API Provider for Azure) that watches both Azure events and Kubernetes events and orchestrates joins

For the base quickstart we leave auto-repair off. Manual replacement is:

```bash
# Failed worker `vmss-k8s-workers_xyz`
# 1. Drain in K8s (best effort — it may already be gone)
kubectl drain vmss-k8s-wkXYZ --ignore-daemonsets --delete-emptydir-data --force --timeout=120s
kubectl delete node vmss-k8s-wkXYZ

# 2. Delete the VMSS instance
az vmss delete-instances -g rg-k8s-vmss-flex -n vmss-k8s-workers --instance-ids xyz

# 3. Scale back up
az vmss scale -g rg-k8s-vmss-flex -n vmss-k8s-workers --new-capacity 3

# 4. Get the new instance name; join it manually
NEW_VM=$(az vm list -g rg-k8s-vmss-flex --query "[?contains(name,'workers')] | [-1].name" -o tsv)
# Run kubeadm join (see Step 11 of the quickstart)
```

---

## Kubernetes version upgrades

The full procedure is in [docs/how-to/upgrade-kubernetes.md](../how-to/upgrade-kubernetes.md). High-level shape:

```
For each CP, sequentially (CP1 first):
  apt-get install kubeadm=<new-version>
  sudo kubeadm upgrade plan
  sudo kubeadm upgrade apply <new-version>      # CP1 only
  sudo kubeadm upgrade node                      # CP2, CP3
  apt-get install kubelet=<new-version> kubectl=<new-version>
  systemctl restart kubelet

For each worker, sequentially (drain first):
  kubectl drain <worker> --ignore-daemonsets --delete-emptydir-data
  apt-get install kubeadm=<new-version>
  sudo kubeadm upgrade node
  apt-get install kubelet=<new-version>
  systemctl restart kubelet
  kubectl uncordon <worker>
```

Time budget: **~5-10 min per node**, sequential. A 3+3 cluster takes 30-60 min to fully upgrade.

**Skip versions at your own risk.** kubeadm officially supports N → N+1 (not N → N+2). For 1.29 → 1.31 you must go through 1.30.

---

## Spot VM eviction

Workers running on Azure Spot instances can be evicted with **30 seconds notice**. The notice arrives via [IMDS Scheduled Events](https://learn.microsoft.com/azure/virtual-machines/linux/scheduled-events):

```bash
curl -s -H "Metadata: true" \
  "http://169.254.169.254/metadata/scheduledevents?api-version=2020-07-01"
```

Pending evictions look like:

```json
{ "Events": [ { "EventType": "Preempt", "Resources": ["<vm-name>"],
                "EventStatus": "Scheduled", "NotBefore": "..." } ] }
```

Without a handler, the node disappears mid-flight; pods on it die abruptly. The fix is a **DaemonSet** that polls IMDS and runs `kubectl drain` when it sees a `Preempt` event for its own VM. Full pattern + manifests: [handle-spot-evictions.md](../how-to/handle-spot-evictions.md).

**Cost vs. risk**: Spot saves ~70% but you get fewer than 30s to drain. Suitable for:
- Stateless workloads with multiple replicas
- Batch jobs that can be retried
- Dev/test environments

Not suitable for:
- Stateful services (etcd, databases, anything with a PVC)
- Anything with strict SLOs

Mix on-demand and Spot in one Flex VMSS via priority_mix.

---

## What breaks during routine events

| Event | Cluster impact | Recovery |
|---|---|---|
| One CP node reboots (planned maintenance) | etcd quorum drops to 2/3 momentarily. LB removes the rebooting CP from rotation. Apiserver still serves. | Auto-rejoin when VM comes back |
| One worker node reboots | Pods on that worker go Unknown then Lost (~5 min kubelet timeout). Pods reschedule elsewhere. | Auto when VM rejoins |
| Azure SLB hairpin re-bites after iptables flush | kubelet on every CP can't reach apiserver via LB. apiserver-via-LB returns 000. | Re-apply iptables NAT rule (`iptables-persistent` saves it across reboots) |
| Calico calico-node DaemonSet pod restarts | Brief loss of pod-to-pod networking on that node (~30s) | Auto |
| etcd leader changes (every ~20s under load) | None visible | N/A |
| Whole zone outage (3 AZ region) | If CPs are zone-redundant: 2/3 down → quorum lost → apiserver read-only | Restore from etcd backup |
| Quota exhaustion during scale-up | New instances stuck `Failed` in VMSS; CA logs `OverConstrainedZonalAllocation` or `QuotaExceeded` | Request quota increase |

---

## Operational checklists

### Before scaling production

- [ ] Confirm regional vCPU quota covers the new capacity
- [ ] Confirm subnet has IP space (`/24` = 251 usable; subtract Azure reserves)
- [ ] Confirm pod CIDR has block-allocator headroom (each node consumes a `/26` from the Calico pool)
- [ ] If using Spot: confirm eviction handler is running on every new instance

### Before upgrading

- [ ] Take an etcd snapshot
- [ ] Verify no in-progress PodDisruptionBudgets
- [ ] Drain a canary node first; observe for 1 cycle
- [ ] Have rollback plan documented (kubeadm versions are pinned; `apt-get install kubeadm=<old>` reverts)

### After a node failure

- [ ] Confirm replacement instance is joined (`kubectl get nodes` shows it)
- [ ] Confirm calico-node DaemonSet placed a pod on it
- [ ] Drain + uncordon to flush stale taints

---

## See also

- [VMSS for Kubernetes](vmss-for-kubernetes.md) — how VMSS APIs interact with kubelet/CA
- [Networking](networking.md) — Calico VXLAN, NSG rules, LB hairpin
- [Configure Cluster Autoscaler](../how-to/configure-cluster-autoscaler.md)
- [Handle Spot Evictions](../how-to/handle-spot-evictions.md)
- [Upgrade Kubernetes](../how-to/upgrade-kubernetes.md)
