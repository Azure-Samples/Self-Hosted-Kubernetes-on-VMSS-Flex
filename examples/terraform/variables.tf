variable "resource_group_name" {
  description = "Resource group to create for the cluster"
  type        = string
  default     = "rg-k8s-vmss-flex"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "northeurope"
}

variable "cluster_name" {
  description = "Logical cluster name (used as a tag)"
  type        = string
  default     = "k8s-vmss-flex"
}

variable "vnet_address_space" {
  description = "Address space for the cluster VNet"
  type        = string
  default     = "10.0.0.0/16"
}

variable "controlplane_subnet_cidr" {
  description = "CIDR for the control-plane subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "worker_subnet_cidr" {
  description = "CIDR for the worker subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "controlplane_vm_size" {
  description = "VM SKU for control-plane nodes"
  type        = string
  default     = "Standard_D4s_v5"
}

variable "worker_vm_size" {
  description = "VM SKU for worker nodes"
  type        = string
  default     = "Standard_D8s_v5"
}

variable "controlplane_instance_count" {
  description = "Number of control-plane nodes (3 = HA quorum)"
  type        = number
  default     = 3
}

variable "worker_instance_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "admin_username" {
  description = "Linux admin username on all nodes"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key (.pub) for VM access"
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes version to install via apt (must be a 1.29.x release for this module)"
  type        = string
  default     = "1.29.3"

  validation {
    condition     = can(regex("^1\\.29\\.[0-9]+$", var.k8s_version))
    error_message = "This module targets Kubernetes 1.29.x. Update cloud-init.yaml to support other minor versions."
  }
}

variable "ssh_source_address_prefix" {
  description = "Source address (or CIDR) allowed to SSH. Use '*' for any (NOT recommended for production)."
  type        = string
  default     = "*"
}

variable "apiserver_source_address_prefix" {
  description = "Source address allowed to reach kube-apiserver on port 6443 via the LB."
  type        = string
  default     = "*"
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default = {
    deployedBy = "terraform"
    workload   = "self-hosted-kubernetes"
  }
}
