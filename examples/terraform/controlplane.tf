locals {
  k8s_minor = join(".", slice(split(".", var.k8s_version), 0, 2))
  k8s_patch = var.k8s_version

  cloud_init = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    K8S_MINOR = local.k8s_minor
    K8S_PATCH = local.k8s_patch
  }))
}

resource "azurerm_orchestrated_virtual_machine_scale_set" "controlplane" {
  name                = "vmss-k8s-controlplane"
  location            = azurerm_resource_group.k8s.location
  resource_group_name = azurerm_resource_group.k8s.name

  platform_fault_domain_count = 1
  sku_name                    = var.controlplane_vm_size
  instances                   = var.controlplane_instance_count

  os_profile {
    custom_data = local.cloud_init

    linux_configuration {
      admin_username                  = var.admin_username
      disable_password_authentication = true
      computer_name_prefix            = "vmss-k8s-cp"

      admin_ssh_key {
        username   = var.admin_username
        public_key = file(var.ssh_public_key_path)
      }
    }
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  network_interface {
    name    = "nic-cp"
    primary = true

    ip_configuration {
      name                                   = "ipc-cp"
      primary                                = true
      subnet_id                              = azurerm_subnet.controlplane.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.controlplane.id]

      public_ip_address {
        name = "pip-cp"
      }
    }
  }

  tags = merge(var.tags, { role = "controlplane", cluster = var.cluster_name })

  # Force VMSS recreate (and re-running cloud-init) if the bootstrap script changes
  depends_on = [
    azurerm_subnet_network_security_group_association.controlplane,
    azurerm_lb_rule.apiserver,
  ]
}
