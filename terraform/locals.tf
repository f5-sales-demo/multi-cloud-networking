locals {
  # --- F5 XC tenant endpoint ---
  # Every F5 XC tenant is served at https://<tenant>.console.ves.volterra.io, so
  # naming the tenant is enough to name the API. providers.tf feeds this to the
  # xcsh provider's api_url, which is what makes the TENANT A PROPERTY OF THE
  # CONFIGURATION rather than of whatever XCSH_API_URL the shell happens to hold.
  xc_api_url = "https://${var.expected_xc_tenant}.console.ves.volterra.io"

  # --- Deployer resolution (4-tier fallback) ---
  # 1. Explicit override via var.deployer
  # 2a. Azure AD: given_name initial + surname
  # 2b. Azure AD: mail prefix (guest/external accounts)
  # 3. Object ID hash (service principals, managed identities)
  deployer_from_name = (
    var.deployer == "" && length(data.azuread_user.current) > 0
    ? try(
      lower("${substr(data.azuread_user.current[0].given_name, 0, 1)}${data.azuread_user.current[0].surname}"),
      ""
    )
    : ""
  )

  deployer_from_mail = (
    var.deployer == "" && length(data.azuread_user.current) > 0 && local.deployer_from_name == ""
    ? try(
      lower(split("@", data.azuread_user.current[0].mail)[0]),
      ""
    )
    : ""
  )

  deployer_from_oid = var.deployer == "" && length(data.azuread_client_config.current) > 0 ? try(substr(sha1(data.azuread_client_config.current[0].object_id), 0, 8), "") : ""

  deployer_resolved = coalesce(
    var.deployer,
    local.deployer_from_name,
    local.deployer_from_mail,
    local.deployer_from_oid
  )

  deployer = replace(lower(local.deployer_resolved), "/[^a-z0-9]/", "")

  # --- Derived object names ---
  # Every name in the deployment descends from var.component (plus the resolved
  # deployer for the resource group, which is per-person by nature). Terraform
  # variable defaults cannot reference other variables, so each of these variables
  # defaults to null and is resolved here instead; an explicit value always wins.
  #
  # The point is that NO object name is a literal anyone has to maintain, and none
  # can carry a customer's or an individual's name by accident: change
  # var.component and the sites, load balancer, origin pool, Route Server, Bastion
  # and resource group all follow.
  region_short = coalesce(var.region_short, var.location)
  # SMSv2 site identities have their own immutable generation. The previous
  # mcn-ce-ha-* generation has unrecoverable generic-name reservations in Sales
  # Demo, so a fresh complete showcase must never attempt to recreate it.
  site_prefix = coalesce(var.site_prefix, "${var.component}-${var.smsv2_site_generation}")
  # AWS has account-global names for key pairs, IAM identities, and ELBv2
  # objects. Keep them in the same immutable generation as the site names so
  # a clean deployment cannot collide with stale component-only resources.
  aws_resource_prefix = local.site_prefix
  resource_group_name = coalesce(var.resource_group_name, "rg-${var.component}-${local.deployer}")
  route_server_name   = coalesce(var.route_server_name, "${var.component}-rs")
  bastion_name        = coalesce(var.bastion_name, "${var.component}-bastion")
  client_vm_name      = coalesce(var.client_vm_name, "${var.component}-client")
  origin_pool_name    = coalesce(var.origin_pool_name, "${var.component}-pool")
  # `-f5se` matches the convention this tenant's other load balancers already use.
  lb_name = coalesce(var.lb_name, "${var.component}-f5se")

  # --- Derived Canada object names ---
  ca_region_short        = coalesce(var.ca_region_short, var.ca_location)
  ca_site_prefix         = coalesce(var.ca_site_prefix, "${local.site_prefix}-ca")
  kvm_site_name          = "${local.site_prefix}-kvm"
  ca_resource_group_name = coalesce(var.ca_resource_group_name, "rg-${var.component}-ca-${local.deployer}")
  ca_route_server_name   = coalesce(var.ca_route_server_name, "${var.component}-ca-rs")
  ca_bastion_name        = coalesce(var.ca_bastion_name, "${var.component}-ca-bastion")
  ca_client_vm_name      = coalesce(var.ca_client_vm_name, "${var.component}-ca-client")
  ca_origin_pool_name    = coalesce(var.ca_origin_pool_name, "${var.component}-ca-pool")
  ca_lb_name             = coalesce(var.ca_lb_name, "${var.component}-ca-f5se")
  ca_re_vsite_name       = coalesce(var.ca_re_vsite_name, "${var.component}-ca-re-vsite")
  ca_ce_vsite_name       = coalesce(var.ca_ce_vsite_name, "${var.component}-ca-ce-vsite")

  # --- Standard tags (applied to every Azure resource) ---
  standard_tags = {
    component   = var.component
    environment = var.environment
    deployer    = local.deployer
    managed_by  = "terraform"
  }

  tags = merge(local.standard_tags, var.tags)

  # F5 objects use the same immutable generation and tenant ownership identity
  # as AWS and KVM resources in this one-state deployment.
  xc_labels = {
    "mcn-deployment-generation" = var.smsv2_site_generation
    "mcn-topology"              = "${local.site_prefix}-aws"
    "mcn-xc-tenant"             = var.expected_xc_tenant
  }
  kvm_xc_labels = merge(local.xc_labels, {
    "mcn-topology" = "${local.site_prefix}-kvm"
  })

  # --- SSH public key material, read once at the root ---
  # When ssh_public_key material is supplied (e.g. by the plan tests) it wins and
  # no file is read; otherwise read the key file once and pass the string down.
  ssh_public_key = var.ssh_public_key != "" ? var.ssh_public_key : file(pathexpand(var.ssh_public_key_path))

  # --- CE site registration token fed to cloud-init ---
  # Prefer the provider-generated xcsh_token.ce[0].uid (the Computed token VALUE);
  # an explicit var.registration_token still wins when supplied (break-glass /
  # externally-minted token). Empty var (default) => the generated token.
  ce_registration_token = var.registration_token != "" ? var.registration_token : try(xcsh_token.ce[0].uid, null)

  # --- CE cloud-init, rendered once per node ---
  # Rendered here rather than inline in the module block so the document is
  # addressable as local.ce_cloud_init in `terraform test` — the rendered YAML is
  # the whole contract with the appliance, and it is only worth asserting if it can
  # be read. See tests/cloud_init.tftest.hcl.
  ce_cloud_init = {
    for key, node in module.ce_topology.ce_nodes : key => templatefile("${path.module}/cloud-init/ce-node.yaml", {
      cluster_name = node.site_name
      token        = local.ce_registration_token
      # chomp: a key read from a .pub file ends in a newline, which would render a
      # second, empty line into authorized_keys under `content: |`.
      ssh_public_key = chomp(local.ssh_public_key)
    })
  }

  # --- Canada CE cloud-init, rendered once per node ---
  ca_ce_cloud_init = {
    for key, node in try(module.ce_topology_ca[0].ce_nodes, {}) : key => templatefile("${path.module}/cloud-init/ce-node.yaml", {
      cluster_name   = node.site_name
      token          = local.ce_registration_token
      ssh_public_key = chomp(local.ssh_public_key)
    })
  }
}
