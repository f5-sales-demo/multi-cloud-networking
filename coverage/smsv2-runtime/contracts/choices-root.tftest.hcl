mock_provider "xcsh" {}
run "rejection" {
  command = plan
  variables { case = "root" }
}
