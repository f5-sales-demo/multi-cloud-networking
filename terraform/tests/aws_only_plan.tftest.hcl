# A normal saved-plan workflow, not Terraform targeting: AWS preflight must be
# able to inspect a graph with no Azure or AzAPI resources at all.
mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "libvirt" {}
mock_provider "docker" {}

variables {
  lb_domain              = "mcn-ce-ha.f5-sales-demo.com"
  aws_lb_domain          = "aws.mcn-ce-ha.f5-sales-demo.com"
  origin_ip              = "203.0.113.10"
  deployer               = "tester"
  ssh_public_key         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  aws_ssh_public_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAwsSpecificKeyMaterialOnlyForTests aws-plan-test-only"
  xc_app_namespace       = "multi-cloud-networking"
  aws_ce_ami_id          = "ami-0123456789abcdef0"
  aws_workload_ami_id    = "ami-0123456789abcdef0"
  enable_azure           = false
  enable_aws             = true
  enable_aws_tgw_connect = false
  enable_kvm             = false
  enable_bgp             = false
}

run "aws_only_plan_has_no_azure_or_us_xc_objects" {
  command = plan

  assert {
    condition     = length(module.azure_hub) == 0 && length(module.ce_node) == 0 && length(module.client_vm) == 0
    error_message = "AWS-only plans must omit all Azure US modules."
  }

  assert {
    condition     = length(module.azure_hub_ca) == 0 && length(module.ce_node_ca) == 0 && length(module.client_vm_ca) == 0
    error_message = "AWS-only plans must omit all Canadian Azure modules."
  }

  assert {
    condition     = length(azapi_resource_action.f5xc_customer_edge_marketplace_agreement) == 0 && length(azurerm_lb.azure_ilb) == 0 && length(azurerm_lb.ca_ilb) == 0
    error_message = "AWS-only plans must omit Marketplace and ILB operations."
  }

  assert {
    condition     = length(libvirt_network.ce_bgp_net) == 0 && length(libvirt_volume.base_cloud) == 0 && length(libvirt_domain.ce_node) == 0 && length(data.xcsh_site_image.kvm) == 0
    error_message = "AWS-only plans must not initialize KVM resources or issue a KVM appliance-image lookup."
  }

  assert {
    condition     = length(xcsh_securemesh_site_v2.aws) == 3 && length(aws_instance.ce) == 3 && output.loadbalancer_name == null
    error_message = "AWS-only plans must retain the three-site AWS graph while omitting the Azure HTTP load balancer."
  }
}
