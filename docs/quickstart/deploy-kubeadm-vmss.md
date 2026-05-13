# Quickstart: Deploy a Highly Available Kubernetes Cluster on Azure VMSS Flex

This quickstart builds a production-shaped, self-managed Kubernetes 1.29 cluster on Azure using **Virtual Machine Scale Sets with Flexible orchestration** for both the control plane and the worker pool. You'll get:

- 3-node HA control plane fronted by an Azure Standard Load Balancer
- 3-node worker pool, both pools as **VMSS Flex** (independent VM lifecycles, mixed-zone capable, FD-aware)
- Calico CNI with VXLAN encapsulation
- A working cluster verified by an 11-test smoke suite

**Time to complete:** 30–45 minutes (most of that is `az` provisioning).

**Tested:** Azure CLI 2.86.0, Ubuntu 22.04 LTS, Kubernetes 1.29.3, Calico v3.27.0, region `northeurope` (May 2026).

> **Why VMSS Flex for the control plane?** Most upstream `kubeadm` guides put control-plane nodes on standalone VMs because each CP needs a stable hostname/IP for sequential `kubeadm init` and `kubeadm join`. Flex works equally well — you simply target each VMSS instance by its full VM name (e.g. `vmss-k8s-controlplane_4fc08081`) when running per-node steps. Flex gives you uniform fault-domain spreading, a single resource to scale, and consistent tagging across CP and worker pools. The tradeoff: instance names are stamped (not predictable), so any automation needs to enumerate them via `az vm list` rather than assuming `vm-controlplane-01`/`02`/`03`.

---

## Prerequisites

