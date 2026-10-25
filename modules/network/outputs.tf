output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "vnet_name" {
  value = azurerm_virtual_network.main.name
}

output "subnet_bastion_id" {
  value = azurerm_subnet.bastion.id
}

output "subnet_appgw_id" {
  value = azurerm_subnet.appgw.id
}

output "subnet_app_id" {
  value = azurerm_subnet.app.id
}

output "subnet_database_id" {
  value = azurerm_subnet.database.id
}

output "subnet_honeypot_id" {
  value = azurerm_subnet.honeypot.id
}
