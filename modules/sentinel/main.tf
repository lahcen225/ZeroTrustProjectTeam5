resource "azurerm_sentinel_log_analytics_workspace_onboarding" "main" {
  workspace_id                 = var.log_analytics_workspace_id
  customer_managed_key_enabled = false
}

# --- Alert: Honeypot SSH Access ---
resource "azurerm_sentinel_alert_rule_scheduled" "honeypot_access" {
  name                       = "Honeypot-Access-Detected"
  display_name               = "Honeypot Access Detected - ALARM"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.main.workspace_id
  severity                   = "High"
  query_frequency            = "PT5M"
  query_period               = "PT5M"

  query = <<-QUERY
    Syslog
    | where Computer == "vm-honeypot"
    | where SyslogMessage contains "Accepted password" or SyslogMessage contains "session opened"
    | project TimeGenerated, Computer, SyslogMessage
  QUERY

  trigger_operator  = "GreaterThan"
  trigger_threshold = 0

  incident_configuration {
    create_incident = true
    grouping {
      enabled = true
    }
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.main]
}

# --- Alert: Honeypot Storage Access ---
resource "azurerm_sentinel_alert_rule_scheduled" "honeypot_storage_access" {
  name                       = "Honeypot-Storage-Access"
  display_name               = "Honey Token Storage Accessed - ALARM"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.main.workspace_id
  severity                   = "High"
  query_frequency            = "PT5M"
  query_period               = "PT5M"

  query = <<-QUERY
    StorageBlobLogs
    | where AccountName startswith "sthoney"
    | where OperationName in ("GetBlob", "ListBlobs", "PutBlob")
    | project TimeGenerated, AccountName, OperationName, CallerIpAddress, UserAgentHeader
  QUERY

  trigger_operator  = "GreaterThan"
  trigger_threshold = 0

  incident_configuration {
    create_incident = true
    grouping {
      enabled = true
    }
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.main]
}

# --- Alert: Decoy Account Login ---
resource "azurerm_sentinel_alert_rule_scheduled" "decoy_account" {
  name                       = "Decoy-Account-Login"
  display_name               = "Decoy Account Login Detected - ALARM"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.main.workspace_id
  severity                   = "High"
  query_frequency            = "PT5M"
  query_period               = "PT5M"

  query = <<-QUERY
    Syslog
    | where SyslogMessage contains "decoyadmin"
    | where SyslogMessage contains "session opened" or SyslogMessage contains "Accepted"
    | project TimeGenerated, Computer, SyslogMessage
  QUERY

  trigger_operator  = "GreaterThan"
  trigger_threshold = 0

  incident_configuration {
    create_incident = true
    grouping {
      enabled = true
    }
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.main]
}

# --- VM Monitoring Extensions ---
resource "azurerm_virtual_machine_extension" "frontend_monitoring" {
  name                 = "OmsAgentForLinux"
  virtual_machine_id   = var.frontend_vm_id
  publisher            = "Microsoft.EnterpriseCloud.Monitoring"
  type                 = "OmsAgentForLinux"
  type_handler_version = "1.19"

  settings = jsonencode({
    workspaceId = var.log_analytics_workspace_workspace_id
  })

  protected_settings = jsonencode({
    workspaceKey = var.log_analytics_workspace_key
  })
}

resource "azurerm_virtual_machine_extension" "backend_monitoring" {
  name                 = "OmsAgentForLinux"
  virtual_machine_id   = var.backend_vm_id
  publisher            = "Microsoft.EnterpriseCloud.Monitoring"
  type                 = "OmsAgentForLinux"
  type_handler_version = "1.19"

  settings = jsonencode({
    workspaceId = var.log_analytics_workspace_workspace_id
  })

  protected_settings = jsonencode({
    workspaceKey = var.log_analytics_workspace_key
  })
}

resource "azurerm_virtual_machine_extension" "honeypot_monitoring" {
  name                 = "OmsAgentForLinux"
  virtual_machine_id   = var.honeypot_vm_id
  publisher            = "Microsoft.EnterpriseCloud.Monitoring"
  type                 = "OmsAgentForLinux"
  type_handler_version = "1.19"

  settings = jsonencode({
    workspaceId = var.log_analytics_workspace_workspace_id
  })

  protected_settings = jsonencode({
    workspaceKey = var.log_analytics_workspace_key
  })
}
