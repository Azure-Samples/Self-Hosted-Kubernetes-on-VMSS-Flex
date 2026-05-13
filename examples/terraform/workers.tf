resource "azurerm_orchestrated_virtual_machine_scale_set" "workers" {
  name                = "vmss-k8s-workers"
  location            = azurerm_resource_group.k8s.location
  resource_group_name = azurerm_resource_group.k8s.name

  platform_fault_domain_count = 1
  sku_name                    = var.worker_vm_size
  instances                   = var.worker_instance_count

  os_profile {
    custom_data = local.cloud_init

    linux_configuration {
      admin_username                  = var.admin_username
      disable_password_authentication = true
      computer_name_prefix            = "vmss-k8s-wk"

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
    name    = "nic-wk"
    primary = true

    ip_configuration {
      name      = "ipc-wk"
      primary   = true
      subnet_id = azurerm_subnet.workers.id

      public_ip_address {
        name = "pip-wk"
      }
    }
  }

  tags = merge(var.tags, { role = "worker", cluster = var.cluster_name })

  depends_on = [
    azurerm_subnet_network_security_group_association.workers,
  ]
}
