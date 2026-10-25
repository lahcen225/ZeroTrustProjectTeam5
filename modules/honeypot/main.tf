resource "azurerm_network_interface" "honeypot" {
  name                = "nic-honeypot"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "honeypot-ip-config"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.2.68"
  }
}

resource "azurerm_linux_virtual_machine" "honeypot" {
  name                            = "vm-honeypot"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = "Standard_B1s"
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.honeypot.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y mysql-server
    systemctl enable mysql
    systemctl start mysql

    # Nep patiëntendata aanmaken
    mysql -e "CREATE DATABASE IF NOT EXISTS patienten_db;"
    mysql -e "CREATE TABLE IF NOT EXISTS patienten_db.patienten (id INT AUTO_INCREMENT PRIMARY KEY, naam VARCHAR(100), bsn VARCHAR(9), diagnose VARCHAR(200));"
    mysql -e "INSERT INTO patienten_db.patienten (naam, bsn, diagnose) VALUES ('Jan de Vries', '123456789', 'Griep'), ('Maria Jansen', '987654321', 'Controle');"

    # Decoy account aanmaken
    useradd -m -s /bin/bash decoyadmin
    echo "decoyadmin:HoneyP0t2024!" | chpasswd
  EOF
  )
}

resource "random_string" "honey_storage" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_storage_account" "honeypot" {
  name                     = "sthoney${random_string.honey_storage.result}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  network_rules {
    default_action             = "Deny"
    virtual_network_subnet_ids = [var.subnet_id]
  }
}

resource "azurerm_monitor_diagnostic_setting" "honeypot_storage" {
  name                       = "diag-honeypot-storage"
  target_resource_id         = "${azurerm_storage_account.honeypot.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  metric {
    category = "Transaction"
  }
}
