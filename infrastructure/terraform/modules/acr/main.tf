resource "azurerm_container_registry" "main" {
  name                = "${replace(var.prefix, "-", "")}acr"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku
  admin_enabled       = false

  # Dev: true so GitHub-hosted runners (public internet) can push images.
  # Prod: false — all traffic must flow through the private endpoint.
  public_network_access_enabled = var.public_network_access_enabled

  # Automatically delete untagged image manifests after 7 days.
  # Untagged manifests are orphaned layers that consume storage and inflate attack surface
  # (old vulnerable image layers remain pullable by digest even when not referenced by any tag).
  # Requires Standard or Premium SKU — dynamic block skips this on Basic (dev).
  dynamic "retention_policy" {
    for_each = var.sku != "Basic" ? [1] : []
    content {
      days    = 7
      enabled = true
    }
  }

  tags = var.tags
}

# Grant AKS kubelet managed identity to pull images — no credentials to store or rotate
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = var.aks_kubelet_identity_object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.main.id
  skip_service_principal_aad_check = true
}

# Private endpoint — requires Premium SKU. Basic and Standard SKUs must use public access.
# count=1 when Premium, count=0 otherwise — resources are simply not created for lower SKUs.
resource "azurerm_private_endpoint" "acr" {
  count               = var.sku == "Premium" ? 1 : 0
  name                = "${var.prefix}-acr-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "${var.prefix}-acr-psc"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr[0].id]
  }
}

resource "azurerm_private_dns_zone" "acr" {
  count               = var.sku == "Premium" ? 1 : 0
  name                = "privatelink.azurecr.io"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  count                 = var.sku == "Premium" ? 1 : 0
  name                  = "${var.prefix}-acr-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.acr[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}
