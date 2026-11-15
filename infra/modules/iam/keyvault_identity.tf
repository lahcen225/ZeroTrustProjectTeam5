# ---------------------------------------------------------------------------
# Key Vault voor de app-secrets. De backend op vm-app haalt het
# databasewachtwoord en het Entra client secret hieruit met zijn managed
# identity: geen wachtwoorden in code of .env.
# (Los van kv-zt-* in de appgateway-module, die het TLS-certificaat bewaart.)
# ---------------------------------------------------------------------------
data "azurerm_client_config" "huidig" {}

resource "azurerm_key_vault" "kv" {
  name                       = var.key_vault_naam
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.huidig.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true # toegang via RBAC i.p.v. access policies
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # true in productie; false zodat jullie kunnen opruimen
}

# Wie Terraform uitvoert, mag de secrets schrijven.
resource "azurerm_role_assignment" "terraform_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.huidig.object_id
}

# RBAC-rechten hebben even nodig om actief te worden.
resource "time_sleep" "kv_rbac" {
  depends_on      = [azurerm_role_assignment.terraform_kv]
  create_duration = "90s"
}

# De app (setup-veilig.sh) gebruikt de system-assigned identity van vm-app.
# Alleen LEZEN.
resource "azurerm_role_assignment" "app_vm_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.app_vm_principal_id
  principal_type       = "ServicePrincipal"
}

# Wachtwoord voor de MySQL-gebruiker van de app (securemed-db-gebruiker op vm-app)
resource "random_password" "db_app" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+"
}

resource "azurerm_key_vault_secret" "db_app" {
  name         = "db-app-wachtwoord"
  value        = random_password.db_app.result
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.kv_rbac]
}

resource "azurerm_key_vault_secret" "entra_client_secret" {
  count        = nonsensitive(var.entra_client_secret != null) ? 1 : 0
  name         = "entra-client-secret"
  value        = var.entra_client_secret
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.kv_rbac]
}

# ---------------------------------------------------------------------------
# Aanmelden op de Linux-VM's met Entra ID (schoolaccount) i.p.v. lokale
# accounts of gedeelde wachtwoorden. Vereist een system-assigned managed
# identity op de VM (zit in de compute- en wazuh-module).
# Niet op vm-honeypot: een decoy-VM mag geen echte aanmelding toelaten.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_machine_extension" "entra_ssh" {
  for_each = var.linux_vm_ids

  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = each.value
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}
