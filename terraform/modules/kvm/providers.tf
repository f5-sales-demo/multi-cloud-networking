terraform {
  required_version = ">= 1.8"

  required_providers {
    xcsh = {
      source  = "f5-sales-demo/xcsh"
      version = "= 11.3.0"
    }
    libvirt = { source = "dmacvicar/libvirt", version = "= 0.8.3" }
    docker  = { source = "kreuzwerker/docker", version = "~> 3.0" }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

provider "xcsh" {
  api_url = "https://${var.expected_xc_tenant}.console.ves.volterra.io"
}
provider "libvirt" {}
provider "docker" {}
