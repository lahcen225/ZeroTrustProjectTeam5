variable "tenant_id" {
  description = "Tenant-ID van de school (waar de subscription aan hangt)."
  type        = string
}

variable "subscription_id" {
  description = "ID van de Azure for Students-subscription."
  type        = string
}

variable "resource_group_name" {
  type    = string
  default = "rg-zerotrust"
}

variable "dns_label" {
  description = "DNS-label van de Application Gateway. Moet overeenkomen met de redirect URI in ../entra en BASE_URL in setup-veilig.sh."
  type        = string
  default     = "securemed-zt"
}

variable "key_vault_naam" {
  description = "Key Vault voor de app-secrets (wereldwijd uniek, 3-24 tekens, bv. kv-securemed-<studentnr>)."
  type        = string
}

variable "entra_client_secret" {
  description = "Client secret van de SecureMed-app: terraform \"-chdir=../entra\" output -raw app_client_secret"
  type        = string
  default     = null
  sensitive   = true
}

# Taken: lezer, netwerk, vm-admin, vm-user, soc, app-deploy, keyvault, compliance, iam
# (zie locals.taken in modules/iam/rbac.tf)
variable "team" {
  description = "Teamleden met hun schoolaccount (UPN = studentnummer@student.pxl.be) en taken."
  type = map(object({
    upn   = string
    taken = list(string)
  }))
}

variable "location" {
  type    = string
  default = "Sweden Central"
}

variable "vnet_address_space" {
  type    = list(string)
  default = ["10.0.0.0/16"]
}

variable "admin_username" {
  type    = string
  default = "azureadmin"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "mysql_admin_username" {
  type    = string
  default = "mysqladmin"
}

variable "mysql_admin_password" {
  type      = string
  sensitive = true
}

variable "vm_size" {
  type    = string
  default = "Standard_B2s_v2"
}

variable "mysql_server_name" {
  description = "Naam van de MySQL Flexible Server (wereldwijd uniek). Moet overeenkomen met DB_HOST in setup-veilig.sh."
  type        = string
  default     = "mysql-zerotrust"
}

variable "discord_webhook_url" {
  description = "Discord-webhook (Serverinstellingen > Integraties > Webhooks). Alerts vanaf level 12 komen in dat kanaal. Geheim: in terraform.tfvars, niet committen."
  type        = string
  default     = null
  sensitive   = true
}
