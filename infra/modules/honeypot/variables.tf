variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "admin_username" {
  type = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "vm_size" {
  type = string
}

variable "wazuh_manager_ip" {
  type = string
}

variable "nsg_name" {
  description = "NSG van het honeypot-subnet (de internetblokkade wordt hier na de installatie toegevoegd)."
  type        = string
}
