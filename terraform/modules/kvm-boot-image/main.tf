# Store a verified creation-time artifact until the owning CE generation changes.
# The current site-image query may change after enrollment; it is not a disk replacement request.
variable "site_generation" {
  type = string
}
variable "artifact" {
  type      = object({ image_download_url = string, image_md5_sum = string })
  sensitive = true
}
resource "terraform_data" "receipt" {
  triggers_replace = var.site_generation
  store {
    input     = var.artifact
    version   = var.site_generation
    sensitive = true
    replace   = true
  }
}
output "artifact" {
  value     = terraform_data.receipt.store.sensitive_output
  sensitive = true
}
