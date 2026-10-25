# --- Resource Group ---
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

# --- Random suffix voor globaal unieke namen ---
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# --- Network: VNet, Subnets, NSGs ---
module "network" {
  source = "./modules/network"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  vnet_address_space  = var.vnet_address_space
}

# --- Bastion: SSH-beheer ---
module "bastion" {
  source = "./modules/bastion"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = module.network.subnet_bastion_id
}

# --- Wazuh: SIEM/XDR Manager ---
module "wazuh" {
  source = "./modules/wazuh"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = module.network.subnet_wazuh_id
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
}

# --- Compute: App VM (NGINX + Node.js API) ---
module "compute" {
  source = "./modules/compute"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = module.network.subnet_app_id
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  wazuh_manager_ip    = module.wazuh.wazuh_private_ip
}

# --- Application Gateway: WAF + HTTPS ---
module "appgateway" {
  source = "./modules/appgateway"

  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  subnet_id              = module.network.subnet_appgw_id
  frontend_vm_private_ip = module.compute.app_private_ip
  random_suffix          = random_string.suffix.result
}

# --- Database: MySQL Flexible Server ---
module "database" {
  source = "./modules/database"

  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  subnet_id            = module.network.subnet_database_id
  vnet_id              = module.network.vnet_id
  mysql_admin_username = var.mysql_admin_username
  mysql_admin_password = var.mysql_admin_password
}

# --- Honeypot: Nep patiëntendata + Decoy account ---
module "honeypot" {
  source = "./modules/honeypot"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = module.network.subnet_honeypot_id
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  wazuh_manager_ip    = module.wazuh.wazuh_private_ip
}
