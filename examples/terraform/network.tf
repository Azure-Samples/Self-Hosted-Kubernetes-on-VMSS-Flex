resource "azurerm_resource_group" "k8s" {
  name     = var.resource_group_name
  location = var.location
  tags     = merge(var.tags, { cluster = var.cluster_name })
}

resource "azurerm_virtual_network" "k8s" {
  name                = "vnet-k8s"
  location            = azurerm_resource_group.k8s.location
  resource_group_name = azurerm_resource_group.k8s.name
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "controlplane" {
  name                 = "snet-controlplane"
  resource_group_name  = azurerm_resource_group.k8s.name
  virtual_network_name = azurerm_virtual_network.k8s.name
  address_prefixes     = [var.controlplane_subnet_cidr]
}

resource "azurerm_subnet" "workers" {
  name                 = "snet-workers"
  resource_group_name  = azurerm_resource_group.k8s.name
  virtual_network_name = azurerm_virtual_network.k8s.name
  address_prefixes     = [var.worker_subnet_cidr]
}

resource "azurerm_network_security_group" "k8s" {
  name                = "nsg-k8s"
  location            = azurerm_resource_group.k8s.location
  resource_group_name = azurerm_resource_group.k8s.name
  tags                = var.tags

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    source_address_prefix      = var.ssh_source_address_prefix
    destination_port_range     = "22"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-apiserver"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    source_address_prefix      = var.apiserver_source_address_prefix
    destination_port_range     = "6443"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-etcd"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    source_address_prefix      = var.controlplane_subnet_cidr
    destination_port_range     = "2379-2380"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-kubelet"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    source_address_prefix      = var.vnet_address_space
    destination_port_range     = "10250"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-calico-vxlan"
    priority                   = 140
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    source_address_prefix      = var.vnet_address_space
    destination_port_range     = "4789"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-nodeports"
    priority                   = 150
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    source_address_prefix      = "*"
    destination_port_range     = "30000-32767"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "controlplane" {
  subnet_id                 = azurerm_subnet.controlplane.id
  network_security_group_id = azurerm_network_security_group.k8s.id
}

resource "azurerm_subnet_network_security_group_association" "workers" {
  subnet_id                 = azurerm_subnet.workers.id
  network_security_group_id = azurerm_network_security_group.k8s.id
}
