resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.prefix}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.prefix
  kubernetes_version  = var.kubernetes_version

  # Public API server endpoint restricted to an explicit IP allowlist.
  # kubectl works directly from any machine whose IP is in api_server_authorized_ip_ranges.
  # Trade-off: slightly larger attack surface than a fully private cluster, but the allowlist
  # keeps it locked to known IPs — acceptable for dev, not recommended for prod.
  private_cluster_enabled       = false
  api_server_authorized_ip_ranges = var.api_server_authorized_ip_ranges

  # Disables the local admin kubeconfig entirely — forces all access through Azure AD RBAC.
  # Without this, anyone with the kubeconfig file has cluster-admin regardless of AAD policies.
  local_account_disabled = true

  # One-way switch — once enabled Azure will never allow disabling it.
  # Required for workload identity federation (pods authenticating to Azure AD without secrets).
  oidc_issuer_enabled = true

  # Patch and minor version updates are applied automatically on the "stable" cadence.
  # Prevents clusters falling behind on CVE patches without requiring manual intervention.
  automatic_channel_upgrade = "stable"

  # System node pool — runs cluster-critical components only, not application workloads
  default_node_pool {
    name                         = "system"
    temporary_name_for_rotation  = "tmpsys"
    node_count                   = 1
    vm_size                      = "Standard_D2s_v3"
    vnet_subnet_id               = var.aks_subnet_id
    os_disk_size_gb              = 50
    type                         = "VirtualMachineScaleSets"
    only_critical_addons_enabled = true
    max_pods                     = 50
  }

  # Control plane identity — UserAssigned so kubelet_identity can also be specified.
  # azurerm requires identity.type = "UserAssigned" whenever kubelet_identity is set.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
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
  # managed = true activates AKS-managed Entra integration (required in azurerm ~3.x).
  # In azurerm v4.0 this field is removed and always defaults to true.
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

  # Role assignment propagation in Azure AD takes up to 2 minutes. Without this
  # dependency the cluster API call races the propagation and fails with 400.
  depends_on = [azurerm_role_assignment.control_plane_kubelet_operator]
}

resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "${var.prefix}-aks-identity"
  location            = var.location
  resource_group_name = var.resource_group_name
}

resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "${var.prefix}-kubelet-identity"
  location            = var.location
  resource_group_name = var.resource_group_name
}

# AKS requires the control plane identity to have Managed Identity Operator on the kubelet
# identity so it can assign that identity to each node at provisioning time.
# Without this, cluster creation fails with CustomKubeletIdentityMissingPermissionError.
resource "azurerm_role_assignment" "control_plane_kubelet_operator" {
  principal_id                     = azurerm_user_assigned_identity.control_plane.principal_id
  role_definition_name             = "Managed Identity Operator"
  scope                            = azurerm_user_assigned_identity.kubelet.id
  skip_service_principal_aad_check = true
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
  max_pods              = 50
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
