variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "vm_size" {
  type    = string
  default = "Standard_B2s"
}

variable "admin_username" {
  type = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "discord_webhook_url" {
  description = "Discord-webhook voor alerts vanaf level 12 (via custom-discord.py). null = geen meldingen."
  type        = string
  default     = null
  sensitive   = true
}
