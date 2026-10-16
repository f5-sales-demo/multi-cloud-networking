# Disposable Azure SMSv2 policy fixture

Independent runtime qualification under [#1503](https://github.com/f5-sales-demo/multi-cloud-networking/issues/1503)
and provider [#2586](https://github.com/f5-sales-demo/terraform-provider-xcsh/issues/2586).
Runtime acceptance is pending until real image boot, registration, completed readiness, observed
MAC identity, routing and fresh HTTP/HTTPS origin observations pass. Historical Azure receipts
without a backing VM do not qualify this fixture.

This root pins Terraform 1.16.5, azurerm 4.81.0 and xcsh 15.9.0. It creates a separate task-owned
resource group, single CE, two ordered SLO/SLI NICs, private client, controlled origin and UDR.
Use exact Marketplace SKU/version/plan and Ubuntu version inputs. The CE SKU must support the
image generation and NIC count; the OS disk is explicitly 100 GiB. Check Marketplace terms,
resource-provider registration and subscription quotas before generating the apply plan.

Use an explicit direct provider installation file and private local state:

```sh
export TF_CLI_CONFIG_FILE=/private/path/direct.tfrc
terraform init -reconfigure -backend-config=path=/private/path/azure-fixture.tfstate
terraform plan -var-file=/private/path/fixture.tfvars.json -out=/private/path/apply.tfplan
terraform show -json /private/path/apply.tfplan > /private/path/apply-plan.json
sha256sum /private/path/apply.tfplan
```

Review every apply, retirement and destroy plan and apply that exact file. Verify subscription,
task labels, image and version pins, expected addresses and preservation of unrelated resources.
Credentials are session-only; state, plans, subscription identity, keys, boot diagnostics and
raw registrations remain private. The resource group and all applicable resources have task tags.
The client has no public IP or default Azure outbound path; its UDR targets the CE SLI. The origin
NSG explicitly permits HTTP/HTTPS from the CE public IP so cloud filtering cannot imitate CE
policy enforcement.

Start with `phase = "bootstrap"`. The Azure cloud-init merge retains every provider-issued
section and appends the image admin account's operator key; it does not invent a VPM configuration.
Azure VM provisioning uses `azureuser`, because Azure rejects the reserved `admin` provisioning
username. The appliance operator account remains `admin`. Two MACs are normalized from Azure's
hyphen notation to registration colon notation. Join real registration devices to the owned NICs
and save the checksummed mapping privately. Azure registrations can report both a synthetic
`hv_netvsc` interface and a bonded SR-IOV alias under the same MAC. The Azure-specific mapper
selects exactly one observed synthetic interface and retains the known VF alias. It rejects
unknown or ambiguous pairs; device names are never guessed. See Microsoft
[application binding requirements](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview).

```sh
python3 ../../../scripts/smsv2_azure_fixture_mapping.py \
  --fixture /private/path/fixture.json --hardware /private/path/hardware.json \
  --output /private/path/device-mapping.json
```

 `phase = "retired"` removes only the bootstrap CE,
site, token and approval, retaining all substrate. Then `phase = "configured"` creates a distinct
site using `device_mapping_file`. Never guess devices or convert a bootstrap site in place.

Wait for dataplane readiness after registration ONLINE; preserve first failures during upgrades.
Use an SSH jump through the origin to the private client. Address the HTTPS origin as
`origin.qualification.test`, explicitly resolve it to the owned origin and trust its generated
certificate. Use fresh request UUIDs and compare client responses with origin logs and CE routing.

`firewall_action`, `firewall_scoped_first` and `firewall_companion_action` support scoped rule
updates and ordering. Create policies first, then set ordered `firewall_policies` references in
the parent site. `proxy_policies` also uses only parent association blocks. Prove HTTP URL and
TLS/SNI behavior independently; HTTPS filtering does not establish TLS decryption.

At cycle completion, review and hash a destroy plan, apply that exact plan and verify empty
managed state, absent task-owned Azure resources/resource group, XC objects and registrations.
The live issue remains open until those receipts exist.

Validation is credential-free:

```sh
terraform validate
terraform test
```
