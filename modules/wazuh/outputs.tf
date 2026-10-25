output "wazuh_vm_id" {
  value = azurerm_linux_virtual_machine.wazuh.id
}

output "wazuh_private_ip" {
  value = azurerm_network_interface.wazuh.private_ip_address
}
