# DESIGNED TO FAIL — proves API v9 MTU ranges {0} or [512,8000] reject >8000.
# One reject run per file: a failing run halts the rest of its own file, so each leaf gets
# its own file to guarantee its validator fires. Run via verify.sh (not plain terraform test).
# mock_provider => no credentials; validator fires from the real provider schema at plan.
mock_provider "xcsh" {}

run "reject_mtu_below_min" {
  command = plan

  # The released provider validates the complete union, including its lower bound.
  variables {
    probe_name = "cov-probe-s1-mtu"
    mtu        = 511
    priority   = 10
    vlan_id    = 100
    proxy_port = 8080
  }
}
