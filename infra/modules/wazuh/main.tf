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

      <!-- Elke mislukte login op de honeypot (bv. brute force met andere namen).
           5760 = "sshd: authentication failed" in Wazuh 4.9 (5716 in oudere versies) -->
      <rule id="100004" level="12">
        <if_sid>5716, 5760, 5503</if_sid>
        <hostname>vm-honeypot</hostname>
        <description>ALARM: Mislukte login op honeypot VM</description>
      </rule>

      <!-- ... en met het decoy-account: hoogste alarm.
           Niet 100001: dat ID heeft de voorbeeldregel in de standaard local_rules.xml al -->
      <rule id="100005" level="15">
        <if_sid>100004</if_sid>
        <match>decoyadmin</match>
        <description>ALARM: Mislukte login met het decoy-account</description>
      </rule>

      <!-- Iemand leest de nep-patientendata in de honeypot-database (MySQL query-log) -->
      <rule id="100006" level="15">
        <location>/var/log/mysql/general.log</location>
        <match>patienten</match>
        <description>ALARM: nep-patientendata op de honeypot gelezen</description>
      </rule>
    </group>

    <!-- Audit-log van de SecureMed-app op vm-app (/var/log/securemed/audit.log, JSON) -->
    <group name="securemed,">
      <rule id="100200" level="3">
        <decoded_as>json</decoded_as>
        <field name="app">securemed</field>
        <description>SecureMed: $(event)</description>
      </rule>

      <rule id="100201" level="12">
        <if_sid>100200</if_sid>
        <field name="event">honeytoken_gebruikt</field>
        <description>ALARM: SecureMed honeytoken "$(poging_gebruiker)" gebruikt vanaf $(ip)</description>
      </rule>

      <rule id="100202" level="7">
        <if_sid>100200</if_sid>
        <field name="event">toegang_geweigerd|login_geweigerd|login_zonder_rol</field>
        <description>SecureMed: geweigerde toegang ($(event)) voor $(gebruiker)</description>
      </rule>
    </group>
    RULES

    # Discord-integratie (eigen script: de ingebouwde Slack-integratie geeft 400 bij Discord)
    echo '${filebase64("${path.module}/custom-discord.py")}' | base64 -d > /var/ossec/integrations/custom-discord.py
    cp /var/ossec/integrations/slack /var/ossec/integrations/custom-discord
    chown root:wazuh /var/ossec/integrations/custom-discord /var/ossec/integrations/custom-discord.py
    chmod 750 /var/ossec/integrations/custom-discord /var/ossec/integrations/custom-discord.py

    # Active response: honeypot-aanvaller 10 minuten blokkeren (firewall op de honeypot)
    # + optioneel melding naar Discord vanaf level 12
    cat >> /var/ossec/etc/ossec.conf <<'XML'

    <ossec_config>
      <active-response>
        <command>firewall-drop</command>
        <location>local</location>
        <rules_id>100002,100005</rules_id>
        <timeout>600</timeout>
      </active-response>
    %{if var.discord_webhook_url != null~}
      <integration>
        <name>custom-discord</name>
        <hook_url>${var.discord_webhook_url}</hook_url>
        <level>12</level>
        <alert_format>json</alert_format>
      </integration>
    %{endif~}
    </ossec_config>
    XML

    systemctl restart wazuh-manager
  EOF
  )
}
