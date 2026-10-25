# --- Frontend VM: NGINX ---
resource "azurerm_network_interface" "frontend" {
  name                = "nic-frontend"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "frontend-ip-config"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.10"
  }
}

resource "azurerm_linux_virtual_machine" "frontend" {
  name                            = "vm-frontend"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.frontend.id]

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
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx
  EOF
  )
}

# --- Backend VM: Node.js API ---
resource "azurerm_network_interface" "backend" {
  name                = "nic-backend"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "backend-ip-config"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.20"
  }
}

resource "azurerm_linux_virtual_machine" "backend" {
  name                            = "vm-backend"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.backend.id]

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
    apt-get install -y nodejs npm
    mkdir -p /opt/api
    cd /opt/api
    npm init -y
    npm install express mysql2
  EOF
  )
}
