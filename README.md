# Self-Hosted Kubernetes on Azure VMSS Flex

> A reference sample for deploying a production-shaped, self-managed Kubernetes 1.29 cluster on Azure Virtual Machine Scale Sets (VMSS) using **Flexible orchestration mode** for both control plane and worker pools.

---

## What you get

- **HA control plane**: 3 instances behind an Azure Standard Load Balancer
- **Worker pool**: 3 instances on VMSS Flex (mix VM sizes, Spot/on-demand)
- **Calico CNI** with VXLAN encapsulation
- **A validation suite** that runs 11 tests (13 assertions): node Ready, etcd quorum, pod-to-pod networking, Service routing, DNS, NodePort reachability, leader election, and apiserver reachability
- **Three deployment paths**: bash CLI, PowerShell, or Terraform

---

## Quick start

Pick your path:

| Path | When to use | Doc |
|---|---|---|
| **Bash CLI** | Linux, macOS, WSL2 — the main tested path | [deploy-kubeadm-vmss.md](docs/quickstart/deploy-kubeadm-vmss.md) |
| **PowerShell** | Windows PowerShell without WSL | [deploy-kubeadm-vmss-powershell.md](docs/quickstart/deploy-kubeadm-vmss-powershell.md) |
| **Terraform** | You want declarative IaC for the infra; manual kubeadm bootstrap follows | [examples/terraform/](examples/terraform/README.md) |

All three deploy the same infrastructure shape (see [architecture concepts](docs/concepts/architecture.md)). The kubeadm bootstrap steps (init, Calico, joins) are run via `az vm run-command` or SSH from your workstation.

**Time to first cluster:** 30–45 minutes (most is Azure provisioning).

---

## Documentation map

### Concepts (read these first)
- [Architecture](docs/concepts/architecture.md) — what gets deployed, why, and how it fails gracefully
- [Networking](docs/concepts/networking.md) — **read this for the Azure SLB hairpin gotcha**, NSG rules, Calico VXLAN
- [What this sample deploys](docs/concepts/when-to-use-this.md) — what you get, what you own after deploy
- [Scaling and lifecycle](docs/concepts/scaling-and-lifecycle.md) — day-2 operations, upgrades, replacements, Spot evictions
- [Storage](docs/concepts/storage.md) — what's there by default, adding Azure Disk/Files CSI
- [Security and identity](docs/concepts/security-and-identity.md) — hardening checklist, what the defaults expose
- [How VMSS powers self-hosted Kubernetes](docs/concepts/vmss-for-kubernetes.md) — Flex orchestration, IMDS, Cluster Autoscaler integration

### Quickstart
- [Deploy with bash CLI](docs/quickstart/deploy-kubeadm-vmss.md) — the main tested guide
- [Deploy with PowerShell](docs/quickstart/deploy-kubeadm-vmss-powershell.md)
- [Deploy with Terraform](examples/terraform/README.md)

### How-To Guides
- [Configure Cluster Autoscaler](docs/how-to/configure-cluster-autoscaler.md)
- [Handle Spot VM Evictions](docs/how-to/handle-spot-evictions.md)
- [Add GPU Worker Nodes](docs/how-to/gpu-nodes-vmss.md)
- [Upgrade Kubernetes](docs/how-to/upgrade-kubernetes.md)
- [Topology-Aware Scheduling](docs/how-to/topology-aware-scheduling.md)

### Reference
- [VMSS Configuration Reference](docs/reference/vmss-configuration.md)

### Troubleshooting
- [Common Issues](docs/troubleshooting/common-issues.md)

---

## Prerequisites Summary

Before you begin, ensure you have the following:

| Prerequisite | Minimum Version | Notes |
|---|---|---|
| Azure subscription | — | Contributor or Owner role on target resource group |
| Azure CLI (`az`) | **2.86.0+** | Earlier versions have a JSON parse bug on `az vmss create --orchestration-mode Flexible`. Run `az upgrade`. |
| `kubectl` | 1.28+ | Must be within one minor version of your cluster |
| `kubeadm` | 1.28+ | Installed on all control plane and worker nodes |
| `containerd` | 1.7+ | Recommended container runtime |
| SSH access | — | Key pair for VM access during bootstrap |

Install the Azure CLI:

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az login
```

Install `kubectl`:

```bash
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

---

## Repository Structure

```
.
├── README.md
├── docs/
│   ├── concepts/
│   │   ├── architecture.md                # what gets deployed
│   │   ├── networking.md                  # NSG, Calico, Azure SLB hairpin
│   │   ├── when-to-use-this.md            # what this sample deploys + what you own
│   │   ├── scaling-and-lifecycle.md       # day-2 operations
│   │   ├── storage.md                     # disks, PVCs, CSI drivers
│   │   ├── security-and-identity.md       # hardening checklist
│   │   └── vmss-for-kubernetes.md         # Flex orchestration internals
│   ├── quickstart/
│   │   ├── deploy-kubeadm-vmss.md             # bash, the main tested path
│   │   └── deploy-kubeadm-vmss-powershell.md  # PowerShell equivalents
│   ├── how-to/
│   │   ├── configure-cluster-autoscaler.md
│   │   ├── handle-spot-evictions.md
│   │   ├── gpu-nodes-vmss.md
│   │   ├── upgrade-kubernetes.md
│   │   └── topology-aware-scheduling.md
│   ├── reference/
│   │   └── vmss-configuration.md
│   └── troubleshooting/
│       └── common-issues.md
└── examples/
    ├── bootstrap-node.sh        # idempotent containerd + kubeadm installer (Step 7)
    ├── validate-cluster.sh      # 11-test / 13-assertion post-deploy validation
    └── terraform/               # Terraform module — same infra, declarative
        ├── README.md
        ├── versions.tf
        ├── variables.tf
        ├── network.tf
        ├── loadbalancer.tf
        ├── controlplane.tf
        ├── workers.tf
        ├── cloud-init.yaml      # node bootstrap baked into VMSS custom_data
        ├── outputs.tf
        └── terraform.tfvars.example
```

---

## Contributing

Pull requests are welcome. For major changes, open an issue first to discuss scope. All commands must be tested against real Azure infrastructure before merging.

## License

MIT
