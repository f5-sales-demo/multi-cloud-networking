# Historical Terraform snippets for translated documentation

The translated `docs/*/demo/terraform.mdx` pages still import the retired
`azure-route-server-bgp` module. These two files preserve the exact public
source from the parent of commit `f39b7bc1`, which removed the live module.
They are staged only into the documentation build through `docs/_imports`.
They are not used by Terraform deployments. The next major translation
reconciliation can remove these snapshots when locale pages match English.
