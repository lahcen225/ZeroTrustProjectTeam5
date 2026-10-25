resource "azurerm_network_interface" "wazuh" {
  name                = "nic-wazuh"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "wazuh-ip-config"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.3.10"
  }
}

resource "azurerm_linux_virtual_machine" "wazuh" {
  name                            = "vm-wazuh"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.wazuh.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 50
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
    set -e

    # Wazuh all-in-one installatie (manager + indexer + dashboard)
    curl -sO https://packages.wazuh.com/4.9/wazuh-install.sh
    curl -sO https://packages.wazuh.com/4.9/config.yml

    # config.yml aanpassen voor single-node
    cat > config.yml <<'CONFIG'
    nodes:
      indexer:
        - name: wazuh-indexer
          ip: "10.0.3.10"
      server:
        - name: wazuh-server
          ip: "10.0.3.10"
      dashboard:
        - name: wazuh-dashboard
          ip: "10.0.3.10"
    CONFIG

    bash wazuh-install.sh --generate-config-files
    bash wazuh-install.sh --wazuh-indexer wazuh-indexer
    bash wazuh-install.sh --start-cluster
    bash wazuh-install.sh --wazuh-server wazuh-server
    bash wazuh-install.sh --wazuh-dashboard wazuh-dashboard

    # Honeypot detectie regels toevoegen
    cat >> /var/ossec/etc/rules/local_rules.xml <<'RULES'
    <group name="honeypot,">
      <rule id="100001" level="15">
        <if_sid>5716</if_sid>
        <match>decoyadmin</match>
        <description>ALARM: Decoy account login gedetecteerd</description>
      </rule>

      <rule id="100002" level="15">
        <if_sid>5715</if_sid>
        <hostname>vm-honeypot</hostname>
        <description>ALARM: SSH login op honeypot VM gedetecteerd</description>
      </rule>

      <rule id="100003" level="12">
        <if_sid>5501</if_sid>
        <hostname>vm-honeypot</hostname>
        <description>ALARM: Login poging op honeypot VM</description>
      </rule>
    </group>
    RULES

    systemctl restart wazuh-manager
  EOF
  )
}
