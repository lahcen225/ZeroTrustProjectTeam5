# ---------------------------------------------------------------------------
# Conditional Access (vereist Entra ID P1). Alle policies sluiten de
# break-glass accounts uit. Standaard in report-only (var.ca_state).
# ---------------------------------------------------------------------------
locals {
  ca_aantal      = var.heeft_p1 ? 1 : 0
  breakglass_ids = [for u in azuread_user.breakglass : u.object_id]

  admin_rol_ids = [
    for naam, r in azuread_directory_role.rol : r.template_id
    if !contains(["Security Reader", "Global Reader"], naam)
  ]
}

# CA01 - MFA voor iedereen, voor alle apps
resource "azuread_conditional_access_policy" "mfa_iedereen" {
  count        = local.ca_aantal
  display_name = "CA01 - MFA verplicht voor alle gebruikers"
  state        = var.ca_state

  conditions {
    client_app_types = ["all"]
    applications {
      included_applications = ["All"]
    }
    users {
      included_users = ["All"]
      excluded_users = local.breakglass_ids
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["mfa"]
  }
}

# CA02 - Legacy authentication blokkeren
resource "azuread_conditional_access_policy" "blokkeer_legacy" {
  count        = local.ca_aantal
  display_name = "CA02 - Blokkeer legacy authentication"
  state        = var.ca_state

  conditions {
    client_app_types = ["exchangeActiveSync", "other"]
    applications {
      included_applications = ["All"]
    }
    users {
      included_users = ["All"]
      excluded_users = local.breakglass_ids
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["block"]
  }
}

# CA03 - Beheerrollen: MFA, elke 4 uur opnieuw aanmelden
resource "azuread_conditional_access_policy" "admins" {
  count        = local.ca_aantal
  display_name = "CA03 - Beheerrollen: MFA en korte sessies"
  state        = var.ca_state

  conditions {
    client_app_types = ["all"]
    applications {
      included_applications = ["All"]
    }
    users {
      included_roles = local.admin_rol_ids
      excluded_users = local.breakglass_ids
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["mfa"]
  }

  session_controls {
    sign_in_frequency        = 4
    sign_in_frequency_period = "hours"
    persistent_browser_mode  = "never"
  }
}

# CA04 - Aanmelden buiten de toegestane landen blokkeren
resource "azuread_named_location" "toegestane_landen" {
  count        = local.ca_aantal
  display_name = "Toegestane landen SecureMed"

  country {
    countries_and_regions                 = var.toegestane_landen
    include_unknown_countries_and_regions = false
  }
}

resource "azuread_conditional_access_policy" "blokkeer_buitenland" {
  count        = local.ca_aantal
  display_name = "CA04 - Blokkeer aanmeldingen buiten toegestane landen"
  state        = var.ca_state

  conditions {
    client_app_types = ["all"]
    applications {
      included_applications = ["All"]
    }
    users {
      included_users = ["All"]
      excluded_users = local.breakglass_ids
    }
    locations {
      included_locations = ["All"]
      excluded_locations = [azuread_named_location.toegestane_landen[0].id]
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["block"]
  }
}

# CA05 - SecureMed-app (patientdata): MFA en elke 8 uur (een werkdag) opnieuw aanmelden
resource "azuread_conditional_access_policy" "securemed_app" {
  count        = local.ca_aantal
  display_name = "CA05 - SecureMed Patientportaal: MFA en sessie max 8 uur"
  state        = var.ca_state

  conditions {
    client_app_types = ["all"]
    applications {
      included_applications = [azuread_application.securemed.client_id]
    }
    users {
      included_users = ["All"]
      excluded_users = local.breakglass_ids
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["mfa"]
  }

  # Geen persistent_browser_mode: Entra staat dat alleen toe op policies voor
  # alle cloud-apps (CA03 dekt dat al voor beheerders).
  session_controls {
    sign_in_frequency        = 8
    sign_in_frequency_period = "hours"
  }
}

# CA06 - Aanmeldingen met hoog risico blokkeren (vereist P2)
resource "azuread_conditional_access_policy" "blokkeer_risico" {
  count        = var.heeft_p1 && var.heeft_p2 ? 1 : 0
  display_name = "CA06 - Blokkeer aanmeldingen met hoog risico"
  state        = var.ca_state

  conditions {
    client_app_types    = ["all"]
    sign_in_risk_levels = ["high"]
    applications {
      included_applications = ["All"]
    }
    users {
      included_users = ["All"]
      excluded_users = local.breakglass_ids
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["block"]
  }
}
