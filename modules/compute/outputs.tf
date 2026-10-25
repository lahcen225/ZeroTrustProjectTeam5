output "app_vm_id" {
  value = azurerm_linux_virtual_machine.app.id
}

output "app_private_ip" {
  value = azurerm_network_interface.app.private_ip_address
}
