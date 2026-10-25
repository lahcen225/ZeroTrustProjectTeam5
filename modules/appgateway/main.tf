resource "azurerm_public_ip" "appgw" {
  name                = "pip-appgw"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Key Vault voor het certificaat
data "azurerm_client_config" "current" {}

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

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

# Self-signed certificaat direct in Key Vault genereren
resource "azurerm_key_vault_certificate" "appgw" {
  name         = "appgw-ssl-cert"
  key_vault_id = azurerm_key_vault.appgw.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=appgw-zerotrust.local"
      validity_in_months = 12

      key_usage = [
        "digitalSignature",
        "keyEncipherment",
      ]
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }

      trigger {
        days_before_expiry = 30
      }
    }
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
    port                  = 80
    protocol              = "Http"
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

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  firewall_policy_id = azurerm_web_application_firewall_policy.main.id

  depends_on = [azurerm_key_vault_access_policy.appgw_identity]
}

resource "azurerm_web_application_firewall_policy" "main" {
  name                = "waf-policy-zerotrust"
  resource_group_name = var.resource_group_name
  location            = var.location

  policy_settings {
    enabled                     = true
    mode                        = "Prevention"
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}
