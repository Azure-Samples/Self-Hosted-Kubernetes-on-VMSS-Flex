# What This Sample Deploys

This sample stands up a self-hosted Kubernetes cluster on Azure VMSS Flex using `kubeadm`. It's a working starting point for teams who want full ownership of the cluster — control plane, kernel, runtime, CNI, and lifecycle.

## What you get

- **3-node HA control plane** on a Flex VMSS, fronted by a Standard Load Balancer (TCP/6443) with iptables NAT to handle the Azure SLB hairpin
- **Worker Flex VMSS** scaled independently of the control plane
- **kubeadm-based bootstrap** — K8s 1.29.x, containerd 2.x (versions are pinned in cloud-init and easy to change)
- **Calico CNI** — VXLAN encapsulation, `192.168.0.0/16` pod CIDR. Swap in another CNI if you prefer.
- **Three deploy paths** — bash + Azure CLI quickstart, PowerShell quickstart, and a Terraform module under [`examples/terraform/`](../../examples/terraform/)
- **Validation harness** — [`examples/validate-cluster.sh`](../../examples/validate-cluster.sh) runs 13 assertions (control-plane health, pod CIDR, CNI, DNS, scheduling, etc.) against a freshly deployed cluster

## What you own after deploy

Self-hosting means you take responsibility for the operational layer. Plan for:

| Area | Your responsibility |
|---|---|
| **etcd backups** | Schedule and verify your own backups (cron + offsite). |
| **Control plane upgrades** | Sequential `kubeadm upgrade` on each CP; you choreograph it. See [Upgrade Kubernetes](../how-to/upgrade-kubernetes.md). |
| **Cert rotation** | kubeadm rotates CP certs at upgrade time. Kubelet certs need `--rotate-certificates`. You verify. |
| **kube-apiserver HA** | You size the LB and the CP pool; you watch quorum. |
| **Cluster autoscaler** | You install it, configure RBAC + managed identity, monitor it. See [Configure Cluster Autoscaler](../how-to/configure-cluster-autoscaler.md). |
| **Cloud-controller-manager features** (LoadBalancer Services, Azure Disk dynamic provisioning, cloud-aware node deletion) | Install [cloud-provider-azure](https://github.com/kubernetes-sigs/cloud-provider-azure) yourself. |
| **Audit logging** | You configure `audit-policy.yaml` and ship logs. |
| **Security patching** | Your image; your responsibility. |
| **Compliance attestations** | You attest your stack. |

## What this sample is NOT

To set expectations up front:

- **Not production-grade by default.** The defaults expose a public-IP apiserver and SSH on the worker subnet. Tighten NSG source ranges, use an internal LB, and put SSH behind Azure Bastion before any production use.
- **Not a managed service.** You patch nodes, rotate certs, upgrade kubeadm, monitor etcd, and respond to Spot evictions.
- **Not a reference architecture.** It demonstrates one working pattern. Real production setups will diverge (image baking, identity federation, service mesh, observability stack).
- **Not opinionated about CNI.** We use Calico VXLAN because it works everywhere; you might pick Cilium, Azure CNI Overlay, or Antrea for your reasons.

## Next steps

- [Architecture overview](architecture.md) — what this sample deploys, in detail
- [Quickstart (bash + Azure CLI)](../quickstart/deploy-kubeadm-vmss.md) — fastest path to a running cluster
- [Networking concepts](networking.md) — the Azure SLB hairpin and other gotchas
- [Scaling and lifecycle](scaling-and-lifecycle.md) — what ongoing operations look like
