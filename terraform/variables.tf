# General variables. Domain-specific inputs live in variables_azure.tf,
# variables_xc.tf and variables_ce.tf.

variable "source_repository" {
  description = "Canonical GitHub repository identity of the reviewed source. Only this repository can produce a deployment identity."
  type        = string

  validation {
    condition     = var.source_repository == "f5-sales-demo/multi-cloud-networking"
    error_message = "source_repository must be exactly f5-sales-demo/multi-cloud-networking."
  }
}

variable "source_ref" {
  description = "Exact trusted branch ref of the reviewed source. PR merge refs and abbreviated branch names are rejected."
  type        = string

  validation {
    condition = (
      can(regex("^refs/heads/[^[:cntrl:][:space:]~^:?*\\\\\\[]+$", var.source_ref)) &&
      !strcontains(var.source_ref, "..") &&
      !strcontains(var.source_ref, "@{") &&
      !strcontains(var.source_ref, "//") &&
      !can(regex("(^refs/heads/|/)\\.", var.source_ref)) &&
      !can(regex("(\\.|\\.lock)(/|$)", var.source_ref)) &&
      var.source_ref != "refs/heads/@" &&
      !endswith(var.source_ref, "/")
    )
    error_message = "source_ref must be a valid exact refs/heads/* ref, never refs/pull/* or an abbreviated branch."
  }
}

variable "source_commit_sha" {
  description = "Immutable lowercase 40-hex commit that was reviewed and used to create the saved plan."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.source_commit_sha))
    error_message = "source_commit_sha must be an immutable lowercase 40-hex Git commit."
  }
}

variable "deployment_owner_id" {
  description = "Non-personal stable identifier for the team or service that owns the deployment."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,62}$", var.deployment_owner_id))
    error_message = "deployment_owner_id must be a 3-63 character lowercase non-personal identifier."
  }
}

variable "deployment_actor_id" {
  description = "Non-personal stable identifier for the automation actor that applies the deployment."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,62}$", var.deployment_actor_id))
    error_message = "deployment_actor_id must be a 3-63 character lowercase non-personal identifier."
  }
}

variable "component" {
  description = "Component name used in tags."
  type        = string
  default     = "mcn-ce-ha"
}

variable "environment" {
  description = "Environment label used in tags."
  type        = string
  default     = "lab"
}

variable "deployer" {
  description = "Override for the deployer identifier used in tags (auto-resolved from Azure AD when empty)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags merged with the standard tags (component/environment/deployer/managed_by)."
  type        = map(string)
  default     = {}
}

variable "enable_kvm" {
  description = "Enable the local KVM/libvirt SMSv2 site. Set false for a KVM-only destroy or when the tenant-owned KVM image prerequisite is unavailable; no KVM image lookup occurs while disabled."
  type        = bool
  default     = false
}

variable "kvm_software_version" {
  description = "F5XC software installed during the KVM CE's first boot. This is pinned explicitly so a fresh install does not consume an unqualified tenant default release."
  type        = string
  default     = "crt-20260801-0205"
  nullable    = false

  validation {
    condition     = can(regex("^crt-[0-9]{8}-[0-9]{4}$", var.kvm_software_version))
    error_message = "kvm_software_version must be an explicit F5XC software build such as crt-20260801-0205."
  }
}

variable "aws_origin_dns_name" {
  description = "DNS name of the public HTTP origin for the AWS SMSv2 load balancer."
  type        = string
  default     = "httpbin.org"
  nullable    = false

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.aws_origin_dns_name))
    error_message = "aws_origin_dns_name must be a fully-qualified lowercase DNS name."
  }
}
