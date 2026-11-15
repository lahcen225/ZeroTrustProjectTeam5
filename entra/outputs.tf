# ---------------------------------------------------------------------------
# Configuratie voor de Node.js-app (niet geheim)
# ---------------------------------------------------------------------------
output "app_config" {
  description = "Waarden voor de OpenID Connect-configuratie van de Node.js-backend."
  value = {
    tenant_id     = var.tenant_id
    client_id     = azuread_application.securemed.client_id
    authority     = "https://login.microsoftonline.com/${var.tenant_id}"
    redirect_uris = var.app_redirect_uris
    app_rollen    = [for r in local.app_rollen : r.value]
  }
}

# Geheim: doorgeven aan ../azure (variabele entra_client_secret), die het in Key Vault zet.
output "app_client_secret" {
  value     = azuread_application_password.securemed.value
  sensitive = true
}

# ---------------------------------------------------------------------------
# Honeytoken en break-glass (voor Rik: detectieregels)
# ---------------------------------------------------------------------------
output "decoy_account" {
  value = {
    upn       = azuread_user.decoy.user_principal_name
    object_id = azuread_user.decoy.object_id
  }
}

output "decoy_wachtwoord" {
  description = "Plaats dit bewust op een 'vindbare' plek (bv. een nep-configbestand op de honeytoken-VM)."
  value       = random_password.decoy.result
  sensitive   = true
}

output "breakglass_accounts" {
  value = { for k, u in azuread_user.breakglass : u.user_principal_name => u.object_id }
}

output "breakglass_wachtwoorden" {
  description = "Offline bewaren."
  value       = { for k, p in random_password.breakglass : k => p.result }
  sensitive   = true
}

output "startwachtwoorden" {
  description = "Tijdelijk; wijzigen bij eerste aanmelding is verplicht."
  value = merge(
    { for k, p in random_password.medewerker : "${k}@${local.domein}" => p.result },
    { for k, p in random_password.admin : "${k}@${local.domein}" => p.result },
  )
  sensitive = true
}
