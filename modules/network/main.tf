resource "azurerm_virtual_network" "main" {
  name                = "vnet-zerotrust"
  address_space       = var.vnet_address_space
  location            = var.location
  resource_group_name = var.resource_group_name
}

# --- Public Subnet: Azure Bastion ---
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.0.0/26"]
}

# --- Public Subnet: Application Gateway ---
resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.0.64/26"]
}

# --- Private Subnet: App (Frontend + Backend VMs) ---
resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

# --- Private Subnet: Database ---
resource "azurerm_subnet" "database" {
  name                 = "snet-database"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/26"]

  delegation {
    name = "mysql-delegation"
    service_delegation {
      name    = "Microsoft.DBforMySQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# --- Private Subnet: Honeypot ---
resource "azurerm_subnet" "honeypot" {
  name                 = "snet-honeypot"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.64/26"]
  service_endpoints    = ["Microsoft.Storage"]
}

# --- Private Subnet: Wazuh ---
resource "azurerm_subnet" "wazuh" {
  name                 = "snet-wazuh"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.3.0/26"]
}

# --- NSG: App Subnet ---
resource "azurerm_network_security_group" "app" {
  name                = "nsg-app"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "Allow-HTTP-From-AppGW"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "10.0.0.64/26"
    destination_address_prefix = "10.0.1.0/24"
  }

  security_rule {
    name                       = "Allow-SSH-From-Bastion"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.0.0/26"
    destination_address_prefix = "10.0.1.0/24"
  }

  security_rule {
    name                       = "Allow-Frontend-To-Backend"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "10.0.1.0/24"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# --- NSG: Database Subnet ---
resource "azurerm_network_security_group" "database" {
  name                = "nsg-database"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "Allow-MySQL-From-App"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3306"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "10.0.2.0/26"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "database" {
  subnet_id                 = azurerm_subnet.database.id
  network_security_group_id = azurerm_network_security_group.database.id
}

# --- NSG: Honeypot Subnet ---
resource "azurerm_network_security_group" "honeypot" {
  name                = "nsg-honeypot"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "Allow-All-Inbound-Honeypot"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "10.0.2.64/26"
  }

  security_rule {
    name                       = "Deny-Internet-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.2.64/26"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "honeypot" {
  subnet_id                 = azurerm_subnet.honeypot.id
  network_security_group_id = azurerm_network_security_group.honeypot.id
}

# --- NSG: Wazuh Subnet ---
resource "azurerm_network_security_group" "wazuh" {
  name                = "nsg-wazuh"
  location            = var.location
  resource_group_name = var.resource_group_name

  # Wazuh agent registratie (port 1514/1515)
  security_rule {
    name                       = "Allow-Wazuh-Agent-Registration"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["1514", "1515"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "10.0.3.0/26"
  }

  # Wazuh Dashboard (port 443)
  security_rule {
    name                       = "Allow-Wazuh-Dashboard"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "10.0.3.0/26"
  }

  # SSH via Bastion
  security_rule {
    name                       = "Allow-SSH-From-Bastion"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.0.0/26"
    destination_address_prefix = "10.0.3.0/26"
  }

  # Wazuh Indexer API (port 9200)
  security_rule {
    name                       = "Allow-Wazuh-Indexer"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9200"
    source_address_prefix      = "10.0.3.0/26"
    destination_address_prefix = "10.0.3.0/26"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "wazuh" {
  subnet_id                 = azurerm_subnet.wazuh.id
  network_security_group_id = azurerm_network_security_group.wazuh.id
}
