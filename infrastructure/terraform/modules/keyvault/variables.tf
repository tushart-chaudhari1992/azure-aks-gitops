variable "prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "vnet_id" { type = string }
variable "pe_subnet_id" { type = string }
variable "ci_service_principal_object_id" { type = string }

variable "workload_identity_object_ids" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
