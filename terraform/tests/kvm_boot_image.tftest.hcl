variables {
  site_generation = "generation-one"
  artifact        = { image_download_url = "https://example.com/bootstrap.qcow2", image_md5_sum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
}
run "captures_verified_bootstrap_artifact" {
  command = apply
  module { source = "./modules/kvm-boot-image" }
  assert {
    condition     = output.artifact.image_md5_sum == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    error_message = "Bootstrap receipt must capture the verified artifact."
  }
}
run "online_current_image_change_does_not_rewrite_boot_receipt" {
  command = apply
  module { source = "./modules/kvm-boot-image" }
  variables {
    artifact = { image_download_url = "https://example.com/online.qcow2", image_md5_sum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  }
  assert {
    condition     = output.artifact.image_md5_sum == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    error_message = "A current-image response after enrollment must not replace the running CE boot artifact."
  }
}
run "repeat_plan_keeps_original_receipt" {
  command = plan
  module { source = "./modules/kvm-boot-image" }
  variables {
    artifact = { image_download_url = "https://example.com/another-current.qcow2", image_md5_sum = "dddddddddddddddddddddddddddddddd" }
  }
  assert {
    condition     = output.artifact.image_md5_sum == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    error_message = "Repeat planning must preserve the selected boot artifact."
  }
}
run "explicit_site_generation_replacement_captures_new_artifact" {
  command = apply
  module { source = "./modules/kvm-boot-image" }
  variables {
    site_generation = "generation-two"
    artifact        = { image_download_url = "https://example.com/replacement.qcow2", image_md5_sum = "cccccccccccccccccccccccccccccccc" }
  }
  assert {
    condition     = output.artifact.image_md5_sum == "cccccccccccccccccccccccccccccccc"
    error_message = "An explicit replacement must select the new verified boot artifact."
  }
}
