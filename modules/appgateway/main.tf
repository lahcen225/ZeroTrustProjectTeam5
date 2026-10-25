resource "azurerm_public_ip" "appgw" {
  name                = "pip-appgw"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Self-signed certificaat genereren voor Application Gateway
resource "tls_private_key" "appgw" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "appgw" {
  private_key_pem = tls_private_key.appgw.private_key_pem

  subject {
    common_name  = "appgw-zerotrust.local"
    organization = "Zero Trust Lab"
  }

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# Key Vault voor het opslaan van het certificaat
resource "azurerm_key_vault" "appgw" {
  name                       = "kv-zt-${var.random_suffix}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions      = ["Get", "List", "Set", "Delete", "Purge"]
    certificate_permissions = ["Get", "List", "Create", "Import", "Delete", "Purge"]
  }
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault_certificate" "appgw" {
  name         = "appgw-ssl-cert"
  key_vault_id = azurerm_key_vault.appgw.id

  certificate {
    contents = base64encode(join("", [
      tls_private_key.appgw.private_key_pem,
      tls_self_signed_cert.appgw.cert_pem,
    ]))
  }
}

# --- Application Gateway ---
resource "azurerm_user_assigned_identity" "appgw" {
  name                = "id-appgw"
  location            = var.location
  resource_group_name = var.resource_group_name
}

resource "azurerm_key_vault_access_policy" "appgw_identity" {
  key_vault_id = azurerm_key_vault.appgw.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.appgw.principal_id

  secret_permissions      = ["Get"]
  certificate_permissions = ["Get"]
}

resource "azurerm_application_gateway" "main" {
  name                = "appgw-zerotrust"
  location            = var.location
  resource_group_name = var.resource_group_name

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw.id]
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = var.subnet_id
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  backend_address_pool {
    name         = "frontend-vm-pool"
    ip_addresses = [var.frontend_vm_private_ip]
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 30
  }

  ssl_certificate {
    name                = "appgw-ssl-cert"
    key_vault_secret_id = azurerm_key_vault_certificate.appgw.secret_id
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    ssl_certificate_name           = "appgw-ssl-cert"
  }

  request_routing_rule {
    name                       = "routing-rule"
    priority                   = 1
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "frontend-vm-pool"
    backend_http_settings_name = "http-settings"
  }

  waf_configuration {
    enabled          = true
    firewall_mode    = "Prevention"
    rule_set_type    = "OWASP"
    rule_set_version = "3.2"
  }

  depends_on = [azurerm_key_vault_access_policy.appgw_identity]
}
