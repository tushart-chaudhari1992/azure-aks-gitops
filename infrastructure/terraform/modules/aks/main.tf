resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.prefix}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.prefix
  kubernetes_version  = var.kubernetes_version

  # Private cluster — API server has no public endpoint at all.
  # kubectl access requires being inside the VNet (jump box, VPN, or CI runner in VNet).
  # Trade-off: harder to access for developers, much smaller attack surface.
  private_cluster_enabled = true
  private_dns_zone_id     = "System" # Azure manages the private DNS zone

  # Disables the local admin kubeconfig entirely — forces all access through Azure AD RBAC.
  # Without this, anyone with the kubeconfig file has cluster-admin regardless of AAD policies.
  local_account_disabled = true

  # Patch and minor version updates are applied automatically on the "stable" cadence.
  # Prevents clusters falling behind on CVE patches without requiring manual intervention.
  automatic_channel_upgrade = "stable"

  # System node pool — runs cluster-critical components only, not application workloads
  default_node_pool {
    name                         = "system"
    node_count                   = 1
    vm_size                      = "Standard_D2s_v3"
    vnet_subnet_id               = var.aks_subnet_id
    os_disk_size_gb              = 50
    type                         = "VirtualMachineScaleSets"
    only_critical_addons_enabled = true
    max_pods                     = 110
  }

  # Control plane identity — used by AKS to manage Azure resources (load balancers, etc.)
  identity {
    type = "SystemAssigned"
  }

  # Kubelet identity — used by nodes to pull images from ACR, separate from control plane
  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet.id
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "calico" # Enforces pod-to-pod traffic rules (NetworkPolicy objects)
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
  }

  # Azure AD RBAC — authenticate to the cluster with Azure identities, not static kubeconfig
  azure_active_directory_role_based_access_control {
    managed            = true
    azure_rbac_enabled = true
  }

  # Enforces Azure Policy definitions against cluster workloads (pod security, resource limits, etc.)
  azure_policy_enabled = true

  # Mounts Key Vault secrets as files/env vars in pods; rotation means pods always see current values
  # without redeployment. Required for zero-downtime secret rotation.
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  }

  tags = var.tags
}

resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "${var.prefix}-kubelet-identity"
  location            = var.location
  resource_group_name = var.resource_group_name
}

# User node pool — runs application workloads, separate from system pool
# Keeps application resource pressure from affecting cluster-critical components
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.user_node_vm_size
  node_count            = var.user_node_count
  vnet_subnet_id        = var.aks_subnet_id
  os_disk_size_gb       = 100
  max_pods              = 110
  tags                  = var.tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.prefix}-law"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}
