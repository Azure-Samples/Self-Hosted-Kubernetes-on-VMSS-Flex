terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {
    # Azure subscription policies often auto-deploy NRMS NSGs into resource
    # groups containing VMs. Without this flag, `terraform destroy` refuses
    # to delete the resource group because of those foreign resources.
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