| Tool | Min version | Install |
|---|---|---|
| Azure subscription | — | Contributor or Owner on target resource group |
| Azure CLI (`az`) | **2.86.0+** | `az upgrade` |
| `kubectl` | 1.28+ | [Install kubectl](https://kubernetes.io/docs/tasks/tools/) |
| SSH key | — | `ssh-keygen -t rsa -b 4096 -f ~/.ssh/k8s_vmss` |
| Shell | bash, zsh, or PowerShell | All examples below are POSIX shell; a PowerShell equivalents block follows Step 1 |

Confirm CLI version and login:

```bash
az version --query '"azure-cli"' -o tsv   # must be >= 2.86.0
az login
```

> ⚠️ **Azure CLI < 2.86.0 had a bug** that broke `az vmss create --orchestration-mode Flexible` with `Extra data: line 1 column 4` JSON parse errors. If you're stuck on an older CLI, upgrade with `az upgrade` before continuing.

---

## Step 1: Set deployment variables

```bash
export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export RESOURCE_GROUP="rg-k8s-vmss-flex"
export LOCATION="northeurope"               # any region with Standard LB + zonal VMSS Flex
export CLUSTER_NAME="k8s-vmss-flex"
export VNET_NAME="vnet-k8s"
export SUBNET_CONTROL="snet-controlplane"
export SUBNET_WORKER="snet-workers"
export NSG_NAME="nsg-k8s"
export LB_NAME="lb-k8s-apiserver"
export LB_IP_NAME="pip-k8s-apiserver"
export CONTROL_VMSS_NAME="vmss-k8s-controlplane"
export WORKER_VMSS_NAME="vmss-k8s-workers"
export CONTROL_VM_SIZE="Standard_D4s_v5"
export WORKER_VM_SIZE="Standard_D8s_v5"
export K8S_VERSION="1.29.3"
export ADMIN_USER="azureuser"
export SSH_KEY_PATH="$HOME/.ssh/k8s_vmss.pub"
```

> 📝 **Sizing for limited subscriptions.** The defaults total **36 vCPU** (12 CP + 24 worker), which exceeds the typical **20 vCPU** soft default on new MSDN/Visual Studio subscriptions. If `terraform apply` or `az vmss create` returns `OperationNotAllowed: Operation results in exceeding quota limits`, either:
>
> - **Right-size for 20 vCPU** (validated in our test runs):
>   ```bash
>   export CONTROL_VM_SIZE="Standard_D2s_v6"   # 2 vCPU x 3 = 6
>   export WORKER_VM_SIZE="Standard_D4s_v6"    # 4 vCPU x 3 = 12  → 18 total
>   ```
>   This matches the "Small prod cluster" profile in [cost concepts](../concepts/cost.md).
>
> - **Or** request a quota increase: `az vm list-usage -l <region>` shows current limits; portal → Subscriptions → Usage + quotas → request more.
>
> Note: v6 SKUs require **Generation 2** images (the doc uses `Ubuntu2204` which is Gen1, fine for v5). For v6, change `--image Ubuntu2204` to `--image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest` in Steps 5 and 6.

<details>
<summary>PowerShell equivalents (and Windows gotchas)</summary>

```powershell
$env:SUBSCRIPTION_ID    = (az account show --query id -o tsv)
$env:RESOURCE_GROUP     = "rg-k8s-vmss-flex"
$env:LOCATION           = "northeurope"
$env:CLUSTER_NAME       = "k8s-vmss-flex"
$env:VNET_NAME          = "vnet-k8s"
$env:SUBNET_CONTROL     = "snet-controlplane"
$env:SUBNET_WORKER      = "snet-workers"
$env:NSG_NAME           = "nsg-k8s"
$env:LB_NAME            = "lb-k8s-apiserver"
$env:LB_IP_NAME         = "pip-k8s-apiserver"
$env:CONTROL_VMSS_NAME  = "vmss-k8s-controlplane"
$env:WORKER_VMSS_NAME   = "vmss-k8s-workers"
$env:CONTROL_VM_SIZE    = "Standard_D4s_v5"
$env:WORKER_VM_SIZE     = "Standard_D8s_v5"
$env:K8S_VERSION        = "1.29.3"
$env:ADMIN_USER         = "azureuser"
$env:SSH_KEY_PATH       = "$HOME\.ssh\k8s_vmss.pub"
```

**Known PowerShell gotchas — read this if you're not using bash/WSL:**

- **Env-var dropouts.** PowerShell drops `$env:*` variables when a long-running `az` command returns after a session timeout. Save the block above to `env.ps1` and dot-source it (`. .\env.ps1`) before every command.
- **JMESPath pipes and brackets break.** Queries like `--query "[?contains(name,'controlplane')]|[0].name"` work in bash but fail in PowerShell because `az.cmd` re-parses the command line through `cmd.exe`, which mangles `|`, `?`, and `[` inside double-quoted strings. **Workaround:** fetch the list as JSON and filter in PowerShell instead:

  ```powershell
  $allVms = az vm list -g $env:RESOURCE_GROUP -o json | ConvertFrom-Json
  $cp1 = ($allVms | Where-Object { $_.name -like '*controlplane*' } |
          Select-Object -ExpandProperty name -First 1)
  ```
- **SSH key passphrase.** When generating an SSH key in PowerShell, use empty-string syntax `-N ""`, not `-N '""'` — the latter creates a key with the literal two-character `""` passphrase. Add `-q` to suppress prompts.
- **CRLF line endings.** Scripts saved by Windows editors get `\r\n` line endings; bash will fail with `$'\r': command not found` or `syntax error: unexpected end of file`. Either configure your editor to save with LF (`\n`), or normalize on the fly when piping: `(Get-Content -Raw foo.sh) -replace "\`r\`n", "\`n" | ssh ...`.
- **Input redirection.** PowerShell does not support `<` for input redirection. Use `Get-Content -Raw file.sh | ssh ...` instead of `ssh ... < file.sh`.

For these reasons, **bash (Linux, macOS, or WSL2) is the recommended shell for this guide.** The remaining steps assume bash; equivalent PowerShell patterns are provided where the syntax differs significantly.

</details>

---

## Step 2: Create the resource group and virtual network

```bash
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

# VNet with two /24 subnets
az network vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VNET_NAME" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name "$SUBNET_CONTROL" \
  --subnet-prefix 10.0.1.0/24

az network vnet subnet create \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_WORKER" \
  --address-prefix 10.0.2.0/24
```

---

## Step 3: Create the network security group

These are the minimum rules `kubeadm` + Calico need. The `--direction Inbound` and `--source-address-prefix` flags are **required** by the current `az` CLI — omitting them produces "expected one argument" errors.

```bash
az network nsg create --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME"

# SSH (tighten the source in production)
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  --name allow-ssh --priority 100 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefix '*' --destination-port-range 22

# kube-apiserver (Internet-facing via LB)
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  --name allow-apiserver --priority 110 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefix '*' --destination-port-range 6443

# etcd peer/client (control-plane subnet only)
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  --name allow-etcd --priority 120 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefix 10.0.1.0/24 --destination-port-range 2379-2380

# kubelet API (within VNet)
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  --name allow-kubelet --priority 130 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefix 10.0.0.0/16 --destination-port-range 10250

# Calico VXLAN
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  --name allow-calico-vxlan --priority 140 --direction Inbound --access Allow \
  --protocol Udp --source-address-prefix 10.0.0.0/16 --destination-port-range 4789

# NodePort range
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  --name allow-nodeports --priority 150 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefix '*' --destination-port-range 30000-32767

# Attach to both subnets
for SUBNET in "$SUBNET_CONTROL" "$SUBNET_WORKER"; do
  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
    --name "$SUBNET" --network-security-group "$NSG_NAME"
done
```

---

## Step 4: Create the control-plane Load Balancer

```bash
# Zone-redundant public IP
az network public-ip create \
  --resource-group "$RESOURCE_GROUP" --name "$LB_IP_NAME" \
  --sku Standard --allocation-method Static --zone 1 2 3

export LB_PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" --name "$LB_IP_NAME" \
  --query ipAddress -o tsv)

echo "Control-plane endpoint: ${LB_PUBLIC_IP}:6443"

# Standard LB with one frontend, one backend pool
az network lb create \
  --resource-group "$RESOURCE_GROUP" --name "$LB_NAME" --sku Standard \
  --public-ip-address "$LB_IP_NAME" \
  --frontend-ip-name fe-apiserver --backend-pool-name be-controlplane

# Health probe on 6443
az network lb probe create \
  --resource-group "$RESOURCE_GROUP" --lb-name "$LB_NAME" --name probe-apiserver \
  --protocol Tcp --port 6443 --interval 5 --threshold 2

# LB rule for kube-apiserver
az network lb rule create \
  --resource-group "$RESOURCE_GROUP" --lb-name "$LB_NAME" --name rule-apiserver \
  --protocol Tcp --frontend-port 6443 --backend-port 6443 \
  --frontend-ip-name fe-apiserver --backend-pool-name be-controlplane \
  --probe-name probe-apiserver --load-distribution SourceIP
```

---

## Step 5: Create the control-plane VMSS (Flex)

The control-plane VMSS is attached to the LB backend pool via `--lb` + `--backend-pool-name`, and each instance gets its own public IP (so you can SSH directly without a bastion). Use `--public-ip-per-vm` cautiously in production — for hardened deployments, drop it and use Bastion or jump host.

```bash
CONTROL_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
  --name "$SUBNET_CONTROL" --query id -o tsv)

az vmss create \
  --resource-group "$RESOURCE_GROUP" --name "$CONTROL_VMSS_NAME" \
  --orchestration-mode Flexible \
  --platform-fault-domain-count 1 \
  --vm-sku "$CONTROL_VM_SIZE" \
  --image Ubuntu2204 \
  --admin-username "$ADMIN_USER" \
  --ssh-key-values "$SSH_KEY_PATH" \
  --subnet "$CONTROL_SUBNET_ID" \
  --instance-count 3 \
  --os-disk-size-gb 128 \
  --storage-sku Premium_LRS \
  --lb "$LB_NAME" --backend-pool-name be-controlplane \
  --public-ip-per-vm \
  --tags "role=controlplane" "cluster=${CLUSTER_NAME}"
```

> ⚠️ **Do not** add Azure tags with `/` characters (e.g. `k8s.io/cluster-autoscaler/enabled=true`). Azure rejects them with `InvalidTagNameCharacters` because `/` is reserved in Azure tag names. The Kubernetes cluster-autoscaler does **not** use those as Azure tags — see [the cluster-autoscaler how-to](../how-to/configure-cluster-autoscaler.md) for how it discovers VMSS nodes.

---

## Step 6: Create the worker VMSS (Flex)

```bash
WORKER_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
  --name "$SUBNET_WORKER" --query id -o tsv)

az vmss create \
  --resource-group "$RESOURCE_GROUP" --name "$WORKER_VMSS_NAME" \
  --orchestration-mode Flexible \
  --platform-fault-domain-count 1 \
  --vm-sku "$WORKER_VM_SIZE" \
  --image Ubuntu2204 \
  --admin-username "$ADMIN_USER" \
  --ssh-key-values "$SSH_KEY_PATH" \
  --subnet "$WORKER_SUBNET_ID" \
  --instance-count 3 \
  --os-disk-size-gb 128 \
  --storage-sku Premium_LRS \
  --public-ip-per-vm \
  --tags "role=worker" "cluster=${CLUSTER_NAME}"
```

Verify all six VMs are running:

```bash
az vm list --resource-group "$RESOURCE_GROUP" -d \
  --query "[].{name:name, privateIp:privateIps, publicIp:publicIps, power:powerState}" -o table
```

You should see three `vmss-k8s-controlplane_<hash>` instances on `10.0.1.x` and three `vmss-k8s-workers_<hash>` instances on `10.0.2.x`.

---

## Step 7: Bootstrap all six nodes (containerd + kubeadm)

Save this as `bootstrap-node.sh`. It installs containerd, configures sysctl, and pins kubeadm 1.29.3. It's idempotent — safe to re-run.

```bash
cat > bootstrap-node.sh <<'SCRIPT'
#!/bin/bash
# Bootstrap a Kubernetes node (control plane or worker). Idempotent.
set -eu

K8S_MINOR="1.29"
K8S_PATCH="1.29.3-1.1"

sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq containerd apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

sudo mkdir -p /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet=${K8S_PATCH} kubeadm=${K8S_PATCH} kubectl=${K8S_PATCH}
sudo apt-mark hold kubelet kubeadm kubectl

echo "BOOTSTRAP_OK"
SCRIPT
chmod +x bootstrap-node.sh
```

Fan it out to all six VMs in parallel using `az vm run-command`. This takes 3–5 minutes per node:

```bash
VMS=$(az vm list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv)
for VM in $VMS; do
  az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" --name "$VM" \
    --command-id RunShellScript --scripts "@bootstrap-node.sh" \
    --query "value[0].message" -o tsv &
done
wait
echo "All nodes bootstrapped"
```

> 🛈 **`az vm run-command` runs scripts under `dash`, not `bash`.** `set -o pipefail` will fail with "Illegal option" — that's why `bootstrap-node.sh` above uses only `set -eu`. If you need `bash` features, wrap the body with `bash -s <<'EOF' ... EOF`.

---

## Step 8: Initialize the first control-plane node

Pick any CP instance (we'll call it `CP1`). Run `kubeadm init` with the LB public IP as the control-plane endpoint, and explicitly add it to `--apiserver-cert-extra-sans` so the cert is valid for external clients.

> ⚠️ **Azure Standard LB hairpin restriction.** A VM in an Azure Standard Load Balancer's backend pool **cannot** reach the LB's frontend IP from itself — traffic loops back and times out. Because `kubeadm` configures kubelet/kubectl/kubeadm-join to talk to apiserver via `--control-plane-endpoint` (the LB IP), the local kubelet on each CP would deadlock waiting for its own apiserver, and `kubeadm join` on the other CPs would fail their preflight cluster-info check.
>
> The fix below adds an **iptables NAT rule** on every CP node that rewrites outgoing traffic for `<LB_IP>:6443` to `127.0.0.1:6443`. This works for both hostnames and IP literals (unlike `/etc/hosts`, which only resolves hostnames). Workers don't need this — they aren't in the LB backend pool and reach the LB IP normally.
>
> The same workaround is applied in Step 10 when joining the other CP nodes. See [Networking concepts](../concepts/networking.md#azure-standard-lb-hairpin-the-single-biggest-gotcha) for the full background.

```bash
# Pick the first CP VMSS instance (bash)
CP1=$(az vm list --resource-group "$RESOURCE_GROUP" \
  --query "[?contains(name,'controlplane')]|[0].name" -o tsv)
echo "CP1 = $CP1"
```

> **PowerShell equivalent** (JMESPath pipes don't survive `cmd.exe` re-parsing — see Step 1 gotchas):
> ```powershell
> $allVms = az vm list -g $env:RESOURCE_GROUP -o json | ConvertFrom-Json
> $cp1 = ($allVms | Where-Object { $_.name -like '*controlplane*' } | Select-Object -ExpandProperty name -First 1)
> ```

```bash
cat > kubeadm-init.sh <<SCRIPT
#!/bin/bash
set -eu
PRIV_IP=\$(hostname -I | awk '{print \$1}')

# CRITICAL: Redirect outgoing traffic for the LB IP to localhost (iptables NAT).
# Azure SLB hairpin restriction: VMs in the LB backend pool can't reach the LB
# frontend IP. kubeadm wires the LB IP into kubelet.conf/admin.conf/kubeadm join
# preflight checks — all of which would time out without this redirect.
# (/etc/hosts is insufficient because kubeconfig uses literal IPs, not hostnames.)
sudo iptables -t nat -C OUTPUT -p tcp -d ${LB_PUBLIC_IP} --dport 6443 \\
  -j DNAT --to-destination 127.0.0.1:6443 2>/dev/null || \\
  sudo iptables -t nat -A OUTPUT -p tcp -d ${LB_PUBLIC_IP} --dport 6443 \\
  -j DNAT --to-destination 127.0.0.1:6443

if [ ! -f /etc/kubernetes/admin.conf ]; then
  sudo kubeadm init \\
    --control-plane-endpoint "${LB_PUBLIC_IP}:6443" \\
    --apiserver-cert-extra-sans "${LB_PUBLIC_IP}" \\
    --apiserver-advertise-address "\${PRIV_IP}" \\
    --upload-certs \\
    --pod-network-cidr 192.168.0.0/16 \\
    --kubernetes-version ${K8S_VERSION}
else
  echo "kubeadm already initialized on this node."
fi

# Set up kubectl for azureuser and root (idempotent)
sudo mkdir -p /home/${ADMIN_USER}/.kube /root/.kube
sudo cp -f /etc/kubernetes/admin.conf /home/${ADMIN_USER}/.kube/config
sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config
sudo chown ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.kube/config

# Always emit fresh join material — tokens expire after 24h, cert-key after 2h.
# Re-running this block is safe and gives you working values if you resume later.
echo "===WORKER_JOIN==="
sudo kubeadm token create --print-join-command
echo "===CP_CERT_KEY==="
sudo kubeadm init phase upload-certs --upload-certs 2>&1 | tail -1
SCRIPT

az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" --name "$CP1" \
  --command-id RunShellScript --scripts "@kubeadm-init.sh" \
  --query "value[0].message" -o tsv | tee kubeadm-init.log
```

Extract the join command and cert-key from `kubeadm-init.log`. The `===` markers are critical — `kubeadm init`'s own output contains an example multi-line `kubeadm join` command (ending in `\`) that would otherwise get captured by a naive parser:

```bash
WORKER_JOIN=$(grep -A1 "===WORKER_JOIN===" kubeadm-init.log | tail -1)
CERT_KEY=$(grep -A1   "===CP_CERT_KEY===" kubeadm-init.log | tail -1)
echo "Worker join: $WORKER_JOIN"
echo "Cert key:    $CERT_KEY"
```

---

## Step 9: Install Calico CNI

```bash
cat > calico-install.sh <<SCRIPT
bash -s <<'EOSCRIPT'
#!/bin/bash
set -eu
export KUBECONFIG=/etc/kubernetes/admin.conf

sudo kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml \\
  || echo "(operator already present)"

cat <<EOF | sudo kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 192.168.0.0/16
      encapsulation: VXLAN
      natOutgoing: Enabled
      nodeSelector: all()
EOF

# Wait for the operator to create calico-system and roll out
for i in {1..30}; do
  if sudo kubectl get ns calico-system >/dev/null 2>&1; then break; fi
  sleep 5
done
sudo kubectl -n calico-system wait --for=condition=Ready pods --all --timeout=300s
sudo kubectl get installation default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
echo
EOSCRIPT
SCRIPT

az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" --name "$CP1" \
  --command-id RunShellScript --scripts "@calico-install.sh" \
  --query "value[0].message" -o tsv
```

The operator creates the `calico-system` namespace asynchronously, which is why we loop-wait for it before calling `kubectl wait`.

---

## Step 10: Join the remaining control-plane nodes

Join CPs **sequentially**, not in parallel — `kubeadm join --control-plane` mutates etcd membership and concurrent joins can leave etcd in an unstable state.

```bash
OTHER_CPS=$(az vm list --resource-group "$RESOURCE_GROUP" \
  --query "[?contains(name,'controlplane') && name!='${CP1}'].name" -o tsv)

cat > join-cp.sh <<SCRIPT
#!/bin/bash
set -eu
if [ -f /etc/kubernetes/admin.conf ]; then echo "Already joined."; exit 0; fi
PRIV_IP=\$(hostname -I | awk '{print \$1}')

# Same Azure SLB hairpin workaround as kubeadm-init.sh (Step 8).
# kubeadm join also makes a TLS connection to the LB IP for the preflight
# cluster-info check — fails without this iptables NAT.
sudo iptables -t nat -C OUTPUT -p tcp -d ${LB_PUBLIC_IP} --dport 6443 \\
  -j DNAT --to-destination 127.0.0.1:6443 2>/dev/null || \\
  sudo iptables -t nat -A OUTPUT -p tcp -d ${LB_PUBLIC_IP} --dport 6443 \\
  -j DNAT --to-destination 127.0.0.1:6443

sudo kubeadm join ${LB_PUBLIC_IP}:6443 \\
  ${WORKER_JOIN#kubeadm join *:6443 } \\
  --control-plane --certificate-key ${CERT_KEY} \\
  --apiserver-advertise-address "\${PRIV_IP}"
echo "CP_JOIN_OK"
SCRIPT

for CP in $OTHER_CPS; do
  echo "Joining $CP..."
  az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" --name "$CP" \
    --command-id RunShellScript --scripts "@join-cp.sh" \
    --query "value[0].message" -o tsv
done
```

---

## Step 11: Join the worker nodes in parallel

```bash
WORKERS=$(az vm list --resource-group "$RESOURCE_GROUP" \
  --query "[?contains(name,'workers')].name" -o tsv)

cat > join-worker.sh <<SCRIPT
#!/bin/bash
set -eu
if sudo test -f /etc/kubernetes/kubelet.conf; then echo "Already joined."; exit 0; fi
sudo ${WORKER_JOIN}
echo "WORKER_JOIN_OK"
SCRIPT

for W in $WORKERS; do
  az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" --name "$W" \
    --command-id RunShellScript --scripts "@join-worker.sh" \
    --query "value[0].message" -o tsv &
done
wait
echo "All workers joined"
```

---

## Step 12: Verify the cluster

```bash
# Copy kubeconfig from CP1 to your workstation
CP1_PUB=$(az vm show -d --resource-group "$RESOURCE_GROUP" --name "$CP1" \
  --query publicIps -o tsv)
ssh -i "${SSH_KEY_PATH%.pub}" "${ADMIN_USER}@${CP1_PUB}" 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/k8s-vmss-flex
export KUBECONFIG=~/.kube/k8s-vmss-flex

kubectl get nodes -o wide
kubectl get pods -A
```

Expected — 3 control-plane + 3 worker nodes, all `Ready`:

```
NAME             STATUS   ROLES           AGE     VERSION
vmss-k8s<hash1>  Ready    control-plane   30m     v1.29.3
vmss-k8s<hash2>  Ready    control-plane   15m     v1.29.3
vmss-k8s<hash3>  Ready    control-plane   12m     v1.29.3
vmss-k8s<hash4>  Ready    <none>          5m      v1.29.3
vmss-k8s<hash5>  Ready    <none>          5m      v1.29.3
vmss-k8s<hash6>  Ready    <none>          5m      v1.29.3
```

### Run the validation suite

Save the [validate-cluster.sh](../../examples/validate-cluster.sh) script and run it via **SSH** to CP1. It performs 11 checks (13 individual assertions):

| # | Test |
|---|---|
| 1 | All 6 nodes Ready |
| 2 | 3 etcd + 3 apiserver pods Running |
| 3 | etcd cluster — all endpoints healthy |
| 4 | CoreDNS pods Running |
| 5 | Pod scheduling spreads across distinct nodes |
| 6 | Pod-to-pod networking across nodes (Calico VXLAN) |
| 7 | ClusterIP service routing (kube-proxy) |
| 8 | DNS resolution via CoreDNS |
| 9 | NodePort externally reachable on worker IP |
| 10 | controller-manager + scheduler leader election |
| 11 | API server `/livez` returns 200 via LB (run from a worker pod) |

```bash
ssh -i "${SSH_KEY_PATH%.pub}" "${ADMIN_USER}@${CP1_PUB}" 'bash -s' < validate-cluster.sh \
  | tee validate.log

grep -E "PASS:|FAIL:|RESULT:" validate.log
```

> ⚠️ **Run validation via SSH, not `az vm run-command`.** The Azure run-command API truncates output at ~4 KB and will cut off the validation report around Test 8. SSH returns the full log.
>
> **PowerShell equivalent** (no input redirection `<`):
> ```powershell
> Get-Content -Raw validate-cluster.sh |
>   ssh -i "K8s-on-vmss\.deploy\k8s_vmss" "azureuser@$cp1Pub" 'bash -s' |
>   Tee-Object -FilePath validate.log
> ```

A healthy cluster reports `RESULT: 13 passed, 0 failed`.

> ℹ️ **Test 11 specifics.** It runs `curl` against the LB frontend IP **from inside a worker pod**, not from a control-plane VM. Azure Standard Load Balancer doesn't allow a VM in the backend pool to reach its own frontend IP (a hairpin restriction), so testing from a CP would yield HTTP `000`. Pods route via Calico pod-IP source, which Azure treats as external and routes correctly.

---

## Tear down

When you're done experimenting:

```bash
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
```

This deletes the resource group and every resource inside it (both VMSS, LB, public IP, NSG, VNet, disks). Verify with `az group exists -n "$RESOURCE_GROUP"`.

---

## What's next

- [Configure the Kubernetes Cluster Autoscaler with Azure VMSS](../how-to/configure-cluster-autoscaler.md) — scale worker pools based on pending pods
- [Handle Spot VM Evictions Gracefully](../how-to/handle-spot-evictions.md) — cut worker costs ~70% with eviction handling
- [Add GPU Worker Nodes](../how-to/gpu-nodes-vmss.md) — attach NDv4/NDv5/H100 pools for AI workloads
- [Upgrade Kubernetes on VMSS Without Downtime](../how-to/upgrade-kubernetes.md)

---

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `argument --resource-group/-g: expected one argument` | Shell variable unset (often after a long-running `az` command) | Re-export the variables from Step 1; in PowerShell, dot-source `env.ps1` |
| `InvalidTagNameCharacters` on `az vmss create` | Tag contains `/`, `<`, `>`, `%`, `&`, `\`, `?`, or control char | Use only alphanumeric tags + `-` `_` `.` `=` |
| `Extra data: line 1 column 4` on `az vmss create --orchestration-mode Flexible` | Azure CLI < 2.86.0 known bug | `az upgrade` |
| `[0].name was unexpected at this time` or `unrecognized arguments` with `--query` in PowerShell | `cmd.exe` re-parses JMESPath `\|`, `?`, `[` inside double quotes | Filter in PowerShell: `az vm list ... -o json \| ConvertFrom-Json \| Where-Object {...}` |
| `set: Illegal option -o pipefail` in `az vm run-command` | Run-command invokes `dash`, not `bash` | Use `bash -s <<'EOF'...EOF` wrapper or remove `pipefail` |
| `az vm run-command` output ends abruptly mid-test | Run-command API truncates at ~4 KB | Use SSH for long-running commands (validation, etcd inspection, etc.) |
| `etcdserver: can only promote a learner member which is in sync with leader` (warning during CP join) | Normal — etcd learner promotion retries until quorum sync completes | Ignore; CP join still reports `CP_JOIN_OK` |
| `error: no matching resources found` for `calico-system` immediately after Calico install | Tigera operator hasn't created the namespace yet | Loop-wait until `kubectl get ns calico-system` succeeds (Step 9 does this) |
| `Enter passphrase for key` despite `ssh-keygen -N '""'` | PowerShell literal quotes — created a key with `""` as the passphrase | Use `ssh-keygen -N "" -q` (empty PowerShell string, not literal quotes) |
| `bash: line N: $'\r': command not found` or `syntax error: unexpected end of file` when piping a script to ssh | Script saved with CRLF line endings | Save with LF, or normalize: `(Get-Content -Raw foo.sh) -replace "\`r\`n","\`n" \| ssh ...` |
| `kubeadm init` fails at `wait-control-plane`, or `kubeadm join` fails preflight with `cluster-info` timeout, kubelet log shows `dial tcp <LB_IP>:6443: i/o timeout` | Azure Standard LB hairpin: CP node can't reach its own LB frontend IP | Add an iptables NAT redirect on every CP **before** `kubeadm init`/`kubeadm join`: `sudo iptables -t nat -A OUTPUT -p tcp -d <LB_IP> --dport 6443 -j DNAT --to-destination 127.0.0.1:6443` (Steps 8 + 10 do this). **Note:** `/etc/hosts` alone is NOT enough — kubeconfig uses literal IPs and skips DNS/hosts lookup. |
| Test 11 (`apiserver healthy via LB`) returns HTTP `000` when run from a CP | Azure Standard LB hairpin — VMs in the backend pool can't reach their own frontend IP | Run the test from a worker pod (the published `validate-cluster.sh` does this) |
| `SkuNotAvailable: ... 'Standard_D*s_v5' is currently not available in location` | Azure capacity allocation for that SKU is unavailable in the chosen region/zone | Try a v6 SKU (e.g. `Standard_D2s_v6` / `D4s_v6`) — also smaller, fits 20 vCPU quota — OR switch region |
| `BadRequest: VM size 'Standard_D*s_v6' cannot boot Hypervisor Generation '1'` | v6 SKUs require a Generation 2 image; default `--image Ubuntu2204` alias is Gen1 | Switch to `--image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest` |
| `OperationNotAllowed: exceeding quota limits` on first `terraform apply` / `az vmss create` | Defaults need 36 vCPU; new MSDN/VS subs default to 20 vCPU per family | Use the smaller v6 SKUs from the "Sizing for limited subscriptions" callout in Step 1 |

For deeper troubleshooting see [Common Issues](../troubleshooting/common-issues.md).
