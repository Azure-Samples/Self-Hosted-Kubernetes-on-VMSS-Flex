# Security and Identity: Self-Hosted Kubernetes on VMSS Flex

What's secure by default, what's NOT, and what to harden before production.

## TL;DR — read this if you skim nothing else

The base quickstart is **NOT production-ready** from a security standpoint:

- ❌ **kube-apiserver is on a public IP** with `allow-apiserver` NSG source `*`. Anyone on the internet can reach `:6443`.
- ❌ **SSH is on a public IP** for every VM, with `allow-ssh` source `*`. The only thing protecting you is RSA key auth.
- ❌ **No managed identity** on the VMSS. The cluster cannot call Azure APIs (no CCM, no Disk CSI, no Cluster Autoscaler).
- ❌ **Default RBAC only**. No PSA, no NetworkPolicies, no AuditPolicy.
- ✅ Calico is installed and supports NetworkPolicy (but no policies are applied).
- ✅ etcd traffic is encrypted at rest by default in kubeadm 1.29+.
- ✅ All API calls within the cluster use mTLS (kubeadm sets this up).

Production-hardening checklist follows. Do at least items 1-4 before any non-test workload.

---

## Hardening checklist

### 1. Tighten NSG source ranges (do this FIRST)

```bash
# Restrict apiserver to operator/CI IPs only
az network nsg rule update --resource-group rg-k8s-vmss-flex --nsg-name nsg-k8s \
  --name allow-apiserver --source-address-prefixes 203.0.113.0/24 198.51.100.5/32

# Restrict SSH to operator IPs only (or eliminate via Bastion below)
az network nsg rule update --resource-group rg-k8s-vmss-flex --nsg-name nsg-k8s \
  --name allow-ssh --source-address-prefixes 203.0.113.0/24
```

In Terraform, set `ssh_source_address_prefix` and `apiserver_source_address_prefix` variables.

### 2. Use Azure Bastion for SSH

```bash
# Remove allow-ssh from NSG entirely, deploy Bastion in a separate subnet
az network bastion create -g rg-k8s-vmss-flex -n bastion-k8s \
  --public-ip-address pip-bastion --vnet-name vnet-k8s --location northeurope
```

Now SSH only via Bastion. NSG `allow-ssh` rule can be removed.

### 3. Switch to an internal Load Balancer

The default uses a public Standard LB. For private clusters:

- Change LB SKU to internal: `--frontend-type private` on `az network lb create`, or `frontend_ip_configuration { private_ip_address = "..." }` in Terraform
- Drop the `pip-k8s-apiserver` public IP
- Tighten `allow-apiserver` to your VNet CIDR only
- Reach the cluster from your workstation via VPN, ExpressRoute, or a jumpbox

This eliminates the entire internet attack surface against the apiserver.

### 4. Pod Security Standards

kubeadm 1.29 ships with Pod Security Admission enabled. Set baseline restrictions:

```bash
kubectl label namespace default \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

Repeat for every workload namespace. `baseline` blocks privileged pods + hostPath; `restricted` blocks running as root, hostPID/IPC, etc.

### 5. NetworkPolicies (default-deny)

Calico is installed but no policies are applied. Workloads can talk to anything by default.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

Apply to each namespace, then add explicit allow-rules for the traffic you want.

### 6. Audit logging

By default the apiserver does not log audit events. Add an audit policy:

```yaml
# /etc/kubernetes/audit-policy.yaml on every CP
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata
    omitStages: ["RequestReceived"]
