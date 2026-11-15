locals {
  # rol_toewijsbaar = true -> role-assignable group: alleen Privileged Role
  # Admins kunnen het lidmaatschap wijzigen. Verplicht voor Entra-rollen.
  groepen = {
    # Bedrijfsrollen -> app roles in de SecureMed-webapp
    artsen        = { beschrijving = "Artsen: patientdossiers lezen en schrijven", rol_toewijsbaar = false }
    verpleging    = { beschrijving = "Verpleging: patientdossiers alleen lezen", rol_toewijsbaar = false }
    administratie = { beschrijving = "Receptie/administratie: afspraken en facturatie, geen medische data", rol_toewijsbaar = false }
    management    = { beschrijving = "Praktijkmanager: rapportages, geen medische data", rol_toewijsbaar = false }

    # Beheergroepen -> Entra-rollen in deze tenant
    adm-privileged = { beschrijving = "Global Admin en Privileged Role Admin", rol_toewijsbaar = true }
    adm-identiteit = { beschrijving = "Gebruikers, MFA, apps en Conditional Access beheren", rol_toewijsbaar = true }
    adm-security   = { beschrijving = "Security-instellingen en sign-in logs", rol_toewijsbaar = true }
    audit          = { beschrijving = "Compliance en audit: alleen lezen", rol_toewijsbaar = true }
  }
}

resource "azuread_group" "groep" {
  for_each = local.groepen

  display_name            = "grp-${each.key}"
  description             = each.value.beschrijving
  security_enabled        = true
  assignable_to_role      = each.value.rol_toewijsbaar
  prevent_duplicate_names = true

  members = concat(
    [for k, m in local.medewerkers : azuread_user.medewerker[k].object_id if m.groep == each.key],
    [for k, a in local.admin_accounts : azuread_user.admin[k].object_id if contains(a.groepen, each.key)],
  )
}
