output "key_vault_naam" {
  value = azurerm_key_vault.kv.name
}

output "key_vault_uri" {
  description = "Voor de backend (KEY_VAULT_URI in setup-veilig.sh)."
  value       = azurerm_key_vault.kv.vault_uri
}

output "roltoewijzingen_team" {
  description = "Overzicht voor het verslag: wie heeft welke rol waarop."
  value = {
    for k, v in local.team_toewijzingen :
    k => "${v.rol} op ${replace(v.scope, local.rg_id, "<rg>")}"
  }
}
