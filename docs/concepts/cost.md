# Cost: Self-Hosted Kubernetes on VMSS Flex

What this cluster actually costs to run, with concrete numbers from `northeurope` retail pricing (May 2026). Real spend may differ — check the [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) with your subscription discounts.

## TL;DR — default cluster cost

The quickstart's default deployment with 3 CP + 3 worker nodes in northeurope, 24/7:

| Component | Pricing | Monthly cost (730h) |
|---|---|---|
| 3× Standard_D4s_v5 control-plane VMs | ~$0.192/hr each | **~$420** |
| 3× Standard_D8s_v5 worker VMs | ~$0.384/hr each | **~$840** |
| 6× 128 GB Premium_LRS managed disks (P10) | ~$19.71/mo each | **~$118** |
| 6× Standard public IPs (per-VM) | ~$3.65/mo each | **~$22** |
| 1× Standard public IP (LB) | ~$3.65/mo | **~$4** |
| 1× Standard LB (1 rule, ~10 GB egress) | ~$22 base + ~$0.50 egress | **~$23** |
| VNet, NSG, subnets | Free | **$0** |
| **Total** | | **~$1,430/month** ≈ **~$2/hr** |

That's the **raw infrastructure**. It does not include: image pulls (egress data), control-plane Spot risk (if you went Spot), monitoring/log ingestion, Bastion ($140/mo if added), or Azure Files/Disks for PVCs.

## Cost-reduction levers

In rough order of impact:

### 1. Use Spot workers (~70% off, with risk)

Workers don't hold state — they're fine on Spot if you have a [Spot eviction handler](../how-to/handle-spot-evictions.md) and pods can be restarted.

| Worker SKU | On-demand | Spot (current avg) | Savings |
|---|---|---|---|
| D8s_v5 | $0.384/hr | ~$0.077/hr | -80% |
| D16s_v5 | $0.768/hr | ~$0.154/hr | -80% |

3× Spot D8s_v5 workers = **~$169/mo** instead of $840/mo. **Saves ~$670/mo**.

**Do NOT put control plane on Spot.** etcd quorum loss = total cluster outage.

In Terraform, set worker VMSS `priority = "Spot"` + `eviction_policy = "Delete"` + `max_bid_price = -1` (cap at on-demand price).

### 2. Right-size the control plane

D4s_v5 (4 vCPU / 16 GB) is overkill for a 3+3 cluster. Drop to D2s_v5:

| CP SKU | vCPU/RAM | Per-VM cost | 3-CP monthly |
|---|---|---|---|
| D4s_v5 (default) | 4 / 16 | $0.192/hr | $420 |
| D2s_v5 | 2 / 8 | $0.096/hr | **$210** |
| B2s | 2 / 4 | $0.0468/hr | **$102** (burstable; fine for <50 nodes) |

For dev/test, B2s control plane saves ~$320/mo.

### 3. Eliminate per-VM public IPs (~$22/mo)

The quickstart enables `--public-ip-per-vm` so you can SSH directly. Production should disable this and use Azure Bastion + private IPs only.

- Removing 6 public IPs: **saves ~$22/mo**
- Bastion costs ~$140/mo, so this only nets savings if you'd reuse Bastion across multiple clusters

### 4. Reserved Instances or Azure Hybrid Benefit

If you'll run this 24/7 for 1+ year, reservations save 30-50% on the VM compute.

| Term | D8s_v5 saving |
|---|---|
| 1-year RI | ~32% |
| 3-year RI | ~52% |
| Azure Hybrid Benefit (Linux SQL) | varies |

Buy reservations at the **subscription** scope, matching VM size + region. They auto-apply.

### 5. Standard SSD instead of Premium for OS disks

Most CP work is etcd writes (which need Premium). Workers can usually live on Standard_SSD_LRS:

| OS disk | 128 GB monthly |
|---|---|
| Premium_LRS (P10) | $19.71 |
| StandardSSD_LRS (E10) | $9.60 |
| Standard_LRS (S10) | $5.89 |

