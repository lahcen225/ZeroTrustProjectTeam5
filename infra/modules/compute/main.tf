# --- Combined VM: NGINX (Frontend) + Node.js API (Backend) ---
resource "azurerm_network_interface" "app" {
  name                = "nic-app"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "app-ip-config"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.10"
  }
}

resource "azurerm_linux_virtual_machine" "app" {
  name                            = "vm-app"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.app.id]

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
    # De app zelf (NGINX + Node.js 20) komt van setup-veilig.sh of setup-alles.sh,
    # uitgevoerd met az vm run-command na terraform apply. Hier alleen de basis.
    apt-get update

    # Wazuh agent installeren
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && chmod 644 /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | tee /etc/apt/sources.list.d/wazuh.list
    apt-get update
    # Zelfde versie als de manager (4.9.2): nieuwere agents worden geweigerd
    WAZUH_MANAGER="${var.wazuh_manager_ip}" apt-get install -y wazuh-agent=4.9.2-1
    apt-mark hold wazuh-agent
    systemctl daemon-reload
    systemctl enable wazuh-agent
    systemctl start wazuh-agent
  EOF
  )
}
