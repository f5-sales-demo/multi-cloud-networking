variable "site_name" {
  description = "XC securemesh_site_v2 name (e.g. mcn-ce-ha-eastus01), created in namespace system."
  type        = string
}

variable "hostname" {
  description = "CE node hostname, must match the Azure VM computer name."
  type        = string
}

variable "interface_name" {
  description = "Auto-derived network_interface object name the BGP peer references: ves-io-securemesh-site-v2-<site>-network-<hostname>-eth0-0."
  type        = string
}

variable "mgmt_nic_mac" {
  description = "Observed MAC of the CE eth0/SLO NIC; null before VM attachment."
  type        = string
  default     = null
}

variable "ce_generation_id" {
  description = "Pre-boot generation shared by the XC site and Azure CE VM."
  type        = string
  validation {
    condition     = trimspace(var.ce_generation_id) != ""
    error_message = "ce_generation_id must identify the exact planned CE generation."
  }
}

variable "peer_ips" {
  description = "List of regional FRR BGP peer IPs (virtual_router_ips), e.g. [10.0.4.4, 10.0.4.5]. Values may be unknown until apply; the count of peers comes from peer_count so the peers block expands at plan time."
  type        = list(string)
}

variable "peer_count" {
  description = "Number of external BGP peers (regional FRR always exposes exactly 2 virtual router IPs). Drives the peers block with a plan-known count so for_each never sees an unknown value."
  type        = number
  default     = 2
}

variable "ce_asn" {
  description = "CE (local) BGP ASN."
  type        = number
  default     = 64512
}

variable "peer_asn" {
  description = "Route Server (peer) BGP ASN."
  type        = number
  default     = 65515
}

variable "peer_port" {
  description = "BGP peer TCP port."
  type        = number
  default     = 179
}

variable "labels" {
  description = "Labels applied to the site object."
  type        = map(string)
  default     = {}
}

variable "enable_bgp" {
  description = "Create the xcsh_bgp object. Defaults true, and nothing gates it: the object-ref name length blocker that once forced it false was removed in provider v3.74.0. Retained only as an escape hatch for planning or deploying the graph without BGP. See main.tf."
  type        = bool
  default     = true
}

variable "create_site" {
  description = "Create the xcsh_securemesh_site_v2 resource object. Set false when the site object is auto-provisioned by registration approval."
  type        = bool
  default     = true
}

variable "approve_registration" {
  description = "Approve the CE's runtime registration (named r-<uuid>, resolved from the site name by the xcsh_site_registration data source) instead of clicking Approve in the console. Two-phase by nature: the registration does not exist until the CE has booted and registered via the token, so the first apply plans no approval and a later apply creates it. For a CE that is ALREADY approved/ONLINE, import the existing approval (namespace/r-<uuid>, see the note in main.tf) rather than letting Terraform create it, since re-approving a non-NEW registration may be rejected. Set false to leave approval to an operator."
  type        = bool
  default     = true
}

variable "os_version" {
  description = "CE operating system version. Empty deliberately selects the server-advertised latest version; set a value only to reproduce an older build."
  type        = string
  default     = ""
}

variable "sw_version" {
  description = "CE F5 Distributed Cloud software version. Empty deliberately selects the server-advertised latest build; set a value only to reproduce an older build."
  type        = string
  default     = ""
}

variable "inside_nic_mac" {
  description = "Observed MAC of eth1/SLI; null before VM attachment."
  type        = string
  default     = null
}
variable "external_nic_mac" {
  description = "Observed MAC of eth2/external SLO; null before VM attachment."
  type        = string
  default     = null
}
