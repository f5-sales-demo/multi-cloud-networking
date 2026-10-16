mock_provider "xcsh" {}
run "root_selection_conflict" {
  command         = plan
  expect_failures = [xcsh_enhanced_firewall_policy.root_conflict]
}
run "nested_action_conflict" {
  command = plan
  variables { case = "nested" }
  expect_failures = [xcsh_enhanced_firewall_policy.action_conflict]
}
