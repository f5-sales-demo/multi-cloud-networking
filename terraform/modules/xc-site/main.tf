# Parks the identity of the CE VM instance the site's node runs on, so the site
# object has something to be coupled to. Nothing else reads it — its only job is
# to be named in the site's replace_triggered_by below.
#
# WHY A SEPARATE RESOURCE. replace_triggered_by may only name managed resources
# declared in the SAME module as the resource carrying the lifecycle block, and
# the CE VM lives in modules/ce-node. Parking the id here is the standard way to
# carry an external value across that boundary.
#
# WHY input AND NOT triggers_replace. This resource must never itself be
# replaced — only observed. A changed `input` is an in-place UPDATE, which is
# what replace_triggered_by reacts to; that keeps the resource cheap and its
# behaviour on ADOPTION correct (see below).
#
# ADOPTION IS INERT. Adding this resource to a deployment that already exists
# plans it as a CREATE, and a create of the referenced resource does NOT fire
# replace_triggered_by — only a subsequent change to its value does. Verified on
# Terraform v1.10.5 and again on v1.15.0:
# adding the pair to a populated state plans "1 to add, 0 to change,
# 0 to destroy". So this fix does not itself trigger the fleet-wide rebuild it
# exists to prevent — no import, no targeted apply, no seeding.
resource "terraform_data" "ce_vm" {
  input = var.ce_vm_instance_id
}

