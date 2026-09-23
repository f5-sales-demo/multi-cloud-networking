locals {
  kvm_site_name = var.site_name
  kvm_xc_labels = var.labels
  kvm_token_labels = {
    for key, value in local.kvm_xc_labels : key => value
    if key != "mcn-source-commit"
  }
}
