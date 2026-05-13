resource "azurerm_public_ip" "apiserver" {
  name                = "pip-k8s-apiserver"
  location            = azurerm_resource_group.k8s.location
  resource_group_name = azurerm_resource_group.k8s.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_lb" "apiserver" {
  name                = "lb-k8s-apiserver"
  location            = azurerm_resource_group.k8s.location
  resource_group_name = azurerm_resource_group.k8s.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "fe-apiserver"
    public_ip_address_id = azurerm_public_ip.apiserver.id
  }
}

resource "azurerm_lb_backend_address_pool" "controlplane" {
  name            = "be-controlplane"
  loadbalancer_id = azurerm_lb.apiserver.id
}

resource "azurerm_lb_probe" "apiserver" {
  name                = "probe-apiserver"
  loadbalancer_id     = azurerm_lb.apiserver.id
  protocol            = "Tcp"
  port                = 6443
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "apiserver" {
  name                           = "rule-apiserver"
  loadbalancer_id                = azurerm_lb.apiserver.id
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = "fe-apiserver"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.controlplane.id]
  probe_id                       = azurerm_lb_probe.apiserver.id
  load_distribution              = "SourceIP"
}
