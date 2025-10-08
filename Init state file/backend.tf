terraform {
  required_version = ">= 1.6.0"

  backend "azurerm" {
    # deliberately left empty; values come from -backend-config=backend.hcl
  }
}

provider "azurerm" {
  features {}
}
