output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "vnet_name" {
  value = module.network.vnet_name
}

output "bastion_public_ip" {
  value = module.bastion.bastion_public_ip
}

output "appgw_public_ip" {
  value = module.appgateway.appgw_public_ip
}

output "frontend_vm_private_ip" {
  value = module.compute.frontend_private_ip
}

output "backend_vm_private_ip" {
  value = module.compute.backend_private_ip
}

output "mysql_server_fqdn" {
  value = module.database.mysql_server_fqdn
}

output "honeypot_vm_private_ip" {
  value = module.honeypot.honeypot_private_ip
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}
