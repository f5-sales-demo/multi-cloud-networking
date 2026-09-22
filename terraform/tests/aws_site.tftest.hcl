# Test suite for AWS Customer Edge site, VPC, EC2 instances, and XC resources.

mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "libvirt" {}
mock_provider "docker" {}

override_resource {
  override_during = plan
  target          = aws_network_interface.slo[0]
  values          = { mac_address = "02:00:00:00:00:01" }
}
override_resource {
  override_during = plan
  target          = aws_network_interface.slo[1]
  values          = { mac_address = "02:00:00:00:00:02" }
}
override_resource {
  override_during = plan
  target          = aws_network_interface.slo[2]
  values          = { mac_address = "02:00:00:00:00:03" }
}
override_resource {
  override_during = plan
  target          = aws_network_interface.sli[0]
  values          = { mac_address = "02:00:00:00:01:01" }
}
override_resource {
  override_during = plan
  target          = aws_network_interface.sli[1]
  values          = { mac_address = "02:00:00:00:01:02" }
}
override_resource {
  override_during = plan
  target          = aws_network_interface.sli[2]
  values          = { mac_address = "02:00:00:00:01:03" }
}

override_resource {
  override_during = plan
  target          = xcsh_token.aws["01"]
  values          = { uid = "test-site-token-01" }
}

override_resource {
  override_during = plan
  target          = xcsh_token.aws["02"]
  values          = { uid = "test-site-token-02" }
}

override_resource {
  override_during = plan
  target          = xcsh_token.aws["03"]
  values          = { uid = "test-site-token-03" }
}

override_data {
  override_during = plan
  target          = data.xcsh_site_cloud_init.aws["01"]
  values          = { cloud_init_config = "#cloud-config\nwrite_files:\n  - path: /etc/vpm/user_data\n    content: |\n      token: {{ .token }}\n" }
}

override_data {
  override_during = plan
  target          = data.xcsh_site_cloud_init.aws["02"]
  values          = { cloud_init_config = "#cloud-config\nwrite_files:\n  - path: /etc/vpm/user_data\n    content: |\n      token: {{ .token }}\n" }
}

override_data {
  override_during = plan
  target          = data.xcsh_site_cloud_init.aws["03"]
  values          = { cloud_init_config = "#cloud-config\nwrite_files:\n  - path: /etc/vpm/user_data\n    content: |\n      token: {{ .token }}\n" }
}

override_data {
  target = data.xcsh_site_registration.aws["01"]
  values = { found = false }
}

override_data {
  target = data.xcsh_site_registration.aws["02"]
  values = { found = false }
}

override_data {
  target = data.xcsh_site_registration.aws["03"]
  values = { found = false }
}

variables {
  site_prefix                   = null
  lb_name                       = null
  origin_pool_name              = null
  route_server_name             = null
  bastion_name                  = null
  client_vm_name                = null
  region_short                  = null
  resource_group_name           = null
  lb_domain                     = "mcn-ce-ha.f5-sales-demo.com"
  aws_lb_domain                 = "aws.mcn-ce-ha.f5-sales-demo.com"
  origin_ip                     = "203.0.113.10"
  deployer                      = "tester"
  ssh_public_key                = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  aws_ssh_public_key            = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAwsSpecificKeyMaterialOnlyForTests aws-plan-test-only"
  xc_app_namespace              = "multi-cloud-networking"
  aws_ce_ami_id                 = "ami-0123456789abcdef0"
  aws_workload_ami_id           = "ami-0123456789abcdef0"
  enable_azure                  = false
  enable_kvm                    = false
  enable_aws                    = true
  enable_aws_tgw_connect        = false
  aws_site_configuration_phase  = "configured"
  aws_smsv2_device_mapping_file = "tests/fixtures/aws-device-mapping.valid.json"
}

