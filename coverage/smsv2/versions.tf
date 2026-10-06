terraform {
  required_version = ">= 1.8"

  required_providers {
    xcsh = {
      source  = "f5-sales-demo/xcsh"
      version = "= 15.0.3"
    }
  }
}

provider "xcsh" {}
