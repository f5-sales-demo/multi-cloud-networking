# The Site Console delegates Basic Auth to VPM on the CE host. The XC site's
# admin_user_credentials field is inert for the built-in admin user, so each VM
# must rotate that host account through an encrypted Azure VM extension.

mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "libvirt" {}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = {
      result = "<GENERATED_SITE_CONSOLE_PASSWORD>"
    }
  }
}

variables {
  enable_azure           = true
  enable_kvm             = false
  lb_domain              = "mcn.example.com"
  origin_ip              = "198.51.100.10"
  enable_aws             = false
  enable_aws_tgw_connect = false
}

run "site_console_password_is_applied_on_the_ce_host" {
  command = plan

  override_resource {
    target          = random_password.site_console_admin["eastus01"]
    override_during = plan
    values = {
      result = "<GENERATED_SITE_CONSOLE_PASSWORD>"
    }
  }

  variables {
    ce_count       = 1
    deployer       = "tester"
    enable_bastion = false
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  }

  assert {
    condition     = length(azurerm_virtual_machine_extension.site_console_password) == 1
    error_message = "Every CE must receive one Site Console password-rotation extension."
  }

  assert {
    condition = (
      azurerm_virtual_machine_extension.site_console_password["eastus01"].publisher == "Microsoft.Azure.Extensions" &&
      azurerm_virtual_machine_extension.site_console_password["eastus01"].type == "CustomScript" &&
      azurerm_virtual_machine_extension.site_console_password["eastus01"].auto_upgrade_minor_version
    )
    error_message = "Password rotation must use the latest minor Azure Linux Custom Script extension."
  }

  assert {
    condition = (
      strcontains(
        base64decode(jsondecode(azurerm_virtual_machine_extension.site_console_password["eastus01"].protected_settings).script),
        "chpasswd"
      ) &&
      strcontains(
        base64decode(jsondecode(azurerm_virtual_machine_extension.site_console_password["eastus01"].protected_settings).script),
        base64encode("<GENERATED_SITE_CONSOLE_PASSWORD>")
      )
    )
    error_message = "The encrypted inline script must apply the generated password with chpasswd."
  }
}
