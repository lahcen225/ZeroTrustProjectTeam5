output "app_vm_id" {
  value = azurerm_linux_virtual_machine.app.id
}

output "app_principal_id" {
  description = "System-assigned identity van vm-app (leest de app-secrets in Key Vault)."
  value       = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

output "app_private_ip" {
  value = azurerm_network_interface.app.private_ip_address
}
