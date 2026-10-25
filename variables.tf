variable "resource_group_name" {
  type    = string
  default = "rg-zerotrust"
}

variable "location" {
  type    = string
  default = "West Europe"
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
  default = "Standard_B2s"
}
