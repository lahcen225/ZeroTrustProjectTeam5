output "bastion_public_ip" {
  value = azurerm_public_ip.bastion.ip_address
}

output "bastion_id" {
  value = azurerm_bastion_host.main.id
}
