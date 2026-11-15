# Deel 1: Entra ID in de tenant van de docent (geen subscription nodig)
terraform {
  required_version = ">= 1.5"

  required_providers {
    # azuread 2.x bewust vastgezet: in 3.x veranderen ID-formaten van
    # CA-policies, named locations en applicaties.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}
