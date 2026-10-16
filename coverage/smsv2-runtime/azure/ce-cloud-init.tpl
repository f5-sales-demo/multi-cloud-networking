#cloud-config
${yamlencode(merge(yamldecode(site_cloud_init), {
  write_files = concat(try(yamldecode(site_cloud_init).write_files, []), [{
    path = "/var/home/admin/.ssh/authorized_keys"
    permissions = "0600"
    owner = "admin:admin"
    content = ssh_public_key
  }])
}))}
