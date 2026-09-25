variable "name" { type = string }
variable "namespace" { type = string }
variable "site_names" { type = list(string) }
variable "domain" { type = string }
variable "vip" { type = string }
variable "origin_pool_name" { type = string }
variable "labels" { type = map(string) }
