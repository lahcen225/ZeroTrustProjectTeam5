locals {
  entra_rollen = toset([
    "Global Administrator",
    "Privileged Role Administrator",
    "Conditional Access Administrator",
    "Application Administrator",
    "Security Administrator",
    "Security Reader",
    "User Administrator",
    "Helpdesk Administrator",
    "Authentication Administrator",
    "Global Reader",
  ])

  # pim = true  -> just-in-time via PIM (als heeft_p2 = true), anders permanent
  # pim = false -> altijd permanent (alleen leesrollen)
  entra_toewijzingen = {
    "privileged-ga"       = { groep = "adm-privileged", rol = "Global Administrator", pim = true }
    "privileged-pra"      = { groep = "adm-privileged", rol = "Privileged Role Administrator", pim = true }
    "identiteit-ca"       = { groep = "adm-identiteit", rol = "Conditional Access Administrator", pim = true }
    "identiteit-app"      = { groep = "adm-identiteit", rol = "Application Administrator", pim = true }
    "identiteit-user"     = { groep = "adm-identiteit", rol = "User Administrator", pim = true }
    "identiteit-auth"     = { groep = "adm-identiteit", rol = "Authentication Administrator", pim = true }
    "identiteit-helpdesk" = { groep = "adm-identiteit", rol = "Helpdesk Administrator", pim = true }
    "security-admin"      = { groep = "adm-security", rol = "Security Administrator", pim = true }
    "security-reader"     = { groep = "adm-security", rol = "Security Reader", pim = false }
    "audit-globalreader"  = { groep = "audit", rol = "Global Reader", pim = false }
  }
}

resource "azuread_directory_role" "rol" {
  for_each     = local.entra_rollen
  display_name = each.key
}

resource "azuread_directory_role_assignment" "permanent" {
  for_each = {
    for k, v in local.entra_toewijzingen : k => v
    if !v.pim || !var.heeft_p2
  }

  role_id             = azuread_directory_role.rol[each.value.rol].template_id
  principal_object_id = azuread_group.groep[each.value.groep].object_id
}

resource "azuread_directory_role_eligibility_schedule_request" "pim" {
  for_each = {
    for k, v in local.entra_toewijzingen : k => v
    if v.pim && var.heeft_p2
  }

  role_definition_id = azuread_directory_role.rol[each.value.rol].template_id
  principal_id       = azuread_group.groep[each.value.groep].object_id
  directory_scope_id = "/"
  justification      = "SecureMed Zero Trust: just-in-time beheerrechten"
}

resource "azuread_directory_role_assignment" "breakglass" {
  for_each = azuread_user.breakglass

  role_id             = azuread_directory_role.rol["Global Administrator"].template_id
  principal_object_id = each.value.object_id
}
