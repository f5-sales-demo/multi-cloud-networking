variable "enable_showcase_origin" {
  description = "Deploy a disposable HTTP origin for repeatable full-showcase traffic verification."
  type        = bool
  default     = false
}
module "showcase_origin" {
  count               = var.enable_azure && var.enable_showcase_origin ? 1 : 0
  source              = "./modules/client-vm"
  name                = "${var.component}-origin${local.deployment_name_suffix}"
  resource_group_name = module.azure_hub[0].resource_group_name
  location            = module.azure_hub[0].location
  subnet_id           = module.azure_hub[0].management_subnet_id
  admin_username      = var.admin_username
  ssh_public_key      = local.ssh_public_key
  serve_http          = true
  tags                = local.tags
  custom_data = base64encode(<<-EOF
    #cloud-config
    write_files:
      - path: /srv/mcn-origin/index.html
        permissions: '0644'
        content: |
          mcn-showcase-origin
      - path: /etc/systemd/system/mcn-origin.service
        permissions: '0644'
        content: |
          [Unit]
          Description=Ephemeral MCN showcase HTTP origin
          After=network-online.target
          [Service]
          ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0 --directory /srv/mcn-origin
          Restart=always
          [Install]
          WantedBy=multi-user.target
    runcmd:
      - [systemctl, daemon-reload]
      - [systemctl, enable, --now, mcn-origin]
    EOF
  )
}
locals {
  selected_origin_ip = var.enable_azure && var.enable_showcase_origin ? module.showcase_origin[0].public_ip : var.origin_ip
}