run "aws_site_and_resources" {
  command = plan

  variables {
    aws_ce_count = 3
  }

  assert {
    condition     = length(data.azuread_client_config.current) == 0 && length(data.azuread_user.current) == 0
    error_message = "An explicit deployer must keep AWS-only planning from reading Azure AD."
  }

  assert {
    condition     = output.aws_lb_domain == "aws.mcn-ce-ha.f5-sales-demo.com"
    error_message = "AWS HTTP Load Balancer domain should be aws.mcn-ce-ha.f5-sales-demo.com."
  }

  # The complete AWS graph, not just the three Secure Mesh sites, must use the
  # immutable SMSv2 generation.  Otherwise a clean recovery can collide with
  # stale component-scoped IAM, NLB, or F5 objects before it reaches bootstrap.
  assert {
    condition = (
      output.aws_loadbalancer_name == "mcn-ce-ha-smsv2-aws-lb" &&
      output.aws_origin_pool_name == "mcn-ce-ha-smsv2-aws-pool" &&
      aws_key_pair.ce[0].key_name == "mcn-ce-ha-smsv2-aws-ce-key" &&
      aws_iam_role.ce[0].name == "mcn-ce-ha-smsv2-aws-ce-role" &&
      aws_iam_instance_profile.ce[0].name == "mcn-ce-ha-smsv2-aws-ce-profile" &&
      aws_iam_role.workload[0].name == "mcn-ce-ha-smsv2-aws-workload-ssm" &&
      aws_iam_instance_profile.workload[0].name == "mcn-ce-ha-smsv2-aws-workload-ssm" &&
      xcsh_virtual_site.aws[0].name == "mcn-ce-ha-smsv2-aws-vsite"
    )
    error_message = "Every singleton AWS/F5 object must use the immutable SMSv2 generation instead of a collision-prone component-only name."
  }

  assert {
    condition     = output.aws_vip == "10.151.1.10"
    error_message = "AWS VIP should default to host 10 of the workload subnet reserved for the internal NLB."
  }

  assert {
    condition     = aws_instance.ce[0].ami == "ami-0123456789abcdef0"
    error_message = "AWS CE instances must use the explicitly approved AMI, not a dynamic discovery result."
  }

  assert {
    condition     = aws_instance.workload[0].ami == var.aws_workload_ami_id
    error_message = "AWS workload instances must use the explicitly approved AMI, not a dynamic discovery result."
  }

  assert {
    condition     = aws_instance.ce[0].root_block_device[0].volume_size == 100
    error_message = "AWS CE instances must plan a 100-GiB root volume."
  }

  assert {
    condition     = aws_key_pair.ce[0].public_key == var.aws_ssh_public_key
    error_message = "AWS must support an AWS-only operator key without changing Azure VM access."
  }

  assert {
    condition     = length(xcsh_securemesh_site_v2.aws) == 3 && length(data.xcsh_site_cloud_init.aws) == 3 && length(xcsh_token.aws) == 3
    error_message = "AWS must plan three independent sites and one site-scoped bootstrap per site."
  }

  assert {
    condition = alltrue([
      for key, token in xcsh_token.aws : token.type == 1 && token.site_name == local.aws_sites[key].name
    ])
    error_message = "Every AWS registration credential must be a JWT token bound to its exact Secure Mesh Site v2 name."
  }

  assert {
    condition = length(data.xcsh_site_registration.aws) == 3 && length(xcsh_registration_approval.aws) == 0

    error_message = "AWS must look up all three runtime registrations and defer approval until they are found."
  }

  assert {
    condition = alltrue([
      for bootstrap in values(data.xcsh_site_cloud_init.aws) : bootstrap.provider_ref == "aws"
    ])
    error_message = "AWS site cloud-init issuance must use the lowercase provider identifier expected by the live API."
  }

  assert {
    condition = alltrue([
      for key, bootstrap in data.xcsh_site_cloud_init.aws :
      bootstrap.site_name == local.aws_active_sites[key].name
    ])
    error_message = "Every AWS CE must retrieve the cloud-init template for its exact SMSv2 site."
  }

  assert {
    condition = alltrue([
      for site in values(xcsh_securemesh_site_v2.aws) :
      site.aws.not_managed.node_list[0].interface_list[0].ethernet_interface.device == "ens5" &&
      site.aws.not_managed.node_list[0].interface_list[1].ethernet_interface.device == "ens6"
    ])
    error_message = "Every AWS SMSv2 node must use the supplied guest device names, correlated with its ENI MACs."
  }

  assert {
    condition = toset([
      for site in values(xcsh_securemesh_site_v2.aws) : site.name
    ]) == toset(["mcn-ce-ha-smsv2-aws-ap-northeast-1-01", "mcn-ce-ha-smsv2-aws-ap-northeast-1-02", "mcn-ce-ha-smsv2-aws-ap-northeast-1-03"])
    error_message = "AWS must use the released SMSv2 identity generation for all independent site names."
  }

  assert {
    condition     = length(aws_vpc.workload) == 1 && length(aws_instance.workload) == 1 && length(aws_security_group.workload) == 1
    error_message = "AWS must plan a dedicated workload VPC and SSM client."
  }

  assert {
    condition     = xcsh_origin_pool.aws[0].origin_servers[0].public_name.dns_name == var.aws_origin_dns_name
    error_message = "AWS traffic must use the declared DNS origin rather than an unmanaged instance address."
  }
}

