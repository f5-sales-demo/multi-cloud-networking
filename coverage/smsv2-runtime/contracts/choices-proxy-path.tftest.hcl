mock_provider "xcsh" {}
run "rejection" {
  command = plan
  variables { case = "proxy-path" }
}
