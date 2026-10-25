variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "log_analytics_workspace_workspace_id" {
  type = string
}

variable "log_analytics_workspace_key" {
  type      = string
  sensitive = true
}

variable "frontend_vm_id" {
  type = string
}

variable "backend_vm_id" {
  type = string
}

variable "honeypot_vm_id" {
  type = string
}
