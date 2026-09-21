# A checksum-pinned Debian cloud image provides the on-prem traffic source.
# The dated URL and SHA-512 are immutable selection inputs, never a floating
# `latest` image. It is fetched by the same atomic verifier as the CE image.
locals {
  kvm_workload_image_url = "https://cloud.debian.org/images/cloud/bookworm/20260909-2596/debian-12-genericcloud-amd64-20260909-2596.qcow2"
  kvm_workload_sha512    = "08fea112563461f251f3c95a5c5cf8cb25eb60f74cec03e85a97ff91d3efef3059d35837598bbb476008f20db6d3bdc7143c5f2f2a9a6da394a0acc601fd5986"
  kvm_workload_cache     = "${local.kvm_image_cache_dir}/debian-12-genericcloud-${substr(local.kvm_workload_sha512, 0, 16)}.qcow2"
}

resource "terraform_data" "kvm_workload_image_cache" {
  count = var.enable_kvm ? 1 : 0

  triggers_replace = [local.kvm_workload_image_url, local.kvm_workload_sha512]

  provisioner "local-exec" {
    command     = "../scripts/ensure-verified-kvm-image.sh --url \"$IMAGE_URL\" --digest \"sha512:$IMAGE_SHA512\" --destination \"$IMAGE_DESTINATION\""
    working_dir = path.root
    environment = {
      IMAGE_URL         = local.kvm_workload_image_url
      IMAGE_SHA512      = local.kvm_workload_sha512
      IMAGE_DESTINATION = local.kvm_workload_cache
    }
  }
}

resource "libvirt_volume" "workload_base" {
  count  = var.enable_kvm ? 1 : 0
  name   = "onprem-workload-base-${substr(local.kvm_workload_sha512, 0, 16)}.qcow2"
  pool   = libvirt_pool.kvm[0].name
  source = local.kvm_workload_cache
  format = "qcow2"

  depends_on = [terraform_data.kvm_workload_image_cache]
}

resource "libvirt_volume" "workload_disk" {
  count          = var.enable_kvm ? 1 : 0
  name           = "onprem-workload-${local.kvm_network_generation}-disk.qcow2"
  pool           = libvirt_pool.kvm[0].name
  base_volume_id = libvirt_volume.workload_base[0].id
  size           = 21474836480
  format         = "qcow2"
}

resource "libvirt_cloudinit_disk" "workload" {
  count = var.enable_kvm ? 1 : 0
  name  = "onprem-workload-${local.kvm_network_generation}-cloudinit.iso"
  pool  = libvirt_pool.kvm[0].name

  network_config = <<-EOF
    version: 2
    ethernets:
      workload:
        match:
          macaddress: "${local.kvm_workload_node.mac}"
        set-name: eth0
        dhcp4: true
        dhcp6: false
  EOF

  user_data = <<-EOF
    #cloud-config
    package_update: false
    packages: [curl, qemu-guest-agent]
    runcmd:
      - [systemctl, enable, --now, qemu-guest-agent]
      - [sh, -c, 'while true; do curl --fail --silent --show-error --max-time 15 https://httpbin.org/get >/var/log/mcn-workload-traffic.log 2>&1 || true; sleep 30; done &']
  EOF

  meta_data = <<-EOF
    instance-id: onprem-workload-${local.kvm_network_generation}
    local-hostname: onprem-workload
  EOF
}

resource "libvirt_domain" "workload" {
  count     = var.enable_kvm ? 1 : 0
  name      = "onprem-workload"
  memory    = 2048
  vcpu      = 2
  autostart = true
  cloudinit = libvirt_cloudinit_disk.workload[0].id
  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_id     = libvirt_network.ce_bgp_net[0].id
    mac            = local.kvm_workload_node.mac
    wait_for_lease = true
  }

  disk { volume_id = libvirt_volume.workload_disk[0].id }

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.workload[0], libvirt_network.ce_bgp_net[0]]
  }
}
