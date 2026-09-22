# Terraform owns the complete KVM BGP fabric.  FRR receives a dedicated macvlan
# address on the libvirt bridge, allowing it to establish before the legacy
# host-network router is retired.  The libvirt bridge retains 10.100.0.1 as the
# CE default gateway; 10.100.0.2 is exclusively the BGP router identity.
locals {
  kvm_frr_image = "frrouting/frr@sha256:990e83490108b686fd6df3b1cafa6bdbb2714acb00eedb9a89693946f46f45ce"

  kvm_frr_daemons = <<-EOF
    bgpd=yes
    zebra=yes
    staticd=yes
  EOF

  kvm_frr_config = <<-EOF
    frr defaults traditional
    hostname mcn-kvm-frr-router
    service integrated-vtysh-config
    !
    router bgp 65515
     bgp router-id 10.100.0.2
     no bgp ebgp-requires-policy
     maximum-paths 4
     network 198.51.100.0/24
    %{for node in values(local.kvm_ce_nodes)~}
     neighbor ${node.address} remote-as 64512
    %{endfor~}
     !
     address-family ipv4 unicast
    %{for node in values(local.kvm_ce_nodes)~}
      neighbor ${node.address} activate
    %{endfor~}
     exit-address-family
    !
    ip route 198.51.100.0/24 Null0
  EOF
}

resource "docker_image" "kvm_frr" {
  count = var.enable_kvm ? 1 : 0

  name         = local.kvm_frr_image
  keep_locally = true
}

resource "docker_network" "kvm_frr" {
  count = var.enable_kvm ? 1 : 0

  name   = "mcn-kvm-frr-net"
  driver = "macvlan"
  options = {
    parent = local.kvm_network_bridge
  }

  ipam_config {
    subnet  = "10.100.0.0/24"
    gateway = "10.100.0.1"
  }

  depends_on = [libvirt_network.ce_bgp_net]
}

resource "docker_container" "kvm_frr" {
  count = var.enable_kvm ? 1 : 0

  name       = "mcn-kvm-frr-router"
  image      = docker_image.kvm_frr[0].image_id
  privileged = true
  must_run   = true
  restart    = "unless-stopped"
  log_opts = {
    "max-file" = "3"
    "max-size" = "10m"
  }

  ulimit {
    name = "nofile"
    hard = 65536
    soft = 65536
  }

  upload {
    file        = "/etc/frr/daemons"
    content     = local.kvm_frr_daemons
    permissions = "0640"
  }

  upload {
    file        = "/etc/frr/frr.conf"
    content     = local.kvm_frr_config
    permissions = "0640"
  }

  upload {
    file        = "/etc/frr/vtysh.conf"
    content     = "service integrated-vtysh-config\n"
    permissions = "0640"
  }

  labels {
    label = "com.f5-sales-demo.owner"
    value = "terraform-mcn"
  }

  labels {
    label = "com.f5-sales-demo.component"
    value = "kvm-frr"
  }

  networks_advanced {
    name         = docker_network.kvm_frr[0].name
    ipv4_address = "10.100.0.2"
  }
}

output "kvm_bgp_fabric" {
  description = "Terraform-owned KVM FRR identity and deterministic CE peer addresses."
  value = var.enable_kvm ? {
    router_name = docker_container.kvm_frr[0].name
    router_ip   = "10.100.0.2"
    router_asn  = 65515
    ce_asn      = 64512
    ce_addresses = {
      for key, node in local.kvm_ce_nodes : key => node.address
    }
  } : null
}
