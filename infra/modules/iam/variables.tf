variable "resource_group_name" {
  type = string
}

variable "resource_group_id" {
  type = string
}

variable "location" {
  type = string
}

variable "linux_vm_ids" {
  description = "VM's (naam -> id) waarop aanmelden met Entra ID aangezet wordt. Moet vm-wazuh bevatten (taak soc)."
  type        = map(string)
}

variable "app_vm_principal_id" {
  description = "Principal-ID van de system-assigned identity van vm-app (leest de app-secrets)."
  type        = string
}

variable "key_vault_naam" {
  description = "Naam voor de Key Vault met app-secrets (wereldwijd uniek, 3-24 tekens)."
  type        = string
}

variable "entra_client_secret" {
  description = "Client secret van de SecureMed-app, uit: terraform output -raw app_client_secret (in ../entra)."
  type        = string
  default     = null
  sensitive   = true
}

# Beschikbare taken: lezer, netwerk, vm-admin, vm-user, soc, app-deploy, keyvault, compliance, iam
variable "team" {
  description = "Teamleden met hun schoolaccount (UPN) en taken."
  type = map(object({
    upn   = string
    taken = list(string)
  }))

  validation {
    condition = alltrue(flatten([
      for p in values(var.team) : [
        for t in p.taken : contains(["lezer", "netwerk", "vm-admin", "vm-user", "soc", "app-deploy", "keyvault", "compliance", "iam"], t)
      ]
    ]))
    error_message = "Onbekende taak. Kies uit: lezer, netwerk, vm-admin, vm-user, soc, app-deploy, keyvault, compliance, iam."
  }
}
