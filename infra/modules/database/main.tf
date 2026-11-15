resource "azurerm_private_dns_zone" "mysql" {
  name                = "privatelink.mysql.database.azure.com"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                  = "mysql-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.mysql.name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_mysql_flexible_server" "main" {
  name                   = var.server_name # wereldwijd uniek (<naam>.mysql.database.azure.com)
  location               = var.location
  resource_group_name    = var.resource_group_name
  administrator_login    = var.mysql_admin_username
  administrator_password = var.mysql_admin_password
  sku_name               = "B_Standard_B1ms"
  version                = "8.0.21"
  zone                   = "1"

  delegated_subnet_id = var.subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.mysql.id

  storage {
    size_gb = 20
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.mysql]
}

resource "azurerm_mysql_flexible_database" "app" {
  name                = "securemed" # gebruikt door mysql/database.sql en de app
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}
