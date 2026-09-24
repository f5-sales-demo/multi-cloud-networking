terraform {
  required_version = ">= 1.8"

  required_providers {
    xcsh = {
      source  = "f5-sales-demo/xcsh"
      version = "= 11.0.1"
    }
  }
}

provider "xcsh" {}
