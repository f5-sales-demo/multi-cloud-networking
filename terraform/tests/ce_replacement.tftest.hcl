# Plan-level test for the CE-replacement coupling that closes #674.
#
# Replacing a CE VM used to leave the XC site object — and with it the
# registration bound to the destroyed node — untouched. The stale registration
# holds the control plane's unique (tenant, cluster_name, hostname) index, so the
# replacement node's own registration can never be created and the site wedges,
# while `terraform plan` reports "No changes" because nothing in the graph ever
# referenced the node's instance identity.
#
# modules/xc-site now takes that identity as ce_vm_instance_id and parks it in
# terraform_data.ce_vm, which the site resource names in replace_triggered_by.
#
# WHAT THESE RUNS CAN AND CANNOT SEE. A lifecycle meta-argument is not part of a
# plan, so no assertion here can observe replace_triggered_by itself. What is
# assertable is the value it keys on: that the module parks the instance id it
# was handed, and that the root hands it the VM's `virtual_machine_id` (the
# 128-bit id Azure regenerates for a replacement VM) rather than the ARM resource
# `id`, which is derived from the VM name and is therefore IDENTICAL before and
# after a replacement — wiring that would silently disable the whole mechanism.
# The discriminating check for the meta-argument is a live single-CE replacement,
# recorded on the pull request.

mock_provider "xcsh" {}

# The module parks exactly the instance id it is handed, and exposes it so an
# operator can compare it against the registration's own infra.instance_id.
run "site_is_keyed_to_the_ce_vm_instance_id" {
  command = apply

  module {
    source = "./modules/xc-site"
  }

  variables {
    site_name         = "mcn-ce-ha-eastus01"
    hostname          = "f5-xc-ce-vm-01"
    interface_name    = "ves-io-securemesh-site-v2-mcn-ce-ha-eastus01-network-f5-xc-ce-vm-01-eth0-0"
    mgmt_nic_mac      = "7c:1e:52:18:c1:77"
    ce_vm_instance_id = "89e6c538-6bc2-4c2c-a37e-d6149c1708ce"
    peer_ips          = ["10.0.1.20", "10.0.1.21"]
    ce_asn            = 64512
    peer_asn          = 65020
    # Not under test here; bgp.tftest.hcl covers the peer wiring.
    enable_bgp           = false
    approve_registration = false
  }

  assert {
    condition     = terraform_data.ce_vm.input == "89e6c538-6bc2-4c2c-a37e-d6149c1708ce"
    error_message = "terraform_data.ce_vm must park the CE VM instance id the site's replace_triggered_by keys on."
  }

  assert {
    condition     = output.bound_vm_instance_id == "89e6c538-6bc2-4c2c-a37e-d6149c1708ce"
    error_message = "bound_vm_instance_id must report the instance the site object is bound to."
  }

  # The site keeps its stable identity: the coupling replaces the object, it does
  # not rename it. A renamed site would orphan the bgp object and the LB
  # advertise rule, which both reference it by name.
  assert {
    condition     = one(xcsh_securemesh_site_v2.this).name == "mcn-ce-ha-eastus01"
    error_message = "The instance-id coupling must not change the site name."
  }
}

# A different node yields a different key. This is the whole point: two nodes
# that differ only by instance id must not share a trigger value.
run "a_different_instance_yields_a_different_key" {
  command = apply

  module {
    source = "./modules/xc-site"
  }

  variables {
    site_name            = "mcn-ce-ha-eastus01"
    hostname             = "f5-xc-ce-vm-01"
    interface_name       = "ves-io-securemesh-site-v2-mcn-ce-ha-eastus01-network-f5-xc-ce-vm-01-eth0-0"
    mgmt_nic_mac         = "7c:1e:52:18:c1:77"
    ce_vm_instance_id    = "81ab781d-36e0-42b0-aa3b-f1ba2c935e24"
    peer_ips             = ["10.0.1.20", "10.0.1.21"]
    ce_asn               = 64512
    peer_asn             = 65515
    enable_bgp           = false
    approve_registration = false
  }

  assert {
    condition     = terraform_data.ce_vm.input == "81ab781d-36e0-42b0-aa3b-f1ba2c935e24"
    error_message = "The parked key must track the instance id, not the site or host name."
  }
}