For 3 workers on StandardSSD: **saves ~$30/mo**, mild IOPS reduction.

### 6. Smaller worker pool when idle

If your workload is bursty, set Cluster Autoscaler with `--nodes=0:10:vmss-k8s-workers`. CA will scale to 0 workers when idle (~$840/mo → ~$0/mo on the worker tier). **Caveats**: scale-from-zero takes 3-5 min per new node, and the first pod waits for cloud-init + kubeadm join. Plan latency budgets accordingly.

### 7. Tear it down when not in use

Dev/test clusters running only during business hours: 8h × 22 weekdays = ~176h/mo, not 730h.

**Savings: 76% of compute** ≈ **~$960/mo for the default sizing**.

Add automation:

```bash
# Stop all VMs at 6pm (deallocates — no compute charge)
for vm in $(az vm list -g rg-k8s-vmss-flex --query "[].name" -o tsv); do
  az vm deallocate -g rg-k8s-vmss-flex -n $vm --no-wait
done

# Start at 8am
for vm in $(az vm list -g rg-k8s-vmss-flex --query "[].name" -o tsv); do
  az vm start -g rg-k8s-vmss-flex -n $vm --no-wait
done
```

Deallocated VMs cost only the OS disk (~$118/mo for our 6 disks). Schedule via Azure Logic Apps or Automation.

> ⚠️ etcd state survives deallocation — disks aren't wiped. **But** kubelet certs and apiserver certs have time-bound validity (1 year by default for client certs, 1 year for serving). Long-deallocated clusters may have expired certs when restarted. `kubeadm certs check-expiration` shows status.

---

## Realistic monthly budgets

| Profile | Sizing | Monthly |
|---|---|---|
| **Dev/test, 8h/day** | 3× B2s CP + 3× D2s_v5 workers, public IPs off, StandardSSD, business hours only | **~$100-150** |
| **Small prod cluster (24/7)** | 3× D2s_v5 CP + 3× D4s_v5 workers, Premium, on-demand | **~$650** |
| **Quickstart default (24/7)** | 3× D4s_v5 + 3× D8s_v5, Premium, on-demand, per-VM public IPs | **~$1,430** |
| **Spot workers prod** | 3× D2s_v5 CP + 3× D8s_v5 Spot workers, 24/7 | **~$380** |
| **High-end prod** | 3× D8s_v5 CP + 12× D16s_v5 workers, Premium, on-demand | **~$3,800** |

---

## What else costs money in the cluster

Beyond compute/storage/networking, watch for:

| Source | Pricing | Notes |
|---|---|---|
| Egress data | $0.087/GB after first 100 GB | Image pulls, syslog forwarding, cross-region traffic |
| Azure Monitor log ingestion | $2.30/GB | If you forward kubelet/apiserver logs |
| Azure Files (RWX PVCs) | $0.06/GB Premium, $0.0255/GB Standard | Plus transactions |
| Azure Disk (RWO PVCs) | Same as OS disks above | Plus reservation cost if dynamically provisioned |
| Bastion | $140/mo + $0.087/GB outbound | Only if you add it |
| Image Builder runs | ~$1 per image build (compute + storage) | Only if you bake custom images |

---

## Cost monitoring

Tag every resource for cost allocation:

```hcl
# In Terraform (already in our variables.tf)
tags = {
  workload       = "self-hosted-kubernetes"
  costCenter     = "engineering"
  environment    = "dev"
  owner          = "platform-team"
}
```

Then enable [Azure Cost Management](https://portal.azure.com/#blade/Microsoft_Azure_CostManagement) > Cost Analysis filtered by tag. Set a **budget with alerts** at 80% and 100% — surprise $5k bills are real on self-hosted clusters that get forgotten.

---

## See also

- [Architecture](architecture.md) — what resources exist
- [Scaling and Lifecycle](scaling-and-lifecycle.md) — when costs scale up
- [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)
- [Spot VM pricing](https://azure.microsoft.com/pricing/details/virtual-machines/linux/) — see "Spot" tab
