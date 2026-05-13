# Storage: Self-Hosted Kubernetes on VMSS Flex

How storage works on this cluster, what's installed by default, and what you need to add for real workloads.

## TL;DR

- **OS disks**: each node has a 128 GB Premium_LRS managed disk (configurable). That's where containerd images, container layers, and `/var` live. Don't store data here.
- **Pod ephemeral storage**: `/var/lib/kubelet` on the OS disk. Pod `emptyDir` volumes live here.
- **PersistentVolumes**: NOT installed out of the box. The cluster has no CSI driver. `PersistentVolumeClaim` resources will sit in `Pending` until you install one.
- **What to add for real workloads**: [Azure Disk CSI driver](https://github.com/kubernetes-sigs/azuredisk-csi-driver) (RWO block storage) and/or [Azure File CSI driver](https://github.com/kubernetes-sigs/azurefile-csi-driver) (RWX SMB/NFS).

---

## What's there by default

| Storage | Where it lives | Size in this sample |
|---|---|---|
| OS disk (root + containerd) | `/dev/sda` on each node | 128 GB Premium_LRS |
| Container layers | `/var/lib/containerd` | Shared OS disk |
| Pod logs | `/var/log/pods` (symlinked from `/var/lib/docker/containers` style) | Shared OS disk |
| `emptyDir` volumes | `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~empty-dir` | Shared OS disk |
| `hostPath` volumes | Whatever path on the host node | Shared OS disk |
| etcd data | `/var/lib/etcd` on each CP | Shared OS disk |

**OS disk fills up under load** — image pulls, log spam, abandoned containers. Monitor `df -h /var` on every node. Premium_LRS at 128 GB has ample headroom for typical clusters; bump to 256 GB for image-heavy workloads.

---

## Adding PersistentVolume support: Azure Disk CSI driver

[azuredisk-csi-driver](https://github.com/kubernetes-sigs/azuredisk-csi-driver) gives you dynamic provisioning of Azure Managed Disks as PersistentVolumes.

```bash
# Install via Helm
helm repo add azuredisk-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/azuredisk-csi-driver/master/charts
helm install azuredisk-csi-driver azuredisk-csi-driver/azuredisk-csi-driver \
  --namespace kube-system

# Verify
kubectl -n kube-system get pods -l app=csi-azuredisk-controller
kubectl -n kube-system get pods -l app=csi-azuredisk-node
```

You'll also need:
1. **Managed Identity** on the VMSS, with `Contributor` (or a tighter custom role) on the resource group — the CSI controller calls Azure APIs to create disks
2. A `StorageClass` referencing it:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-premium
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
  cachingMode: ReadOnly
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

After that, a PVC with `storageClassName: managed-premium` provisions an Azure Disk on demand and attaches it to the node where its pod schedules.

**Why this isn't in the quickstart**: it requires a managed identity attached to the VMSS, RBAC role assignments, and a non-trivial RBAC story. The base quickstart focuses on a working cluster; storage is a substantial follow-on.

---

## RWX (multi-attach) storage: Azure Files

Azure Managed Disks are **RWO** — only one node can mount them at a time. For shared storage (`ReadWriteMany`), use [azurefile-csi-driver](https://github.com/kubernetes-sigs/azurefile-csi-driver), which mounts Azure File Shares over SMB/NFS.

| Need | Pick |
|---|---|
| RWO, high IOPS, single-pod | Azure Disk (Premium_LRS, P30+) |
| RWO, ultra-low latency | Azure Disk (UltraSSD or Premium v2) |
| RWX, multi-pod, SMB OK | Azure Files (Standard or Premium) |
| RWX, NFS v4.1, POSIX semantics | Azure Files NFS or Azure NetApp Files |

---

## Storage gotchas on Flex VMSS

### 1. Disk attachment latency on instance recreate

When VMSS Flex replaces an instance, the new VM is a fresh resource. Any **data disks** attached to the old instance need to be detached first (the old VM resource is gone, but the disk persists if the old VM was deleted without `--delete-data-disks`). Automating this is annoying.

For most stateful workloads, prefer **CSI-managed dynamic provisioning** — the CSI driver handles attach/detach correctly when pods reschedule. Avoid `azurerm_virtual_machine_data_disk_attachment` to VMSS Flex instances.

### 2. Premium SSD v2 + UltraSSD

Flex orchestration supports both. Uniform mode does NOT support UltraSSD. If you need UltraSSD for I/O-intensive databases, Flex is your only Azure VMSS path.

Caveat: UltraSSD requires the zone-aligned VMSS instance to be in a zone where UltraSSD is available (not all regions/zones). Set `--ultra-ssd-enabled` on the VMSS create.

### 3. Ephemeral OS disks

Default in this sample is **persistent** OS disk (saved on instance recreate). For pure-stateless workers you could switch to **ephemeral** OS disks (local to the host, faster, free):

```hcl
os_disk {
  diff_disk_settings {
    option = "Local"
  }
  caching = "ReadOnly"
  storage_account_type = "Standard_LRS"  # doesn't matter for ephemeral
}
```

Ephemeral disks reset on instance restart. That's fine for kubeadm-bootstrapped workers — they re-join on a fresh boot via cloud-init + manual join. But you lose `/var/log` history and any local state. Not recommended unless you really know you don't need it.

### 4. etcd on the OS disk (CPs)

Our default puts `/var/lib/etcd` on the same 128 GB OS disk as everything else. For clusters with high write rates (1000+ pods churning), separate etcd onto its own disk:

```hcl
data_disk {
  disk_size_gb         = 64
  storage_account_type = "Premium_LRS"
  caching              = "None"   # critical for etcd write durability
  create_option        = "Empty"
  lun                  = 0
}
```

Then mount it at `/var/lib/etcd` before `kubeadm init`. **Caching MUST be `None`** for etcd — `ReadWrite` cache loses writes on power loss.

---

## See also

- [Architecture](architecture.md) — what gets deployed by default
- [Azure Disk CSI driver docs](https://learn.microsoft.com/azure/aks/azure-disk-csi)
- [Azure Files CSI driver docs](https://learn.microsoft.com/azure/aks/azure-files-csi)
- [etcd hardware recommendations](https://etcd.io/docs/v3.5/op-guide/hardware/)
