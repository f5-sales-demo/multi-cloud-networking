variable "name" {
  description = "Test client VM name; every child resource derives from it (<name>PublicIP, <name>NSG, <name>VMNic). REQUIRED, deliberately without a default: the root passes a value derived from var.component, so no deployment-specific name can hide in a module default."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group (created by the hub module)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "subnet_id" {
  description = "snet-hub-internal subnet ID the client attaches to."
  type        = string
}

variable "vm_size" {
  description = "VM size."
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "SSH admin username."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key MATERIAL (string), passed down from the root."
  type        = string
}

variable "custom_data" {
  description = "Base64-encoded cloud-init custom data."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "serve_http" {
  description = "Allow public HTTP only for the opt-in disposable origin."
  type        = bool
  default     = false
}

variable "allow_ssh" {
  type        = bool
  description = "Allow SSH for test clients; the origin uses Azure Run Command instead."
  default     = true
}
variable "restrict_ingress" {
  type        = bool
  description = "Deny unlisted origin ingress before Azure default rules."
  default     = false
}
variable "http_source_cidrs" {
  type        = list(string)
  description = "Explicit HTTP source networks for the disposable origin."
  default     = []
  validation {
    condition     = alltrue([for cidr in var.http_source_cidrs : can(cidrhost(cidr, 0)) && !contains(["0.0.0.0/0", "::/0"], cidr)])
    error_message = "HTTP origin sources must be valid CIDRs and cannot allow the whole Internet."
  }
}
