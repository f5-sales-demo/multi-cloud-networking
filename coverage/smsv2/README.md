# SMSv2 coverage probe

Azure-free. Creates one `xcsh_securemesh_site_v2` object in the `system` namespace
to exercise schema arms. The object creates/reads/deletes with **no backing Azure
VM** (each an HTTP 200). Never targets the live demo sites
(`ar-bgp-eastus01/02/03`).

## Runs — always against a registry release

Drive this probe with an explicit `TF_CLI_CONFIG_FILE`, never with the ambient
`~/.terraformrc`:

```bash
cd coverage/smsv2
printf 'provider_installation {\n  direct {}\n}\n' > /tmp/tfrc-registry-only.hcl
export TF_CLI_CONFIG_FILE=/tmp/tfrc-registry-only.hcl
terraform init -upgrade    # confirm the log names the version you expect
set -a; source /tmp/mcn-xcsh.env; set +a   # live XC creds (env-only, never commit)
terraform apply -auto-approve -var probe_name=cov-probe-s0-01
terraform plan  -var probe_name=cov-probe-s0-01   # expect: No changes (idempotent)
terraform destroy -auto-approve -var probe_name=cov-probe-s0-01
```

A `dev_overrides` entry in `~/.terraformrc` silently substitutes a local working-tree build for
the released provider, and the resulting failure does not look like a version problem: against a
pre-v3.80.0 build this probe errors with `Blocks of type "jumbo_disabled" are not expected here`,
which reads as a config bug. `dev_overrides` also forbids `terraform init`, so the lock file
cannot be refreshed while it is active. `TF_CLI_CONFIG_FILE` overrides `~/.terraformrc` outright,
so it is the only supported way in.

`versions.tf` is the only **tracked** place a provider version is pinned. `.terraform.lock.hcl`
pins the resolved version at runtime but is gitignored, so `terraform init -upgrade` is what tells
you which release you are actually testing — read its log. See the comment in `versions.tf` for why
nothing else may restate a version.

Use a **fresh `-var probe_name=` per run** — a stale name collides with the tenant's
existing StatusObject and 500s on create. XC site names reject underscores, so keep them
hyphenated.

## Adding a file here needs `git add -f`

`.gitignore` ignores `coverage/` wholesale (a rule aimed at test-coverage output, which this
directory is not). Every tracked file here was force-added, so `git add -A` **silently skips** any
new one — `git status` will not even list it, because it is ignored rather than untracked:

```bash
git add -f coverage/smsv2/reject-tests/reject-my-new-leaf.tftest.hcl
```

S8 lost `reject-drain-count-min.tftest.hcl` this way. `verify.sh` caught it in CI — the assertion
was present but its reject case was not in the commit, so the diagnostic never appeared — which is
exactly why the assertion list lives in `verify.sh` rather than being inferred from the files on
disk. `.gitignore` is managed by docs-control, so the rule cannot be fixed from this repo.

## Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `probe_name` | `cov-probe-01` | Throwaway site name (override per run). |
| `mtu` | `1500` | eth0 interface MTU. API v9 validator: `0` or `512–8000`. |
| `priority` | `10` | eth0 interface priority. Validator `Between(0, 255)`. |
| `vlan_id` | `100` | vlan_interface VLAN tag. Validator `Between(1, 4095)`. |
| `proxy_port` | `8080` | custom_proxy port. Validator `Between(0, 65535)`. |
| `extended_arms` | `true` | Render the `vlan_interface` interface + top-level `custom_proxy` so the `vlan_id`/`proxy_port` leaves are reachable at plan. Set `false` for a live apply — those two arms 400 on this single-node probe, but the base eth0 interface (carrying `mtu`/`priority`) still applies live. |
| `interface_arm` | `ethernet` | eth0 interface_choice oneof: `ethernet` \| `bond` \| `vlan`. `ethernet` is live; `bond`/`vlan` are plan-only (400 live). |
| `address_arm` | `static_ip` | eth0 address_choice oneof: `dhcp_client` \| `static_ip` \| `no_ipv4_address`. All three live-appliable. |
| `ipv6_arm` | `no_ipv6_address` | eth0 ipv6_address_choice oneof: `no_ipv6_address` \| `ipv6_auto_config` \| `static_ipv6_address`. `no_ipv6_address` is live; the other two are plan-only (400 live). |
| `monitor_arm` | `monitor_disabled` | eth0 monitoring_choice oneof: `monitor` \| `monitor_disabled`. Both live-appliable. |
| `s2s_iface_arm` | `disabled` | eth0 site_to_site_connectivity_interface_choice oneof: `disabled` \| `enabled`. Both live-appliable. |
| `blocked_service_arm` | `ssh` | blocked_service service_choice oneof: `dns` \| `ssh` \| `web_user_interface`. All three live-appliable; F5 keeps exactly one member. |
| `l7_jumbo_arm` | `jumbo_disabled` | perf_mode_l7_enhanced jumbo sub-oneof: `jumbo_disabled` \| `jumbo_enabled`. Both live-appliable; `jumbo_disabled` is the server default. |
| `l3_jumbo_arm` | `no_jumbo` | perf_mode_l3_enhanced jumbo sub-oneof: `no_jumbo` \| `jumbo`. Different member names from the l7 pair. Rendered only when `perf_arm=perf_mode_l3_enhanced`; both live-appliable. |

