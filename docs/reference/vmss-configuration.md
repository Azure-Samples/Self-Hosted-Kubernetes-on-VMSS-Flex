# VMSS Configuration Reference for Kubernetes

This reference covers recommended VMSS settings, supported VM SKUs, instance metadata fields, Cluster Autoscaler tags, Azure RBAC permissions, and VMSS limits relevant to self-hosted Kubernetes deployments.

---

## Recommended VMSS Settings for Kubernetes

### Orchestration Mode

Always use **Flexible** orchestration mode for new Kubernetes deployments.

```bash
az vmss create \
  --orchestration-mode Flexible \
  --platform-fault-domain-count 1 \
  ...
```

`--platform-fault-domain-count 1` places all instances in a single fault domain, which is standard for Kubernetes worker pools that rely on Kubernetes for HA rather than Azure fault domain distribution.

### Health Probes

Configure the Application Health Extension to report node health. The VMSS uses this for automatic instance repair.

```json
{
  "extensionProfile": {
    "extensions": [
      {
        "name": "ApplicationHealthLinux",
        "properties": {
          "publisher": "Microsoft.ManagedServices",
          "type": "ApplicationHealthLinux",
          "typeHandlerVersion": "1.0",
          "settings": {
            "protocol": "tcp",
            "port": 10248,
            "requestPath": "/healthz"
          }
        }
      }
    ]
  }
}
```

Port 10248 is the kubelet health check endpoint. This ensures VMSS considers a node unhealthy only when kubelet itself is unreachable.

Via CLI:

```bash
az vmss extension set \
  --resource-group $RESOURCE_GROUP \
  --vmss-name $WORKER_VMSS_NAME \
  --name ApplicationHealthLinux \
  --publisher Microsoft.ManagedServices \
  --version 1.0 \
  --settings '{"protocol":"tcp","port":10248,"requestPath":"/healthz"}'
```

### Scale-In Policy

| Policy | Behavior | Recommended For |
|---|---|---|
| `Default` | Balance across fault/update domains | General worker pools |
| `NewestVM` | Delete most recently created VM | Spot pools (removes newest, least-settled nodes) |
| `OldestVM` | Delete oldest VM | Pools managed by manual upgrade scripts |

For Cluster Autoscaler-managed pools, CA selects the specific instance to delete — the VMSS scale-in policy only applies to Azure-native autoscale actions:

```bash
az vmss update \
  --resource-group $RESOURCE_GROUP \
  --name $WORKER_VMSS_NAME \
  --scale-in-policy NewestVM
```

### Automatic Instance Repair

Enable automatic repair with a sufficient grace period to prevent VMSS from deleting a node before Kubernetes has had time to restart kubelet:

```bash
az vmss update \
  --resource-group $RESOURCE_GROUP \
  --name $WORKER_VMSS_NAME \
  --enable-automatic-repairs true \
  --automatic-repairs-grace-period 30  # minutes
```

**Minimum recommended grace period: 30 minutes.** Setting it too low causes VMSS to delete nodes that are temporarily unreachable during upgrades or transient disruptions.

### Overprovisioning

Disable overprovisioning for Kubernetes. Overprovisioning creates extra VMs during scale-out and deletes them once the new instances are healthy, which confuses the Kubernetes node lifecycle:

```bash
az vmss update \
  --resource-group $RESOURCE_GROUP \
  --name $WORKER_VMSS_NAME \
  --set singlePlacementGroup=false \
  --set overprovision=false
```

---

## Instance Metadata Fields Relevant to Kubernetes

All fields accessible at `http://169.254.169.254/metadata/instance/compute?api-version=2021-12-13`.

