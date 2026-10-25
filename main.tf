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

# --- Log Analytics Workspace (gedeeld door sentinel en honeypot) ---
resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-zerotrust"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
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

# --- Compute: Frontend VM (NGINX) + Backend VM (Node.js) ---
module "compute" {
  source = "./modules/compute"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = module.network.subnet_app_id
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
}

# --- Application Gateway: WAF + HTTPS ---
module "appgateway" {
  source = "./modules/appgateway"

  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  subnet_id              = module.network.subnet_appgw_id
  frontend_vm_private_ip = module.compute.frontend_private_ip
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

  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  subnet_id                  = module.network.subnet_honeypot_id
  admin_username             = var.admin_username
  admin_password             = var.admin_password
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
}

# --- Sentinel: Alerts + VM Monitoring ---
module "sentinel" {
  source = "./modules/sentinel"

  resource_group_name                  = azurerm_resource_group.main.name
  location                             = azurerm_resource_group.main.location
  log_analytics_workspace_id           = azurerm_log_analytics_workspace.main.id
  log_analytics_workspace_workspace_id = azurerm_log_analytics_workspace.main.workspace_id
  log_analytics_workspace_key          = azurerm_log_analytics_workspace.main.primary_shared_key
  frontend_vm_id                       = module.compute.frontend_vm_id
  backend_vm_id                        = module.compute.backend_vm_id
  honeypot_vm_id                       = module.honeypot.honeypot_vm_id
}