# Single-node Secure Mesh v2 CE site with an EXPLICIT eth0/SLO interface. The
# explicit interface is what makes XC auto-create the network_interface object
# (var.interface_name) that the BGP peer binds to — without it a standalone bgp
# object is accepted but never renders to FRR (see xcsh #1207).
resource "xcsh_securemesh_site_v2" "this" {
  count       = var.create_site ? 1 : 0
  name        = var.site_name
  namespace   = "system"
  description = "MCN CE-HA (BGP/ECMP) single-node SMSv2 site ${var.site_name} — explicit eth0 SLO interface for BGP peer binding."
  # `null`, not `{}`, when no labels are set. xcsh #1286 makes the provider preserve a
  # config-declared empty map on the POST-APPLY read-back, but import has no config to
  # read: the state carries only id/name/namespace and `ReadRequest` exposes nothing
  # else, so a literal `{}` would still re-plan as `+ labels = {}` on the first
  # post-import plan. Sending `null` when the map is empty stops asking the provider to
  # distinguish "declared empty" from "absent" — something it cannot observe on import.
  # (The nested `interface_list.labels {}` marker is a separate class, fixed by xcsh #1244.)
  #
  # EXPECTED ONE-TIME DRIFT AFTER A NODE (RE)REGISTERS. F5 XC stamps the node's
  # hardware facts onto the site as labels (host-os-version, hw-model,
  # hw-serial-number, hw-vendor, hw-version) once the CE registers. The next plan
  # therefore shows `- labels = {...} -> null` for that site, and applying it
  # settles — XC does not re-stamp them. It is one more convergence pass in the
  # already two-phase deploy, not drift to chase; observed on the site rebuilt by
  # the #674 CE replacement.
  labels = length(var.labels) > 0 ? var.labels : null

  azure {
    not_managed {
      node_list {
        hostname  = var.hostname
        type      = "Control"
        public_ip = null

        interface_list {
          name = "eth0"

          ethernet_interface {
            device = "eth0"
            mac    = var.mgmt_nic_mac
          }

          # Site Local Outside (SLO) — required on every site; BGP peers from here.
          network_option {
            site_local_network = {}
          }

          dhcp_client = {}
        }
      }
    }
  }

  block_all_services = {}
  disable_ha         = {}

  dns_ntp_config {
    f5_dns_default = {}
    f5_ntp_default = {}
  }

  local_vrf {
    default_config     = {}
    default_sli_config = {}
  }

  logs_streaming_disabled = {}
  no_forward_proxy        = {}
  no_network_policy       = {}
  no_s2s_connectivity_sli = {}
  no_s2s_connectivity_slo = {}

  offline_survivability_mode {
    no_offline_survivability_mode = {}
  }

  performance_enhancement_mode {
    perf_mode_l7_enhanced {
      # The provider schema gives perf_mode_l7_enhanced a {jumbo_disabled | jumbo_enabled}
      # sub-oneof. F5 materialises jumbo_disabled server-side, so leaving both members
      # undeclared makes the site land and then re-plan the marker as a removal on
      # every subsequent plan — it never reaches 0 changes. Declaring the server
      # default explicitly is what settles it (same fix coverage/smsv2 took in #625).
      jumbo_disabled = {}
    }
  }

  re_select {
    geo_proximity = {}
  }

  # CE software and OS selection is create-time configuration. The node always
  # installs a destination build on first boot; an empty variable arms the
  # default_* marker and means "install the newest version the server advertises."
  # That is the deployment policy, not an accidental omission. The clean
  # 2026-08-03 rebuild selected the advertised pair on all three 64 GB nodes and
  # brought all three sites ONLINE. Issue #714 separately proves why the disk
  # default carries headroom: the same pair failed on the marketplace image's
  # 31 GiB disk and installed at every tested size from 33 GB upwards.
  #
  # Terraform cannot update these fields after creation: PUT is rejected when
  # pinning forward, pinning backward, or clearing a pin. The platform can perform
  # an in-place change through the site upgrade_sw and upgrade_os actions, but the
  # provider cannot drive those actions yet (xcsh#1390). Set a concrete value only
  # when deliberately reproducing an older build.
  software_settings {
    os {
      default_os_version       = var.os_version == "" ? {} : null
      operating_system_version = var.os_version == "" ? null : var.os_version
    }
    sw {
      default_sw_version        = var.sw_version == "" ? {} : null
      volterra_software_version = var.sw_version == "" ? null : var.sw_version
    }
  }

  # Rebuild the site object whenever the CE VM instance it describes is rebuilt
  # (issue #674).
  #
  # THE FAILURE THIS PREVENTS. A CE's runtime registration is bound to one node
  # instance and holds the control plane's unique
  # (tenant, cluster_name, hostname) index. Destroying the VM does NOT retire
  # that registration, so the replacement node — same site, same hostname —
  # cannot create its own: the create fails with UniqueSecondaryIndexViolation
  # and retries on a ~65 s loop forever. Nothing recovers on its own, and worse,
  # nothing in the graph noticed: with no reference to the node's identity
  # anywhere, `terraform plan` reported "No changes" for the whole time the
  # fleet was down.
  #
  # WHY REPLACING THE SITE IS THE FIX. Deleting the site object takes its
  # registrations with it — observed live while replacing one CE: the site
  # 404ed and the registration bound to the outgoing instance disappeared in the
  # same poll — so the replacement node registers into a site whose index key is
  # free. Deleting only the registration is not enough: the site keeps a status
  # object that then rejects the node's workload request.
  #
  # THE ORDER IS THE POINT. Terraform runs this as: destroy site -> destroy VM
  # -> create VM -> create site. The stale registration is therefore gone before
  # the replacement node ever boots, and the site is back before the node
  # finishes booting and registers. The outgoing node cannot slip a fresh
  # registration into the gap: once its own registration is deleted it 404-loops
  # against the name it persisted in registration-obj.yml instead of creating a
  # new one.
  #
  # SAFE WHILE OTHER OBJECTS REFERENCE THE SITE. xcsh_bgp and the root HTTP load
  # balancer's advertise_where both name this site, and F5 XC resolves those
  # references lazily: deleting a site that both of them reference returns HTTP
  # 200 and leaves them intact, and re-creating it under the same name re-binds
  # them (verified against the live tenant with a throwaway site).
  #
  # THAT LAZINESS DOES NOT EXTEND TO CREATION, and the difference has bitten once.
  # An EXISTING load balancer tolerates a dangling site reference; POSTing a NEW one
  # whose advertise_where names a site that does not exist yet is rejected outright
  # with `[BAD_REQUEST] Invalid request parameters`. Renaming the deployment does
  # exactly that — every site is destroyed and re-created under a different name, so
  # the load balancer is created fresh — which is why the root resource now carries
  # an explicit `depends_on = [module.xc_site]`. Do not remove it on the strength of
  # the paragraph above: it is about deletion, not creation.
  lifecycle {
    replace_triggered_by = [terraform_data.ce_vm]
  }
}

