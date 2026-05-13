# Terraform: Self-Hosted Kubernetes on Azure VMSS Flex

This Terraform module provisions the **infrastructure** for a self-hosted Kubernetes cluster on Azure VMSS Flex (Steps 2–7 of the [quickstart](../../docs/quickstart/deploy-kubeadm-vmss.md)):

- Resource group, VNet with two subnets, NSG with K8s rules
- Standard Load Balancer with a public IP for the apiserver
- 3-instance **control-plane** VMSS Flex, attached to the LB backend pool
- 3-instance **worker** VMSS Flex
- **Node bootstrap via cloud-init**: containerd, kubeadm 1.29.3, sysctl, swap-off are installed at first boot — no separate `az vm run-command` step needed

After `terraform apply` completes, all six nodes are bootstrapped and ready. You then run the [`kubeadm init` → Calico → join](../../docs/quickstart/deploy-kubeadm-vmss.md#step-8-initialize-the-first-control-plane-node) steps over SSH (those steps don't fit cleanly into Terraform's declarative model — see [Why no provisioners?](#why-no-provisioners) below).

---

## Prerequisites

| Tool | Min version |
|---|---|
| Terraform | 1.5+ |
| Azure CLI (for `az login`) | 2.86.0+ |
| SSH key | RSA or Ed25519 keypair |

```bash
az login
az account set --subscription "<your-sub-id>"
```

---

## Usage

```bash
cd K8s-on-vmss/examples/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars to set ssh_public_key_path and any overrides

terraform init
terraform plan
terraform apply -auto-approve
```

Apply takes 8–12 minutes. When it finishes, capture the outputs:

```bash
terraform output -raw lb_public_ip
terraform output -raw cp1_public_ip
terraform output -raw ssh_to_cp1
```

Then **SSH to CP1 and continue with Steps 8–12** of the main quickstart — `kubeadm init`, Calico install, CP joins, worker joins, validation.

> Run-command from your workstation also works (Step 8 of the main quickstart uses `az vm run-command`), but cloud-init has already installed kubeadm/containerd on every node, so SSH is the simplest path.

---

## What's in here

| File | What it does |
|---|---|
| [`versions.tf`](versions.tf) | Pins Terraform and `azurerm` provider versions |
| [`variables.tf`](variables.tf) | All configurable inputs (location, sizes, counts, SSH key path) |
| [`network.tf`](network.tf) | Resource group, VNet, subnets, NSG, rules, subnet associations |
| [`loadbalancer.tf`](loadbalancer.tf) | Public IP + Standard LB (frontend, backend pool, probe, rule) |
| [`controlplane.tf`](controlplane.tf) | Control-plane VMSS Flex, joined to LB backend pool |
| [`workers.tf`](workers.tf) | Worker VMSS Flex |
| [`cloud-init.yaml`](cloud-init.yaml) | Node bootstrap (containerd + kubeadm + kubectl + sysctls) |
| [`outputs.tf`](outputs.tf) | LB IP, CP1 public IP, SSH command, kubeadm-init template |
| [`terraform.tfvars.example`](terraform.tfvars.example) | Starter values |

---

## Why no provisioners?

You'll notice this module **does not** use `null_resource` + `remote-exec` to run `kubeadm init`. That's deliberate:

1. **kubeadm join is order-dependent.** CP1 must init before CP2/CP3 can join as control planes, and they should join sequentially (concurrent CP joins can corrupt etcd quorum). Modeling this as `depends_on` chains works but is brittle.
2. **Joins require runtime data.** The join token is created by `kubeadm token create`, the cert-key by `kubeadm init phase upload-certs --upload-certs`. Both are short-lived (24h and 2h). Terraform has no good way to capture these and feed them to a downstream `remote-exec` without storing them in state.
3. **Provisioner failures are messy.** A failed `remote-exec` leaves Terraform thinking the resource exists but unconfigured. Re-running often requires `terraform taint` + `apply`, which destroys and recreates the VM.

The conventional patterns in production are:
- **Bake everything into the OS image** with Packer / Azure Image Builder, then Terraform just deploys instances of the pre-baked image.
- **Cloud-init for OS-level config**, then a separate run (Ansible, kubespray, or hand-run `kubeadm`) for cluster bootstrap. This module follows that pattern.
- **AKS** if you don't actually need self-management.

---

## Validation

After running `kubeadm init` and joining all nodes, validate from your workstation:

```bash
CP1_PUB=$(terraform output -raw cp1_public_ip)
SSH_KEY=$(terraform output -raw ssh_private_key_path)
ssh -i "$SSH_KEY" "azureuser@$CP1_PUB" 'bash -s' < ../validate-cluster.sh | tee validate.log
grep -E "PASS:|FAIL:|RESULT:" validate.log
```

A healthy cluster reports `RESULT: 13 passed, 0 failed`.

---

## Tear down

```bash
terraform destroy -auto-approve
```

This removes everything in the resource group.

---

## Tested versions

| Component | Version |
|---|---|
| Terraform | 1.15.2 |
| `hashicorp/azurerm` provider | 4.72.0 |
| Ubuntu image | `Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest` (Gen2 — required for v5+/v6 VM SKUs) |
| Kubernetes | 1.29.3 |
| Calico | v3.27.0 |
| Region tested | `northeurope` (also works in others; check SKU availability per region) |
| Tested SKUs | `D4s_v5`/`D8s_v5` (Visual Studio Enterprise sub: not available; use `D2s_v6`/`D4s_v6` instead) |
| Latest result | **13/13** validation tests passed (May 2026, VS Enterprise sub, `D2s_v6`/`D4s_v6` sizing) |

## Sizing for limited subscriptions

The default `controlplane_vm_size = "Standard_D4s_v5"` + `worker_vm_size = "Standard_D8s_v5"` totals **36 vCPU**, exceeding the **20 vCPU** soft default on new MSDN/Visual Studio subscriptions.

For limited-quota subs, set in `terraform.tfvars`:

```hcl
controlplane_vm_size = "Standard_D2s_v6"   # 2 vCPU x 3 = 6
worker_vm_size       = "Standard_D4s_v6"   # 4 vCPU x 3 = 12  → 18 total
```

This module already uses the Gen2 Ubuntu image (`22_04-lts-gen2`) which supports both v5 and v6 SKUs.

## Common deploy errors

| Error | Cause | Fix |
|---|---|---|
| `SkuNotAvailable: 'Standard_D*s_v5' is currently not available in location` | Azure capacity in your region/zone | Switch to v6 SKUs (smaller, often more capacity) or change `location` |
| `OperationNotAllowed: exceeding quota limits` | Default 36 vCPU exceeds new-sub 20 vCPU quota | Use the v6 SKU sizing above |
| `BadRequest: VM size '...' cannot boot Hypervisor Generation '1'` | Image is Gen1 but SKU is Gen2-only (v6+) | This module already uses `22_04-lts-gen2`; if you forked it, switch the `sku` field in `controlplane.tf` and `workers.tf` |
| `prevent_deletion_if_contains_resources` blocks destroy | Azure auto-injected `NRMS-*` NSGs (corp policy subs) | The provider block in [versions.tf](versions.tf) already sets `prevent_deletion_if_contains_resources = false` |
| `kubeadm join` preflight `connection refused` to LB IP | Azure SLB hairpin — CP can't reach its own LB frontend until apiserver is up | Done correctly in the [main quickstart](../../docs/quickstart/deploy-kubeadm-vmss.md) Step 10: install iptables NAT redirect **after** `kubeadm join` completes (not before) |