run "aws_requires_an_explicit_ami_before_any_instance_plan" {
  command = plan

  variables {
    aws_ce_ami_id = null
  }

  expect_failures = [aws_instance.ce]
}

run "aws_runtime_readiness_cannot_be_shortened" {
  command = plan

  variables {
    aws_runtime_convergence_timeout_seconds = 600
  }

  expect_failures = [var.aws_runtime_convergence_timeout_seconds]
}

run "aws_bootstrap_stage_uses_distinct_discovery_sites" {
  command = plan

  variables {
    aws_site_configuration_phase  = "bootstrap"
    aws_smsv2_device_mapping_file = null
    smsv2_site_generation         = "smsv2-current"
  }

  assert {
    condition     = length(xcsh_token.aws) == 3 && alltrue([for site in values(xcsh_securemesh_site_v2.aws) : endswith(site.name, "-bootstrap")])
    error_message = "Bootstrap must create all three distinct disposable discovery sites."
  }

  assert {
    condition     = alltrue([for site in values(xcsh_securemesh_site_v2.aws) : length(site.aws.not_managed.node_list) == 0])
    error_message = "Bootstrap discovery sites must not guess configured node or device identities."
  }

  assert {
    condition = (
      length(distinct([for token in values(xcsh_token.aws) : token.name])) == 3 &&
      alltrue([for token in values(xcsh_token.aws) :
        length(token.name) >= 1 &&
        length(token.name) <= 63 &&
        can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", token.name))
      ])
    )
    error_message = "Bootstrap registration-token names must remain unique DNS-1035 labels within the XC API 63-character limit."
  }
}

run "aws_disabled_plans_no_aws_resources" {
  command = plan

  variables {
    enable_aws             = false
    enable_aws_tgw_connect = false
  }

  assert {
    condition     = length(aws_vpc.aws) == 0
    error_message = "With enable_aws = false, no AWS VPC should be created."
  }

  assert {
    condition     = length(aws_instance.ce) == 0
    error_message = "With enable_aws = false, no AWS EC2 instances should be created."
  }

  assert {
    condition     = length(xcsh_securemesh_site_v2.aws) == 0 && length(aws_vpc.workload) == 0
    error_message = "With enable_aws = false, no AWS SecureMesh site should be created."
  }

  assert {
    condition     = length(xcsh_http_loadbalancer.aws) == 0
    error_message = "With enable_aws = false, no AWS HTTP load balancer should be created."
  }

  assert {
    condition     = output.aws_vpc_id == null
    error_message = "With enable_aws = false, aws_vpc_id output must be null."
  }
}

run "aws_device_discovery_must_be_supplied" {
  command = plan
  variables {
    aws_smsv2_device_mapping_file = null
  }
  expect_failures = [var.aws_smsv2_device_mapping_file]
}

run "aws_vip_selects_explicitly_labelled_sites" {
  command = plan
  assert {
    condition = alltrue([
      for advertisement in xcsh_http_loadbalancer.aws[0].advertise_custom.advertise_where :
      advertisement.site.network == "SITE_NETWORK_INSIDE" && advertisement.site.ip == null
    ])
    error_message = "Every exact SMSv2 site must use its supported automatic inside listener address."
  }
  assert {
    condition = alltrue([for site in values(xcsh_securemesh_site_v2.aws) :
      lookup(site.labels, "mcn-topology", "") == "${local.site_prefix}-aws"
    ]) && toset(xcsh_virtual_site.aws[0].site_selector.expressions) == toset(["mcn-topology in (${local.site_prefix}-aws)"])
    error_message = "The virtual site must select an explicit topology label present on every AWS SMSv2 site."
  }

  assert {
    condition     = xcsh_http_loadbalancer.aws[0].http.dns_volterra_managed == null
    error_message = "The AWS showcase HTTP LB must remain a non-delegated Sales Demo domain."
  }
}
