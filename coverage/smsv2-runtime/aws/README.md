# Disposable AWS SMSv2 policy fixture

This standalone root supports [#1495](https://github.com/f5-sales-demo/multi-cloud-networking/issues/1495)
and provider umbrella [#2586](https://github.com/f5-sales-demo/terraform-provider-xcsh/issues/2586).
It creates one CE, a private traffic client and a controlled HTTP/HTTPS origin in a task-owned VPC.
It uses no existing showcase state or resource address. Runtime acceptance remains pending until
boot, registration, ONLINE readiness, MAC identity, routing and fresh origin-observed traffic pass.

The fixture pins Terraform 1.16.5, AWS provider 5.100.0 and XC provider 15.9.0. Supply exact approved
CE and Amazon Linux 2023 image IDs and matching CE software/OS versions. Origin initialization uses
Amazon Linux `dnf`. Credentials stay in session environment; do not put them in variables or source.

Create a private state directory and a Terraform installation file containing:

```hcl
provider_installation {
  direct {}
}
```

```sh
export TF_CLI_CONFIG_FILE=/private/path/direct.tfrc
terraform init -backend-config=path=/private/path/aws-fixture.tfstate
terraform plan -var-file=/private/path/fixture.tfvars.json -out=/private/path/apply.tfplan
terraform show -json /private/path/apply.tfplan > /private/path/apply-plan.json
sha256sum /private/path/apply.tfplan
```

Review each saved apply, retirement and destroy plan before applying that exact file. Verify task
identity, allowed resource addresses, image pins, CE routing and preservation of unrelated state.
Keep plans, state, registration output and runtime logs private. The client has no public IP and
its default AWS route targets the CE SLI. Origin HTTP/HTTPS ingress explicitly permits the CE EIP.
This prevents a cloud security-group drop from imitating CE policy enforcement.

The AWS contract uses three phases. Start with `phase = "bootstrap"`, a unique non-personal
`task_id`, and a task-owned SSH key. Reapply after registration to create approval, then verify the
running node and collect private outputs:

```sh
terraform output -json fixture > /private/path/fixture.json
terraform output -json hardware > /private/path/hardware.json
python3 ../../../scripts/smsv2_fixture_mapping.py \
  --fixture /private/path/fixture.json --hardware /private/path/hardware.json \
  --output /private/path/device-mapping.json
```

The mapping joins the observed bootstrap registration to the two Terraform-owned ENI MACs; it
rejects missing, foreign, duplicate and terminal registrations. `phase = "retired"` removes only
the bootstrap site, token, approval and CE instance while retaining the network, ENIs, EIP, client
and origin. Review and apply that retirement plan before setting `phase = "configured"` and
`device_mapping_file` to the private mapping file. Configured creation uses a distinct site identity.
Do not guess device names or turn a bootstrap site into a configured site in place.

Use SSH through the origin to reach the private client. Address HTTPS as
`origin.qualification.test` with an explicit resolver mapping to the task-owned origin public IP and
trust the origin's generated certificate. Generate a new UUID for every request and send it as
the `case` query parameter. The origin always returns HTTP 200 and echoes the case; its JSON access
log records the case, source, URI and status. Compare fresh client traffic with origin logs and
the CE's runtime path. A successful HTTP response or an absent origin entry alone is insufficient.

`firewall_policies` and `proxy_policies` are ordered lists of `{ name, namespace }` references.
The parent site's attachment blocks are the sole association writer. Keep the substrate stable
while qualifying one capability family; HTTPS SNI filtering does not establish TLS decryption.

At cycle completion, save, review and hash a destroy plan, apply that exact plan, and verify empty
task state plus absence of task-owned cloud and XC objects. Preserve first failures and corrective
receipts separately. This source fixture does not close live qualification issues.

Validation:

```sh
terraform validate
terraform test
python3 ../../../tests/test_fixture_mapping.py
```