```

Edit `/etc/kubernetes/manifests/kube-apiserver.yaml` on each CP to add:

```yaml
- --audit-log-path=/var/log/kube-audit.log
- --audit-log-maxage=30
- --audit-policy-file=/etc/kubernetes/audit-policy.yaml
```

Ship `/var/log/kube-audit.log` to Azure Monitor or a SIEM.

### 7. etcd encryption at rest

kubeadm 1.29+ enables etcd encryption for Secrets by default with AESCBC. To verify:

```bash
sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep encryption-provider-config
```

If absent, follow the [official guide](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) to add an `EncryptionConfiguration` resource.

### 8. Image scanning + admission

The base cluster will pull any image from any registry. Lock down via:

- **ImagePolicyWebhook** or [Kyverno](https://kyverno.io/) / [OPA Gatekeeper](https://open-policy-agent.github.io/gatekeeper/) policies that require:
  - Images from your allowed registries (e.g. `<your-acr>.azurecr.io/*`)
  - SHA digests, not floating tags
  - Signed images (Notary v2 / cosign)

---

## Managed identity on the VMSS

For any feature that calls Azure APIs from inside the cluster, attach a Managed Identity to the VMSS.

```bash
# Create user-assigned managed identity
az identity create -g rg-k8s-vmss-flex -n k8s-cluster-identity
MI_ID=$(az identity show -g rg-k8s-vmss-flex -n k8s-cluster-identity --query id -o tsv)
MI_PRINCIPAL=$(az identity show -g rg-k8s-vmss-flex -n k8s-cluster-identity --query principalId -o tsv)

# Attach to both VMSS
az vmss identity assign -g rg-k8s-vmss-flex -n vmss-k8s-controlplane --identities $MI_ID
az vmss identity assign -g rg-k8s-vmss-flex -n vmss-k8s-workers --identities $MI_ID

# Grant Contributor on the resource group (or scope tighter for production)
az role assignment create --assignee-object-id $MI_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --role Contributor --scope $(az group show -n rg-k8s-vmss-flex --query id -o tsv)
```

Tighten the role to a custom role like `Virtual Machine Contributor` + `Network Contributor` (for Cluster Autoscaler and LoadBalancer services). Read [the cloud-provider-azure RBAC docs](https://kubernetes-sigs.github.io/cloud-provider-azure/install/configs/) for the minimum required permissions.

The cloud-provider-azure DaemonSet picks up the MI via IMDS automatically when configured.

---

## SSH key rotation

SSH keys baked into the VMSS profile via `--ssh-key-values` apply only at **VM creation time**. To rotate keys later:

```bash
# Update the VMSS model (affects future instances)
az vmss update -g rg-k8s-vmss-flex -n vmss-k8s-workers \
  --set "virtualMachineProfile.osProfile.linuxConfiguration.ssh.publicKeys[0].keyData=$(cat ~/.ssh/new-key.pub)"

# Update existing instances: push new keys via az vm user update
for vm in $(az vm list -g rg-k8s-vmss-flex --query "[].name" -o tsv); do
  az vm user update -g rg-k8s-vmss-flex -n $vm -u azureuser --ssh-key-value "@~/.ssh/new-key.pub"
done
```

`az vm user update` modifies `~azureuser/.ssh/authorized_keys` directly on each VM via the VM Agent. This **replaces** the existing key for that user — make sure your new key works before destroying the old one.

---

## What's missing for compliance

This sample's defaults will not pass:

- **FedRAMP / DoD STIG**: needs CIS-benchmarked OS image (we use stock Ubuntu 22.04), audit logging, FIPS crypto, no plaintext public endpoints
- **PCI-DSS**: needs network segmentation, encrypted data-at-rest with customer-managed keys, separate logging plane
- **HIPAA**: needs BAA-eligible Azure services only (this sample uses BAA-eligible primitives but you must configure them)
- **Microsoft SDL**: needs threat model, dependency scanning, signed binaries

For compliance-grade clusters, start from a baked image built with Image Builder + Packer that has CIS hardening, drop the public-IP defaults, and use Azure Policy to enforce drift detection.

---

## See also

- [Networking](networking.md) — NSG rules and what they do
- [Quickstart Step 2-3](../quickstart/deploy-kubeadm-vmss.md#step-2-create-the-resource-group-and-virtual-network) — where the public IPs are defined
- [Cloud Provider Azure](https://kubernetes-sigs.github.io/cloud-provider-azure/) — managed identity integration
- [Azure Bastion](https://learn.microsoft.com/azure/bastion/bastion-overview)
- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