| Field | K8s Usage | Example Value |
|---|---|---|
| `subscriptionId` | ProviderID construction | `a1b2c3d4-...` |
| `resourceGroupName` | ProviderID, cloud provider config | `rg-k8s-vmss-prod` |
| `name` | Node hostname / ProviderID (Flexible mode) | `vmss-k8s-workers_0` |
| `vmId` | Unique VM identifier | `xxxxxxxx-xxxx-...` |
| `vmScaleSetName` | Cluster Autoscaler node group discovery | `vmss-k8s-workers` |
| `location` | `topology.kubernetes.io/region` label | `eastus2` |
| `zone` | `topology.kubernetes.io/zone` label | `2` |
| `platformFaultDomain` | Custom topology labels | `0` |
| `platformUpdateDomain` | Custom topology labels | `0` |
| `sku` | Node instance type labeling | `Standard_D8s_v5` |
| `proximityPlacementGroupId` | Topology-aware scheduling | `/subscriptions/.../ppg-gpu-training` |
| `storageProfile.osDisk.managedDisk.storageAccountType` | Storage class configuration | `Premium_LRS` |

Scheduled Events endpoint: `http://169.254.169.254/metadata/scheduledevents?api-version=2020-07-01`

| Event Type | Meaning | Handler Action |
|---|---|---|
| `Terminate` | VM will be deleted | Drain + cordon |
| `Preempt` | Spot VM eviction | Drain + cordon |
| `Reboot` | Planned maintenance reboot | Optional: drain |
| `Redeploy` | VM moving to different host | Optional: drain |
| `Freeze` | Brief pause for live migration | Usually no action needed |

---

## VMSS Tags Used by Cluster Autoscaler

> ⚠️ **Azure does NOT use the AWS-style `k8s.io/cluster-autoscaler/*` tag scheme.** Azure rejects tag names containing `/` as `InvalidTagNameCharacters`. Some unofficial guides still recommend those tags — they will fail at VMSS creation time.

### Discovery options for the Azure Cluster Autoscaler

The Azure Cluster Autoscaler (cloud-provider-azure) has two ways to discover VMSS node groups:

| Method | How | When to use |
|---|---|---|
| **Explicit `--nodes` flag** (recommended) | `--nodes=<min>:<max>:<vmss-name>` repeated per VMSS, on the CA Deployment | Single cluster, few VMSS pools — simplest setup |
| **Tag-based auto-discovery** | `--node-group-auto-discovery=label:<key>=<value>` plus a matching Azure-safe tag on each VMSS | Many VMSS pools, automatic discovery of new pools |

For auto-discovery, set Azure-safe tags on the VMSS (no `/` in keys, no reserved characters in values):

| Tag Key | Value | Purpose |
|---|---|---|
| `cluster-autoscaler-enabled` | `"true"` | CA discovery (with matching `--node-group-auto-discovery=label:cluster-autoscaler-enabled=true`) |
| `cluster-autoscaler-cluster` | `<cluster-name>` | Identify which cluster owns this VMSS |

### Optional resource-hint tags

For scale-from-zero, CA needs to know what a new node will provide before any instance exists. Azure-safe key naming:

| Tag Key | Value | Purpose |
|---|---|---|
| `cluster-autoscaler-cpu` | `"8"` | vCPU count hint |
| `cluster-autoscaler-memory` | `"32Gi"` | Memory hint |
| `cluster-autoscaler-gpu` | `"4"` | GPU count hint |

The CA reads these via the cloud-provider-azure plugin's tag normalization. Verify your CA version supports the tag keys you set — see [the official docs](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/azure/README.md).

---

## Supported VM SKUs for Kubernetes Worker Nodes

> 📝 **Hypervisor generation matters.** v5 SKUs support both Gen1 and Gen2 images (`Ubuntu2204` alias is Gen1; `22_04-lts-gen2` is Gen2). v6 SKUs are **Gen2-only**. If you see `BadRequest: VM size 'Standard_D*s_v6' cannot boot Hypervisor Generation '1'`, switch the image SKU to `22_04-lts-gen2`.

### General Purpose (Recommended for most workloads)

| SKU | vCPUs | RAM | Hypervisor | Notes |
|---|---|---|---|---|
| Standard_D2s_v6 | 2 | 8 GiB | Gen2 | Smallest CP node — fits 20-vCPU MSDN/VS Enterprise quota |
| Standard_D4s_v6 | 4 | 16 GiB | Gen2 | Smallest dev/test worker |
| Standard_D2s_v5 | 2 | 8 GiB | Gen1+Gen2 | Smallest CP node, where v5 SKU is available |
| Standard_D4s_v5 | 4 | 16 GiB | Gen1+Gen2 | Control plane (default for the quickstart), light workers |
| Standard_D8s_v5 | 8 | 32 GiB | Gen1+Gen2 | Standard worker (default for the quickstart) |
| Standard_D16s_v5 | 16 | 64 GiB | Gen1+Gen2 | Heavier workloads |
| Standard_D32s_v5 | 32 | 128 GiB | Gen1+Gen2 | Large pod capacity |
| Standard_D48s_v5 | 48 | 192 GiB | Gen1+Gen2 | Large pod capacity |

