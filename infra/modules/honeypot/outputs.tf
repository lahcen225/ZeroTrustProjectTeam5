output "honeypot_vm_id" {
  value = azurerm_linux_virtual_machine.honeypot.id
}

output "honeypot_private_ip" {
  value = azurerm_network_interface.honeypot.private_ip_address
}

output "honeypot_storage_account_name" {
  value = azurerm_storage_account.honeypot.name
}
