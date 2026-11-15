# ---------------------------------------------------------------------------
# Least privilege voor het team (schoolaccounts) op de resource group
# ---------------------------------------------------------------------------
data "azuread_user" "team" {
  for_each            = var.team
  user_principal_name = each.value.upn
}

locals {
  rg_id = var.resource_group_id

  # Taak -> rollen. Network Contributor e.d. op RG-niveau geeft alleen rechten
  # op dat type resource (bv. netwerk), niet op de VM's of de data.
  taken = {
    lezer    = [{ rol = "Reader", scope = local.rg_id }] # ook nodig om via Bastion te verbinden
    netwerk  = [{ rol = "Network Contributor", scope = local.rg_id }]
    vm-admin = [{ rol = "Virtual Machine Administrator Login", scope = local.rg_id }] # SSH met sudo
    vm-user  = [{ rol = "Virtual Machine User Login", scope = local.rg_id }]          # SSH zonder sudo
    # Wazuh draait op een VM: de SOC-analist heeft sudo op vm-wazuh nodig, niet op de rest
    soc = [{ rol = "Virtual Machine Administrator Login", scope = var.linux_vm_ids["vm-wazuh"] }]
    # App uitrollen met az vm run-command (setup-veilig.sh), alleen op vm-app
    app-deploy = [{ rol = "Virtual Machine Contributor", scope = var.linux_vm_ids["vm-app"] }]
    keyvault   = [{ rol = "Key Vault Secrets Officer", scope = azurerm_key_vault.kv.id }]
    # Op de RG, zodat het ook werkt als wie Terraform uitvoert alleen Owner op de RG is
    compliance = [{ rol = "Security Reader", scope = local.rg_id }] # Defender for Cloud / CIS
    iam        = [{ rol = "Role Based Access Control Administrator", scope = local.rg_id }]
  }

  team_toewijzingen = merge([
    for persoon, p in var.team : merge([
      for taak in p.taken : {
        for i, r in local.taken[taak] : "${persoon}-${taak}-${i}" => {
          persoon = persoon
          rol     = r.rol
          scope   = r.scope
        }
      }
    ]...)
  ]...)
}

resource "azurerm_role_assignment" "team" {
  for_each = local.team_toewijzingen

  scope                = each.value.scope
  role_definition_name = each.value.rol
  principal_id         = data.azuread_user.team[each.value.persoon].object_id
  principal_type       = "User"
  description          = "SecureMed IAM: ${each.key}"
}
