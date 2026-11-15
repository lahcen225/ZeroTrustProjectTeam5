variable "tenant_id" {
  description = "Tenant-ID van de tenant van de docent."
  type        = string
}

variable "heeft_p1" {
  description = <<-EOF2
    true als de tenant Entra ID P1 (of hoger) heeft.
    Nodig voor Conditional Access en om groepen aan de app toe te wijzen.
    false -> geen CA-policies, en gebruikers worden rechtstreeks aan de app toegewezen.
  EOF2
  type        = bool
  default     = true
}

variable "heeft_p2" {
  description = "true als de tenant Entra ID P2 heeft: beheerrollen via PIM en blokkeren van riskante aanmeldingen."
  type        = bool
  default     = false
}

variable "ca_state" {
  description = "Status van de CA-policies. Begin in report-only en zet pas op 'enabled' na testen."
  type        = string
  default     = "enabledForReportingButNotEnforced"

  validation {
    condition     = contains(["enabled", "disabled", "enabledForReportingButNotEnforced"], var.ca_state)
    error_message = "ca_state moet 'enabled', 'disabled' of 'enabledForReportingButNotEnforced' zijn."
  }
}

variable "toegestane_landen" {
  description = "Landen (ISO-code) van waaruit aanmelden toegestaan is."
  type        = list(string)
  default     = ["BE"]
}

variable "app_redirect_uris" {
  description = <<-EOF2
    Waar Entra de gebruiker na het aanmelden naar terugstuurt.
    Productie: https://<publiek adres van de Application Gateway>/auth/callback
    Lokaal testen: http://localhost:3000/auth/callback
  EOF2
  type        = list(string)
  default     = ["http://localhost:3000/auth/callback"]
}
