output "vnet_id" { value = azurerm_virtual_network.main.id }
output "aks_subnet_id" { value = azurerm_subnet.aks.id }
output "appgw_subnet_id" { value = azurerm_subnet.appgw.id }
output "pe_subnet_id" { value = azurerm_subnet.private_endpoints.id }
