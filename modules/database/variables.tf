variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "vnet_id" {
  type = string
}

variable "mysql_admin_username" {
  type = string
}

variable "mysql_admin_password" {
  type      = string
  sensitive = true
}
