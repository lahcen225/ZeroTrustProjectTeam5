# ---------------------------------------------------------------------------
# App registration voor de SecureMed-webapp (NGINX + Node.js op de VM's in
# de schoolsubscription). De app laat gebruikers aanmelden via deze tenant
# (OpenID Connect) en leest de rol uit de "roles"-claim van het token.
# ---------------------------------------------------------------------------
locals {
  # groep -> app role. value = de tekst die in de "roles"-claim komt.
  app_rollen = {
    artsen        = { value = "Arts", naam = "Arts", beschrijving = "Patientdossiers lezen en schrijven" }
    verpleging    = { value = "Verpleging", naam = "Verpleging", beschrijving = "Patientdossiers alleen lezen" }
    administratie = { value = "Administratie", naam = "Administratie", beschrijving = "Afspraken en facturatie, geen medische data" }
    management    = { value = "Management", naam = "Management", beschrijving = "Rapportages, geen medische data" }
  }

  microsoft_graph_app_id = "00000003-0000-0000-c000-000000000000"
  graph_user_read_id     = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read (delegated)
}

resource "random_uuid" "app_rol" {
  for_each = local.app_rollen
}

resource "azuread_application" "securemed" {
  display_name     = "SecureMed Patientportaal"
  sign_in_audience = "AzureADMyOrg" # alleen accounts uit deze tenant

  dynamic "app_role" {
    for_each = local.app_rollen
    content {
      allowed_member_types = ["User"]
      display_name         = app_role.value.naam
      description          = app_role.value.beschrijving
      value                = app_role.value.value
      id                   = random_uuid.app_rol[app_role.key].result
      enabled              = true
    }
  }

  web {
    redirect_uris = var.app_redirect_uris

    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  required_resource_access {
    resource_app_id = local.microsoft_graph_app_id

    resource_access {
      id   = local.graph_user_read_id
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "securemed" {
  client_id = azuread_application.securemed.client_id

  # Zero Trust: alleen wie expliciet een app role heeft, kan aanmelden.
  # Het decoy-account en de beheeraccounts krijgen dus een fout.
  app_role_assignment_required = true
}

# Admin consent voor de aanmeldrechten. De tenant staat gebruikers niet toe
# zelf toestemming te geven aan apps; hier keurt de beheerder het één keer
# goed voor de hele organisatie (alleen basisrechten, geen toegang tot data).
data "azuread_service_principal" "msgraph" {
  client_id = local.microsoft_graph_app_id
}

resource "azuread_service_principal_delegated_permission_grant" "securemed" {
  service_principal_object_id          = azuread_service_principal.securemed.object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = ["openid", "profile", "offline_access", "User.Read"]
}

# Client secret voor de Node.js-backend. Wordt in de Key Vault van de
# schoolsubscription bewaard (zie ../azure), nooit in de code.
resource "azuread_application_password" "securemed" {
  application_id    = azuread_application.securemed.id
  display_name      = "securemed-backend"
  end_date_relative = "2160h" # 90 dagen, daarna roteren
}

# ---------------------------------------------------------------------------
# Wie krijgt welke app role?
# Met P1: de groep wordt toegewezen (beheer via groepslidmaatschap).
# Zonder P1: elke gebruiker afzonderlijk (groepstoewijzing vereist P1).
# ---------------------------------------------------------------------------
resource "azuread_app_role_assignment" "groep" {
  for_each = var.heeft_p1 ? local.app_rollen : {}

  app_role_id         = azuread_service_principal.securemed.app_role_ids[each.value.value]
  principal_object_id = azuread_group.groep[each.key].object_id
  resource_object_id  = azuread_service_principal.securemed.object_id
}

resource "azuread_app_role_assignment" "gebruiker" {
  for_each = var.heeft_p1 ? {} : {
    for k, m in local.medewerkers : k => m if m.groep != null
  }

  app_role_id         = azuread_service_principal.securemed.app_role_ids[local.app_rollen[each.value.groep].value]
  principal_object_id = azuread_user.medewerker[each.key].object_id
  resource_object_id  = azuread_service_principal.securemed.object_id
}
