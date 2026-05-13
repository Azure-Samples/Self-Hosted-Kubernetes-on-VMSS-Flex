#!/bin/bash
# Bootstrap script for Kubernetes nodes (control plane + workers)
# Idempotent: safe to re-run.
set -euo pipefail

K8S_MINOR="1.29"
K8S_PATCH="1.29.3-1.1"

echo "[1/6] Disable swap"
sudo swapoff -a || true
sudo sed -i '/ swap / s/^/#/' /etc/fstab || true

echo "[2/6] Load kernel modules"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

echo "[3/6] Sysctl for k8s networking"
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null

echo "[4/6] Install containerd"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq containerd apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "[5/6] Install kubeadm/kubelet/kubectl ${K8S_PATCH}"
sudo mkdir -p /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet=${K8S_PATCH} kubeadm=${K8S_PATCH} kubectl=${K8S_PATCH}
sudo apt-mark hold kubelet kubeadm kubectl

echo "[6/6] Verify"
kubeadm version
containerd --version
echo "BOOTSTRAP_OK"
