output "resource_group_name" {
  description = "Resource group containing the cluster"
  value       = azurerm_resource_group.k8s.name
}

output "location" {
  value = azurerm_resource_group.k8s.location
}

output "lb_public_ip" {
  description = "Public IP of the control-plane Load Balancer (kube-apiserver endpoint)"
  value       = azurerm_public_ip.apiserver.ip_address
}

output "control_plane_endpoint" {
  description = "Use this as --control-plane-endpoint for kubeadm init"
  value       = "${azurerm_public_ip.apiserver.ip_address}:6443"
}

output "controlplane_vmss_name" {
  value = azurerm_orchestrated_virtual_machine_scale_set.controlplane.name
}

output "worker_vmss_name" {
  value = azurerm_orchestrated_virtual_machine_scale_set.workers.name
}

output "ssh_public_key_path" {
  value = var.ssh_public_key_path
}

output "next_steps" {
  description = "Run these commands after `terraform apply` finishes to complete the cluster bootstrap"
  value       = <<-EOT

    # 1. Find the public IP of any CP instance:
    az vm list -g ${azurerm_resource_group.k8s.name} -d \
      --query "[?contains(name,'controlplane')].{name:name,ip:publicIps}" -o table

    # 2. SSH to that VM (pick the first IP from above):
    ssh -i ${replace(var.ssh_public_key_path, ".pub", "")} azureuser@<cp1-public-ip>

    # 3. On CP1, initialize the control plane:
    sudo kubeadm init \
      --control-plane-endpoint "${azurerm_public_ip.apiserver.ip_address}:6443" \
      --apiserver-cert-extra-sans "${azurerm_public_ip.apiserver.ip_address}" \
      --apiserver-advertise-address "$(hostname -I | awk '{print $1}')" \
      --upload-certs \
      --pod-network-cidr 192.168.0.0/16 \
      --kubernetes-version ${var.k8s_version}

    # 4. Set up kubectl on CP1:
    mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config

    # 5. Install Calico:
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml
    cat <<EOF | kubectl apply -f -
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

    # 6. Get the join commands (run these on CP1):
    sudo kubeadm token create --print-join-command          # for workers
    sudo kubeadm init phase upload-certs --upload-certs     # cert-key for CP joins (last line)

    # 7. Join CP2 + CP3 sequentially, then workers in parallel
    #    (see ../docs/quickstart/deploy-kubeadm-vmss.md Steps 10-11)

    # 8. Validate:
    scp -i ${replace(var.ssh_public_key_path, ".pub", "")} ../validate-cluster.sh azureuser@<cp1-public-ip>:~
    ssh -i ${replace(var.ssh_public_key_path, ".pub", "")} azureuser@<cp1-public-ip> 'bash ~/validate-cluster.sh'
  EOT
}
