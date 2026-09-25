# Plan-level test focused on the BGP half of the xc-site module: two external
# peers (one per Route Server IP), CE ASN 64512 peering to RS ASN 65515. Uses
# the REAL 71-char auto-derived SLO interface name, which now validates since
# the provider relaxed the object-ref name cap from 63 to 128 chars.

mock_provider "xcsh" {}

run "bgp_two_peers" {
  command = plan

  module {
    source = "./modules/xc-site"
  }

  variables {
    site_name         = "mcn-ce-ha-eastus02"
    hostname          = "f5-xc-ce-vm-02"
    interface_name    = "ves-io-securemesh-site-v2-mcn-ce-ha-eastus01-network-f5-xc-ce-vm-01-eth0-0"
    mgmt_nic_mac      = "60:45:bd:ef:07:9f"
    ce_vm_instance_id = "d6c33249-b85d-4936-a994-f971d4b2cdb9"
    peer_ips          = ["10.0.1.20", "10.0.1.21"]
    ce_asn            = 64512
    peer_asn          = 65020
    enable_bgp        = true
  }

  assert {
    condition     = output.bgp_name == "mcn-ce-ha-eastus02-bgp"
    error_message = "BGP object name should be <site>-bgp."
  }

  assert {
    condition     = output.peer_count == 2
    error_message = "There must be exactly two external BGP peers (one per Route Server IP)."
  }

  assert {
    condition     = xcsh_bgp.this[0].namespace == "system"
    error_message = "The bgp object must be created in the system namespace."
  }
}
