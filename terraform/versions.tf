terraform {
  # The automated showcase lifecycle and its test harness execute this exact
  # version on the authoritative Ubuntu host.
  required_version = "= 1.16.3"

  required_providers {
    xcsh = {
      source  = "f5-sales-demo/xcsh"
      version = "= 11.0.2"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.12.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}
