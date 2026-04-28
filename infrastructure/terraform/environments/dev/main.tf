terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstate3a2f7662"
    container_name       = "tfstate"
    key                  = "dev.terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = local.tags
}

module "networking" {
  source              = "../../modules/networking"
  prefix              = var.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  vnet_cidr           = "10.10.0.0/16"
  aks_subnet_cidr     = "10.10.1.0/24"
  appgw_subnet_cidr   = "10.10.2.0/24"
  pe_subnet_cidr      = "10.10.3.0/24" # Dedicated subnet for private endpoint NICs
  tags                = local.tags
}

module "aks" {
  source              = "../../modules/aks"
  prefix              = var.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  aks_subnet_id       = module.networking.aks_subnet_id
  user_node_vm_size   = "Standard_D2s_v3"
  user_node_count     = 1
  tags                = local.tags
}

module "acr" {
  source                         = "../../modules/acr"
  prefix                         = var.prefix
  location                       = var.location
  resource_group_name            = azurerm_resource_group.main.name
  sku                            = "Basic"
  aks_kubelet_identity_object_id = module.aks.kubelet_identity_object_id
  vnet_id                        = module.networking.vnet_id
  pe_subnet_id                   = module.networking.pe_subnet_id
  public_network_access_enabled  = true # GitHub-hosted runners need public access to push
  tags                           = local.tags
}

module "keyvault" {
  source                         = "../../modules/keyvault"
  prefix                         = var.prefix
  location                       = var.location
  resource_group_name            = azurerm_resource_group.main.name
  vnet_id                        = module.networking.vnet_id
  pe_subnet_id                   = module.networking.pe_subnet_id
  ci_service_principal_object_id = var.ci_service_principal_object_id
  tags                           = local.tags
}

locals {
  tags = {
    environment = "dev"
    project     = "boutique"
    managed_by  = "terraform"
  }
}
