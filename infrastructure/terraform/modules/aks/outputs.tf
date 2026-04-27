output "cluster_id" { value = azurerm_kubernetes_cluster.main.id }
output "cluster_name" { value = azurerm_kubernetes_cluster.main.name }
output "kube_config" {
  value     = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive = true
}
output "kubelet_identity_object_id" { value = azurerm_user_assigned_identity.kubelet.principal_id }
output "log_analytics_workspace_id" { value = azurerm_log_analytics_workspace.main.id }