## S3 interface / addressing oneof arms

Every eth0 interface oneof is modeled as an **enum selector** (`interface_arm`, `address_arm`,
`ipv6_arm`, `monitor_arm`, `s2s_iface_arm`) so exactly one member of each oneof renders and no two
siblings ever coexist (which would trip the provider's `ConflictsWith`). Defaults are the live-safe
base arm, so a bare apply (with `extended_arms=false`) stays idempotent and import-clean.

**Live-appliable** (HTTP 200, idempotent, import-clean):
`ethernet_interface`, `dhcp_client`, `static_ip`, `no_ipv4_address`, `no_ipv6_address`, `monitor`,
`monitor_disabled`, `site_to_site_connectivity_interface_disabled`, and
`site_to_site_connectivity_interface_enabled` (s2s `enabled` was expected to need s2s wiring but the
single-node `azure` probe accepts it — verified live).

**Plan-only** — these return `[BAD_REQUEST] Invalid request parameters (status: 400)` on the
single-node `azure` not_managed probe, so their schema is proven at PLAN only (like `vlan_id`/
`proxy_port`): `bond_interface` (`interface_arm=bond`), `vlan_interface` (`interface_arm=vlan`),
`static_ipv6_address` (`ipv6_arm=static_ipv6_address`), `ipv6_auto_config`
(`ipv6_arm=ipv6_auto_config`). Their validated leaves (bond `devices` `SizeBetween(1, 8)`,
static_ipv6 `node_static_ip.ip_address` `CIDRValidator()`) are proven by `verify.sh` reject tests;
`vlan_id` `Between(1, 4095)` is already covered by S1.

Live cycle per live-appliable arm (fresh `probe_name`, `extended_arms=false`):

```bash
cd coverage/smsv2
set -a; source /tmp/mcn-xcsh.env; set +a
terraform apply   -auto-approve -var probe_name=cov-probe-s3-x -var extended_arms=false -var monitor_arm=monitor
terraform plan                  -var probe_name=cov-probe-s3-x -var extended_arms=false -var monitor_arm=monitor  # No changes
terraform state rm xcsh_securemesh_site_v2.probe
terraform import  -var probe_name=cov-probe-s3-x -var extended_arms=false -var monitor_arm=monitor xcsh_securemesh_site_v2.probe system/cov-probe-s3-x
terraform plan                  -var probe_name=cov-probe-s3-x -var extended_arms=false -var monitor_arm=monitor  # No changes
terraform destroy -auto-approve -var probe_name=cov-probe-s3-x -var extended_arms=false -var monitor_arm=monitor
```

## S4 networking / services oneof arms

Every top-level networking/services oneof is modeled as an **enum selector** (`services_arm`,
`ha_arm`, `dns_arm`, `ntp_arm`, `proxy_arm`, `proxy_bypass_arm`, `url_cat_arm`, `mgmt_net_arm`,
`s2s_slo_arm`, `s2s_sli_arm`, `forward_proxy_arm`, `network_policy_arm`, `logs_arm`, `vip_vrrp_mode`,
`segment_vrf_arm`) that supersedes the pre-S4 base literal so exactly one member of each oneof
renders. Every default is the base arm, so a bare `terraform plan` (all defaults) is unchanged versus
the pre-S4 base (verified: applied the committed base, swapped in the S4 code, defaults plan =
"No changes").

**Live-appliable (S4a)** — apply→idempotent→import (0-change)→destroy on the
single-node `azure` probe: `f5_proxy`, `custom_dns`, `custom_ntp`, `custom_proxy_bypass`,
`no_proxy_bypass`, `enable_url_categorization`, `disable_url_categorization`,
`disable_management_network`, `load_balancing.vip_vrrp_mode` (ENABLE + DISABLE),
`site_mesh_group_on_slo` all-empty (`no_site_mesh_group{} sm_connection_public_ip{}`), and
`blocked_services` (live since S7 — see below).

**Plan-only** — proven at plan via `validation.tftest.hcl` positive asserts (would 400 / needs a ref
live):

- `enable_ha`, `enable_management_network` — 400 on a single-node probe.
- `active_forward_proxy_policies`, `active_enhanced_firewall_policies`, `log_receiver_with_net`,
  `dc_cluster_group_sli`, `dc_cluster_group_slo`, `site_mesh_group_on_slo` (ref variant) — ObjectRefType
  arms whose referents must pre-exist.
- `segment_vrf` — needs a Segment object ref the provider cannot yet inject (api-specs-enriched #1053).

Logs are driven via `log_receiver_with_net`, never the stale top-level `log_receiver` field
(provider #1256).

Live cycle per S4a arm (fresh `probe_name`, `extended_arms=false`):

```bash
cd coverage/smsv2
set -a; source /tmp/mcn-xcsh.env; set +a
terraform apply   -auto-approve -var probe_name=cov-probe-s4-x -var extended_arms=false -var vip_vrrp_mode=VIP_VRRP_ENABLE
terraform plan                  -var probe_name=cov-probe-s4-x -var extended_arms=false -var vip_vrrp_mode=VIP_VRRP_ENABLE  # No changes
terraform state rm xcsh_securemesh_site_v2.probe
terraform import  -var probe_name=cov-probe-s4-x -var extended_arms=false -var vip_vrrp_mode=VIP_VRRP_ENABLE xcsh_securemesh_site_v2.probe system/cov-probe-s4-x
terraform plan                  -var probe_name=cov-probe-s4-x -var extended_arms=false -var vip_vrrp_mode=VIP_VRRP_ENABLE  # No changes
terraform destroy -auto-approve -var probe_name=cov-probe-s4-x -var extended_arms=false -var vip_vrrp_mode=VIP_VRRP_ENABLE
```

## S5 site-mode oneof arms

Every site-mode oneof (performance mode, OS/SW version, offline survivability, RE selection, upgrade
drain, admin credentials) is modeled as an **enum selector** (`perf_arm`, `os_arm`/`os_version`,
`sw_arm`/`sw_version`, `offline_arm`, `re_select_arm`, `upgrade_drain_arm`, `vega_arm`, `admin_creds`)
that supersedes the pre-S5 hardcoded literal, plus gated `upgrade_settings` + `admin_user_credentials`
blocks (both unset in the base). Every default renders the identical base member, so a bare
`terraform plan` (all defaults) is unchanged versus the pre-S5 base (verified: defaults
apply→0-change→import→destroy round-trips 0-change).

**Live-appliable (S5a)** — apply→idempotent→import (0-change)→destroy on the
single-node `azure` probe: `perf_mode_l3_enhanced{no_jumbo{}}`, `operating_system_version`
(`9.2024.6`), `volterra_software_version` (`crt-20250613-3382`; both version leaves are **create-only**
yet round-trip 0-change), `enable_offline_survivability_mode`, and
`upgrade_settings.kubernetes_upgrade_drain.enable_upgrade_drain` (drain count/timeout + vega
sub-oneof). `enable_upgrade_drain` was expected plan-only (k8s worker drain on a non-k8s node) but the
single-node probe accepts it — reclassified live after verification.

**Plan-only (S5b)** — return `[BAD_REQUEST] Invalid request parameters (status: 400)` live on the
single-node probe, so proven at plan via `validation.tftest.hcl` positive asserts:

- `admin_user_credentials` — needs node local services / a multi-node CE. Its `admin_password`
  SecretType uses `clear_secret_info { url = "string:///<base64>" }` — the only dependency-free
  backend (blindfold/vault/wingman need external providers → 400) — with a base64 of a **dummy
  throwaway placeholder**; NO real secret is committed. `ssh_key` `LengthAtMost(8192)` is
  reject-proven at plan. The `secret_encoding_type` leaf S5 covered is gone — the upstream F5 spec
  dropped it from SecretType, so provider v3.80.0 has no such attribute.
- `re_select.specific_re` — `primary_re` must name a real RE geography (a dummy name 400s);
  `primary_re` `LengthBetween(1, 64)` reject-proven at plan.

Live cycle per S5a arm (fresh `probe_name`, `extended_arms=false`):

```bash
cd coverage/smsv2
set -a; source /tmp/mcn-xcsh.env; set +a
terraform apply   -auto-approve -var probe_name=cov-probe-s5-x -var extended_arms=false -var os_arm=operating_system_version -var sw_arm=volterra_software_version
terraform plan                  -var probe_name=cov-probe-s5-x -var extended_arms=false -var os_arm=operating_system_version -var sw_arm=volterra_software_version  # No changes
terraform state rm xcsh_securemesh_site_v2.probe
terraform import  -var probe_name=cov-probe-s5-x -var extended_arms=false -var os_arm=operating_system_version -var sw_arm=volterra_software_version xcsh_securemesh_site_v2.probe system/cov-probe-s5-x
terraform plan                  -var probe_name=cov-probe-s5-x -var extended_arms=false -var os_arm=operating_system_version -var sw_arm=volterra_software_version  # No changes
terraform destroy -auto-approve -var probe_name=cov-probe-s5-x -var extended_arms=false -var os_arm=operating_system_version -var sw_arm=volterra_software_version
```

## S7 `blocked_services` (provider >= 3.80.0)

`versions.tf` pins `>= 3.80.0` — the first release carrying the `x-f5xc-wire-name` contract (specs
`v2.1.194`). On anything older, `blocked_services` fails the apply with `Provider produced inconsistent
result after apply` (provider #1257): the provider sent JSON key `blocked_service` while F5's runtime
key is the misspelled `blocked_sevice`, so the API dropped the block. Verified against the live API —
`GET /api/config/namespaces/system/securemesh_site_v2s/<probe>` returns
`spec.blocked_services.blocked_sevice[]`, so the wire-name mapping is load-bearing. The
Terraform-facing name is unchanged (`blocked_service`).

`blocked_service`'s `service_choice` members (`dns`, `ssh`, `web_user_interface`) are an enum selector
because **F5 keeps exactly one** — configuring two silently dropped one, and the provider's
absent-marker suppression hid the drop behind a 0-change plan.

```bash
cd coverage/smsv2
set -a; source /tmp/mcn-xcsh.env; set +a
terraform apply   -auto-approve -var probe_name=cov-probe-s7-bs-x -var extended_arms=false -var services_arm=blocked_services -var blocked_service_arm=ssh
terraform plan                  -var probe_name=cov-probe-s7-bs-x -var extended_arms=false -var services_arm=blocked_services -var blocked_service_arm=ssh  # No changes
terraform state rm xcsh_securemesh_site_v2.probe
terraform import  -var probe_name=cov-probe-s7-bs-x -var extended_arms=false -var services_arm=blocked_services -var blocked_service_arm=ssh xcsh_securemesh_site_v2.probe system/cov-probe-s7-bs-x
terraform plan                  -var probe_name=cov-probe-s7-bs-x -var extended_arms=false -var services_arm=blocked_services -var blocked_service_arm=ssh  # No changes
terraform destroy -auto-approve -var probe_name=cov-probe-s7-bs-x -var extended_arms=false -var services_arm=blocked_services -var blocked_service_arm=ssh
```

Two unrelated v3.80.0 schema deltas came with the pin: SecretType lost `secret_encoding_type`, and
`perf_mode_l7_enhanced` gained a `{jumbo_disabled | jumbo_enabled}` sub-oneof. The server materializes
`jumbo_disabled`, so `l7_jumbo_arm` declares it — an undeclared marker re-plans as a removal after
import.

## S1 numeric-validation gate

```bash
cd coverage/smsv2
./verify.sh   # credential-free: mocks the xcsh provider; the real schema validators fire at plan
```

`verify.sh` proves the SMSv2 numeric validators both accept valid bounds and reject
out-of-range input. It wraps `terraform test` because Terraform's `expect_failures` only
captures user custom conditions, not provider schema validators: `validation.tftest.hcl`
asserts the accept case, and `reject-tests/*.tftest.hcl` (one leaf per file, *designed to
fail*) are driven with `-test-directory=reject-tests` while verify.sh asserts each leaf's
exact validator diagnostic. This is the gate the `coverage-smsv2` CI job runs.

Coverage progress is tracked in `../smsv2-coverage-matrix.md`.
