terraform {
  required_version = ">= 1.8"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    xcsh = {
      source  = "f5-sales-demo/xcsh"
      version = "= 12.0.3"
    }
  }
}
