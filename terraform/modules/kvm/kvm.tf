# KVM / libvirt Network for On-Prem Customer Edge nodes.
#
# The CE addresses are routing identities: FRR peers with them and SMSv2 renders
# one peer configuration across the site.  Do not derive them from DHCP lease
# ordering; a restart must not silently leave FRR peering with former tenants.
locals {
  # The demo host has capacity for one production-sized CE plus its workload;
  # a three-node under-provisioned topology cannot establish a valid showcase.
  kvm_ce_nodes = {
    "01" = { address = "10.100.0.11", mac = "52:54:00:10:00:11" }
  }
  kvm_workload_node   = { address = "10.100.0.100", mac = "52:54:00:10:00:64" }
  kvm_network_hosts   = merge(local.kvm_ce_nodes, { workload = local.kvm_workload_node })
  kvm_image_cache_dir = pathexpand("~/.cache/multi-cloud-networking/kvm")
  kvm_pool_name       = "mcn-kvm-showcase"

  kvm_network_generation = substr(sha256(jsonencode(local.kvm_network_hosts)), 0, 8)
  kvm_network_name       = "ce-bgp-net-${local.kvm_network_generation}"
  # Linux bridge device names are limited to 15 bytes.
  kvm_network_bridge       = "vbgp-${local.kvm_network_generation}"
  kvm_bootstrap_generation = var.enable_kvm ? nonsensitive(substr(sha256(xcsh_token.kvm[0].uid), 0, 8)) : "disabled"
  kvm_enabled_nodes        = var.enable_kvm ? local.kvm_ce_nodes : {}
}
# Provider refresh cannot reconcile dnsmasq host entries after a libvirt-side
# reservation drift.  A changed declarative identity generation must therefore
# replace the network, which transitively tears down and recreates dependent CE
# domains and the FRR fabric in Terraform order.
resource "terraform_data" "kvm_network_identity" {
  count = var.enable_kvm ? 1 : 0

  input = sha256(jsonencode(local.kvm_network_hosts))
}

# The Sales Demo tenant issues the currently supported KVM CE appliance as a
# signed image URL. Never substitute a generic cloud OS: it has no VPM runtime.
data "xcsh_site_image" "kvm" {
  count = var.enable_kvm ? 1 : 0

  site_name = xcsh_securemesh_site_v2.onprem_kvm[0].name
}

data "xcsh_site_cloud_init" "kvm" {
  count = var.enable_kvm ? 1 : 0

  provider_ref              = "kvm"
  site_name                 = xcsh_securemesh_site_v2.onprem_kvm[0].name
  enable_management_network = false
}

resource "libvirt_pool" "kvm" {
  count = var.enable_kvm ? 1 : 0
  name  = local.kvm_pool_name
  type  = "dir"
  target { path = "/var/lib/libvirt/images/${local.kvm_pool_name}" }
}

resource "terraform_data" "kvm_ce_image_cache" {
  count            = var.enable_kvm ? 1 : 0
  triggers_replace = [data.xcsh_site_image.kvm[0].image_download_url, data.xcsh_site_image.kvm[0].image_md5_sum]
  provisioner "local-exec" {
    command     = "../scripts/ensure-verified-kvm-image.sh --url \"$IMAGE_URL\" --digest \"md5:$IMAGE_MD5\" --destination \"$IMAGE_DESTINATION\""
    working_dir = path.root
    environment = {
      IMAGE_URL         = data.xcsh_site_image.kvm[0].image_download_url
      IMAGE_MD5         = data.xcsh_site_image.kvm[0].image_md5_sum
      IMAGE_DESTINATION = "${local.kvm_image_cache_dir}/f5xc-${data.xcsh_site_image.kvm[0].image_md5_sum}.qcow2"
    }
  }
}
resource "libvirt_network" "ce_bgp_net" {
  count = var.enable_kvm ? 1 : 0

  name      = local.kvm_network_name
  mode      = "nat"
  domain    = "ce.local"
  addresses = ["10.100.0.0/24"]

  bridge = local.kvm_network_bridge

  autostart = true

  dhcp {
    enabled = true
  }

  dnsmasq_options {
    dynamic "options" {
      for_each = local.kvm_network_hosts
      content {
        option_name  = "dhcp-host"
        option_value = "${options.value.mac},${options.value.address}"
      }
    }
  }

  dns {
    enabled = true
  }

  lifecycle {
    replace_triggered_by = [terraform_data.kvm_network_identity[0]]
  }
}

# Base cloud OS image volume in libvirt
resource "libvirt_volume" "base_cloud" {
  count = var.enable_kvm ? 1 : 0

  name       = "f5xc-kvm-ce-${data.xcsh_site_image.kvm[0].image_md5_sum}.qcow2"
  pool       = libvirt_pool.kvm[0].name
  source     = "${local.kvm_image_cache_dir}/f5xc-${data.xcsh_site_image.kvm[0].image_md5_sum}.qcow2"
  format     = "qcow2"
  depends_on = [terraform_data.kvm_ce_image_cache]
}

# Per-CE root overlay disks
resource "libvirt_volume" "ce_disk" {
  for_each       = local.kvm_enabled_nodes
  name           = "onprem-ce-${each.key}-${local.kvm_network_generation}-${local.kvm_bootstrap_generation}-disk.qcow2"
  pool           = libvirt_pool.kvm[0].name
  base_volume_id = libvirt_volume.base_cloud[0].id
  size           = 85899345920
  format         = "qcow2"
}

# Cloud-Init ISO seed disks per CE node
resource "libvirt_cloudinit_disk" "ce_cloudinit" {
  for_each = local.kvm_enabled_nodes
  name     = "onprem-ce-${each.key}-${local.kvm_network_generation}-${local.kvm_bootstrap_generation}-cloudinit.iso"
  pool     = libvirt_pool.kvm[0].name
  # The provider returns the modern /etc/vpm/user_data template. It has the
  # lowercase placeholder exactly once; this CE receives its own type-1 JWT.
  user_data = replace(
    data.xcsh_site_cloud_init.kvm[0].cloud_init_config,
    "{{ .token }}",
    xcsh_token.kvm[0].uid,
  )

  meta_data = <<-EOF
    instance-id: onprem-ce-${each.key}-${local.kvm_bootstrap_generation}
    local-hostname: onprem-ce-${each.key}
  EOF

}

# Declarative KVM Virtual Machines managed by Terraform
resource "libvirt_domain" "ce_node" {
  for_each  = local.kvm_enabled_nodes
  name      = "onprem-ce-${each.key}"
  memory    = 32768
  vcpu      = 8
  autostart = true

  cloudinit = libvirt_cloudinit_disk.ce_cloudinit[each.key].id

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_id     = libvirt_network.ce_bgp_net[0].id
    mac            = each.value.mac
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.ce_disk[each.key].id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }

  # A changed seed ISO is not consumed by an already-running CE.  Replace the
  # domain so cloud-init applies the declared MAC and static routing identity
  # on first boot rather than leaving an old DHCP lease in the BGP fabric.
  lifecycle {
    replace_triggered_by = [
      libvirt_cloudinit_disk.ce_cloudinit[each.key],
      libvirt_network.ce_bgp_net[0],
    ]
  }
}
