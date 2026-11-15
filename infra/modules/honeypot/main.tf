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
  size                            = var.vm_size
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

    # Elke query loggen (Wazuh-regel 100006: nepdata gelezen)
    cat > /etc/mysql/mysql.conf.d/zz-honeypot-log.cnf <<'CNF'
    [mysqld]
    general_log      = 1
    general_log_file = /var/log/mysql/general.log
    CNF
    systemctl restart mysql

    # Lokaas: "vergeten" configbestand met DB-gegevens die alleen de nepdata kunnen lezen
    mysql -e "CREATE USER IF NOT EXISTS 'patient_app'@'localhost' IDENTIFIED BY 'Welkom2024!'; GRANT SELECT ON patienten_db.* TO 'patient_app'@'localhost';"
    cat > /home/decoyadmin/app-config.env <<'ENV'
    # SecureMed patientportaal - productie (NIET DELEN)
    DB_HOST=localhost
    DB_NAME=patienten_db
    DB_USER=patient_app
    DB_PASSWORD=Welkom2024!
    ENV
    chown decoyadmin: /home/decoyadmin/app-config.env
    chmod 600 /home/decoyadmin/app-config.env

    # Wazuh agent installeren
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && chmod 644 /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | tee /etc/apt/sources.list.d/wazuh.list
    apt-get update
    # Zelfde versie als de manager (4.9.2): nieuwere agents worden geweigerd
    WAZUH_MANAGER="${var.wazuh_manager_ip}" apt-get install -y wazuh-agent=4.9.2-1
    apt-mark hold wazuh-agent
    cat >> /var/ossec/etc/ossec.conf <<'XML'

    <ossec_config>
      <localfile>
        <log_format>syslog</log_format>
        <location>/var/log/mysql/general.log</location>
      </localfile>
    </ossec_config>
    XML
    systemctl daemon-reload
    systemctl enable wazuh-agent
    systemctl start wazuh-agent
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


# Wachten tot de installatie (cloud-init: MySQL, decoy-account, Wazuh-agent)
# klaar is, en pas dan de honeypot van het internet afsluiten. Anders kan de
# VM bij het opstarten niets downloaden.
resource "azurerm_virtual_machine_run_command" "wacht_op_installatie" {
  name               = "wacht-op-installatie"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.honeypot.id

  source {
    script = "cloud-init status --wait || true; systemctl is-active wazuh-agent mysql"
  }
}

resource "azurerm_network_security_rule" "deny_internet" {
  name                        = "Deny-Internet-Outbound"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "10.0.2.64/26"
  destination_address_prefix  = "Internet"
  resource_group_name         = var.resource_group_name
  network_security_group_name = var.nsg_name

  depends_on = [azurerm_virtual_machine_run_command.wacht_op_installatie]
}
