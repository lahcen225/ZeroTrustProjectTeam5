data "azuread_domains" "tenant" {
  only_initial = true
}

locals {
  domein = data.azuread_domains.tenant.domains[0].domain_name

  # 15 fictieve medewerkers. groep = bedrijfsrol (zie groups.tf) en bepaalt
  # de app role in de SecureMed-webapp. null = geen toegang tot de app.
  medewerkers = {
    "an.peeters"      = { naam = "An Peeters", functie = "Arts", groep = "artsen" }
    "jan.claes"       = { naam = "Jan Claes", functie = "Arts", groep = "artsen" }
    "sofie.maes"      = { naam = "Sofie Maes", functie = "Arts", groep = "artsen" }
    "pieter.jacobs"   = { naam = "Pieter Jacobs", functie = "Arts", groep = "artsen" }
    "lotte.willems"   = { naam = "Lotte Willems", functie = "Verpleegkundige", groep = "verpleging" }
    "tom.mertens"     = { naam = "Tom Mertens", functie = "Verpleegkundige", groep = "verpleging" }
    "emma.goossens"   = { naam = "Emma Goossens", functie = "Verpleegkundige", groep = "verpleging" }
    "lars.wouters"    = { naam = "Lars Wouters", functie = "Verpleegkundige", groep = "verpleging" }
    "nina.desmet"     = { naam = "Nina De Smet", functie = "Verpleegkundige", groep = "verpleging" }
    "ines.dubois"     = { naam = "Ines Dubois", functie = "Receptie", groep = "administratie" }
    "bram.lambert"    = { naam = "Bram Lambert", functie = "Administratie", groep = "administratie" }
    "julie.hermans"   = { naam = "Julie Hermans", functie = "Facturatie", groep = "administratie" }
    "eva.janssens"    = { naam = "Eva Janssens", functie = "Receptie", groep = "administratie" }
    "karel.vermeulen" = { naam = "Karel Vermeulen", functie = "Praktijkmanager", groep = "management" }
    "dries.michiels"  = { naam = "Dries Michiels", functie = "IT (extern)", groep = null }
  }

  # Aparte beheeraccounts voor het beheer van deze tenant (nooit voor dagelijks werk).
  # Het beheer van de Azure-resources gebeurt met de schoolaccounts (zie ../azure).
  admin_accounts = {
    "adm-alan"   = { naam = "ADM Alan Skrodzki", groepen = ["adm-privileged", "adm-identiteit"] }
    "adm-rik"    = { naam = "ADM Rik Vangeel", groepen = ["adm-security"] }
    "adm-lahcen" = { naam = "ADM Lahcen Oualach", groepen = ["audit"] }
    "adm-dries"  = { naam = "ADM Dries Michiels", groepen = ["adm-identiteit"] }
  }

  breakglass_accounts = toset(["breakglass01", "breakglass02"])
}

# ---------------------------------------------------------------------------
# Medewerkers
# ---------------------------------------------------------------------------
resource "random_password" "medewerker" {
  for_each    = local.medewerkers
  length      = 20
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

resource "azuread_user" "medewerker" {
  for_each = local.medewerkers

  user_principal_name   = "${each.key}@${local.domein}"
  display_name          = each.value.naam
  job_title             = each.value.functie
  department            = "SecureMed Clinic"
  usage_location        = "BE"
  password              = random_password.medewerker[each.key].result
  force_password_change = true
}

# ---------------------------------------------------------------------------
# Beheeraccounts
# ---------------------------------------------------------------------------
resource "random_password" "admin" {
  for_each    = local.admin_accounts
  length      = 24
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

resource "azuread_user" "admin" {
  for_each = local.admin_accounts

  user_principal_name   = "${each.key}@${local.domein}"
  display_name          = each.value.naam
  department            = "IT-beheer"
  usage_location        = "BE"
  password              = random_password.admin[each.key].result
  force_password_change = true
}

# ---------------------------------------------------------------------------
# Break-glass accounts: permanent Global Admin, uitgesloten van CA.
# ---------------------------------------------------------------------------
resource "random_password" "breakglass" {
  for_each    = local.breakglass_accounts
  length      = 64
  special     = true
  min_upper   = 4
  min_lower   = 4
  min_numeric = 4
  min_special = 4
}

resource "azuread_user" "breakglass" {
  for_each = local.breakglass_accounts

  user_principal_name   = "${each.key}@${local.domein}"
  display_name          = "Break Glass ${substr(each.key, -2, 2)}"
  usage_location        = "BE"
  password              = random_password.breakglass[each.key].result
  force_password_change = false
}

# ---------------------------------------------------------------------------
# Honeytoken: decoy-account zonder enige rol, groep of app-toegang.
# Elke aanmeldpoging is per definitie verdacht.
# ---------------------------------------------------------------------------
resource "random_password" "decoy" {
  length  = 32
  special = true
}

resource "azuread_user" "decoy" {
  user_principal_name   = "svc-backup-admin@${local.domein}"
  display_name          = "Backup Admin (service)"
  job_title             = "Backup Service Account"
  department            = "IT-beheer"
  usage_location        = "BE"
  password              = random_password.decoy.result
  force_password_change = false
}