# The approve API takes the runtime registration name ("r-<uuid>"), NOT the site
# name (GET .../registrations/<site> -> 404). registrations_by_site returns
# HTTP 200 with items:[] for a site whose CE has not registered yet, so this read
# never fails an early apply — it just reports found = false.
#
# NOTE: this data source must never carry depends_on. Its inputs are statically
# derived from ce_topology, so it resolves at plan time; a resource dependency
# would make the count below unknown at plan time ("The count value depends on
# resource attributes that cannot be determined until apply").
data "xcsh_site_registration" "this" {
  site_name = var.site_name # == passport.cluster_name (cloud-init ClusterName)
  hostname  = var.hostname  # discriminator for multi-node sites
  namespace = "system"
}

# Approve the CE registration so the node reaches ONLINE without the manual
# console step (#1206 / #1210). The registration exists only after the CE boots
# and registers via the token, so the first apply plans no approval; re-apply
# once the CE has registered (see the deploy ordering in main.tf).
#
# The action only legitimately transitions a NEW registration. Retired and
# already-admitted registrations are observations, never approval targets.
# Keeping the guard in the module rather than relying on provider selection also
# protects installed provider versions that predate terminal-state filtering.
#
# Approval can auto-provision a site in XC, so it must wait for Terraform's
# explicit site creation. The data source deliberately has no dependency: its
# result determines this resource's plan-known count.
resource "xcsh_registration_approval" "this" {
  count = var.approve_registration && data.xcsh_site_registration.this.found && data.xcsh_site_registration.this.state == "NEW" ? 1 : 0

  namespace    = "system"
  name         = data.xcsh_site_registration.this.name
  cluster_size = 1
  state        = "APPROVED"

  depends_on = [xcsh_securemesh_site_v2.this]
}

# One bgp object per CE site: eBGP from the CE (ASN var.ce_asn) to two regional FRR routers
# (ASN var.peer_asn), one external peer per router IP, each bound to the explicit SLO interface.
#
# NOT BLOCKED — and nothing about this arm is gated any more. The object-ref name
# length limit that used to block it is gone: the provider relaxed it to
# stringvalidator.LengthBetween(1, 128) in v3.74.0, so the 71-char interface object
# XC auto-generates for the explicit SLO interface
# (ves-io-securemesh-site-v2-<site>-network-<hostname>-eth0-0) validates. The floor
# that guarantees it is declared once, in versions.tf — do not restate the number.
#
# var.enable_bgp therefore defaults true and every test now runs with that default;
# it survives only as an escape hatch for deploying the topology without BGP. It is
# NOT an ordering gate: var.interface_name is derived statically from ce_topology, and
# XC accepts a bgp object naming an interface that does not exist yet (it converges
# once the CE is up — see the deploy ordering in the root main.tf).
resource "xcsh_bgp" "this" {
  count = var.enable_bgp ? 1 : 0

  name        = "${var.site_name}-bgp"
  namespace   = "system"
  description = "CE ${var.site_name} BGP to Azure Route Server via explicit SLO interface."

  where {
    site {
      ref {
        namespace = "system"
        name      = var.site_name
      }
      network_type         = "VIRTUAL_NETWORK_SITE_LOCAL"
      disable_internet_vip = {}
    }
  }

  bgp_parameters {
    asn = var.ce_asn
    # local_address {} = derive the BGP router ID from the interface's local
    # address (the JSON's BGP_ROUTER_ID_FROM_INTERFACE; there is no separate
    # bgp_router_id_type attribute in the provider schema).
    local_address = {}
  }

  # Iterate over a plan-KNOWN peer count (rs_peer_count) and index into
  # rs_peer_ips. The IP values may be unknown until the Route Server is applied,
  # but the number of peers is fixed, so the block expands cleanly at plan time.
  dynamic "peers" {
    for_each = { for i in range(var.peer_count) : "azure-frr-${i + 1}" => i }
    content {
      metadata {
        name = peers.key
      }

      external {
        asn     = var.peer_asn
        address = try(var.peer_ips[peers.value], "")
        port    = var.peer_port

        interface {
          namespace = "system"
          name      = var.interface_name
        }

        disable_v6 = {}
      }

      passive_mode_disabled = {}
      bfd_disabled          = {}
    }
  }
}