> Capacity availability varies by region. If `az vmss create` returns `SkuNotAvailable`, try a different region or switch v5↔v6.

### Memory Optimized

| SKU | vCPUs | RAM | Notes |
|---|---|---|---|
| Standard_E8s_v5 | 8 | 64 GiB | In-memory caches, databases |
| Standard_E16s_v5 | 16 | 128 GiB | Large in-memory workloads |
| Standard_E32s_v5 | 32 | 256 GiB | Very large in-memory workloads |

### GPU

| SKU | vCPUs | GPU | GPU Memory | Use Case |
|---|---|---|---|---|
| Standard_NC4as_T4_v3 | 4 | 1x T4 | 16 GB | Light inference |
| Standard_NC16as_T4_v3 | 16 | 4x T4 | 64 GB | Inference |
| Standard_NC24ads_A100_v4 | 24 | 1x A100 | 80 GB | Training/inference |
| Standard_NC96ads_A100_v4 | 96 | 4x A100 | 320 GB | Multi-GPU training |
| Standard_ND96asr_v4 | 96 | 8x A100 + IB | 640 GB | Distributed training |
| Standard_ND96isr_H100_v5 | 96 | 8x H100 + IB | 640 GB | Large model training |

---

## VMSS Limits

| Resource | Limit | Notes |
|---|---|---|
| Max instances per VMSS (Flexible) | 1,000 | Per VMSS resource |
| Max instances per VMSS (Uniform) | 1,000 | Per VMSS resource |
| Max VMSS per subscription (per region) | 2,500 | Soft limit, requestable |
| Max NICs per VM | Varies by SKU | D8s_v5: 4 NICs |
| Max data disks per VM | Varies by SKU | D8s_v5: 16 data disks |
| VMSS scale operation timeout | 10 minutes | Default ARM operation timeout |
| Cluster Autoscaler max node provision time | 15 minutes (configurable) | Set via `--max-node-provision-time` |

---

## Required Azure RBAC Permissions for Kubernetes Automation

### Cluster Autoscaler (Managed Identity)

Minimum permissions on the resource group containing the VMSS:

| Role | Scope | Purpose |
|---|---|---|
| `Virtual Machine Contributor` | Resource group | Create, delete, reimage VMSS instances |
| `Reader` | Resource group | List VMSS and VM resources |

Custom role (minimum permissions):

```json
{
  "Name": "Kubernetes Cluster Autoscaler",
  "Description": "Minimum permissions for K8s Cluster Autoscaler on VMSS",
  "Actions": [
    "Microsoft.Compute/virtualMachineScaleSets/read",
    "Microsoft.Compute/virtualMachineScaleSets/write",
    "Microsoft.Compute/virtualMachineScaleSets/virtualmachines/read",
    "Microsoft.Compute/virtualMachineScaleSets/virtualmachines/write",
    "Microsoft.Compute/virtualMachineScaleSets/virtualmachines/delete",
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Network/networkInterfaces/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
  ],
  "NotActions": [],
  "AssignableScopes": ["/subscriptions/<subscription-id>"]
}
```

### Azure Cloud Controller Manager

| Role | Scope | Purpose |
|---|---|---|
| `Virtual Machine Contributor` | Resource group | Node lifecycle management |
| `Network Contributor` | VNet resource group | Load balancer management |
| `Storage Blob Data Contributor` | Storage account | CSI driver (if used) |

### Node Bootstrap (kubeadm join automation)

If using automation to bootstrap nodes (custom script extension or cloud-init), the automation identity needs:

| Role | Scope | Purpose |
|---|---|---|
| `Reader` | Resource group | Read cluster metadata |
| `Key Vault Secrets User` | Key Vault | Read bootstrap tokens (if stored in KV) |
