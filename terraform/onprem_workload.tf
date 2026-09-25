# A checksum-pinned Debian cloud image provides the on-prem traffic source.
# The dated URL and SHA-512 are immutable selection inputs, never a floating
# `latest` image. It is fetched by the same atomic verifier as the CE image.
locals {
  kvm_workload_image_url = "https://cloud.debian.org/images/cloud/bookworm/20260909-2596/debian-12-genericcloud-amd64-20260909-2596.qcow2"
  kvm_workload_sha512    = "08fea112563461f251f3c95a5c5cf8cb25eb60f74cec03e85a97ff91d3efef3059d35837598bbb476008f20db6d3bdc7143c5f2f2a9a6da394a0acc601fd5986"
  kvm_workload_cache     = "${local.kvm_image_cache_dir}/debian-12-genericcloud-${substr(local.kvm_workload_sha512, 0, 16)}.qcow2"
  kvm_workload_lan_mac   = "52:54:00:10:01:64"
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

  network_config = yamlencode({
    version = 2
    ethernets = merge({
      workload = {
        match    = { macaddress = local.kvm_workload_node.mac }
        set-name = "eth0"
        dhcp4    = true
        dhcp6    = false
      }
      }, var.enable_kvm_lan && var.kvm_lan != null ? {
      lan = {
        match     = { macaddress = local.kvm_workload_lan_mac }
        set-name  = "eth1"
        dhcp4     = false
        dhcp6     = false
        addresses = ["${var.kvm_lan.backend_ip}/${split("/", var.kvm_lan.sli_cidr)[1]}"]
      }
    } : {})
  })

  user_data = <<-EOF
    #cloud-config
    package_update: false
    packages: [curl, qemu-guest-agent]
%{if var.enable_kvm_lan && var.kvm_lan != null~}
    write_files:
      - path: /etc/systemd/system/mcn-lan-origin.service
        permissions: '0644'
        content: |
          [Unit]
          Description=MCN KVM LAN HTTP origin
          After=network-online.target
          Wants=network-online.target
          [Service]
          Type=simple
          ExecStart=/usr/bin/python3 -m http.server ${var.kvm_lan.backend_port} --bind ${var.kvm_lan.backend_ip} --directory /srv/mcn-lan-origin
          Restart=always
          [Install]
          WantedBy=multi-user.target
      - path: /srv/mcn-lan-origin/index.html
        permissions: '0644'
        content: |
          mcn-kvm-lan-origin
%{endif~}
    runcmd:
      - [systemctl, enable, --now, qemu-guest-agent]
%{if var.enable_kvm_lan && var.kvm_lan != null~}
      - [systemctl, daemon-reload]
      - [systemctl, enable, --now, mcn-lan-origin]
%{endif~}
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

  dynamic "network_interface" {
    for_each = var.enable_kvm_lan && var.kvm_lan != null ? [var.kvm_lan] : []
    content {
      bridge         = network_interface.value.bridge
      mac            = local.kvm_workload_lan_mac
      wait_for_lease = false
    }
  }

  disk { volume_id = libvirt_volume.workload_disk[0].id }

  # Debian 12 requires a serial device with this libvirt/QEMU machine layout.
  # It also keeps the first-boot and DHCP diagnostics available through virsh.
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.workload[0], libvirt_network.ce_bgp_net[0]]
  }
}
