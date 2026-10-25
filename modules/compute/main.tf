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
    apt-get update

    # NGINX installeren (frontend)
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx

    # Node.js installeren (backend API)
    apt-get install -y nodejs npm
    mkdir -p /opt/api
    cd /opt/api
    npm init -y
    npm install express mysql2

    # NGINX reverse proxy configureren naar Node.js API
    cat > /etc/nginx/sites-available/api <<'NGINX'
    server {
        listen 3000;
        location / {
            proxy_pass http://127.0.0.1:3001;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
    NGINX
    ln -sf /etc/nginx/sites-available/api /etc/nginx/sites-enabled/api
    systemctl reload nginx

    # Wazuh agent installeren
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && chmod 644 /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | tee /etc/apt/sources.list.d/wazuh.list
    apt-get update
    WAZUH_MANAGER="${var.wazuh_manager_ip}" apt-get install -y wazuh-agent
    systemctl daemon-reload
    systemctl enable wazuh-agent
    systemctl start wazuh-agent
  EOF
  )
}
