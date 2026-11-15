# Infrastructuur + IAM in de schoolsubscription (één terraform apply).
# Entra ID (tenant van de docent) blijft apart in ../entra.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # Alleen om de schoolaccounts van het team op te zoeken via hun UPN
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id # verplicht sinds azurerm 4.x
}

provider "azuread" {
  tenant_id = var.tenant_id
}
