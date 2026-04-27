variable "prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "aks_kubelet_identity_object_id" { type = string }
variable "vnet_id" { type = string }
variable "pe_subnet_id" { type = string }

variable "sku" {
  type    = string
  default = "Basic"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "public_network_access_enabled" {
  type        = bool
  default     = false
  description = "Allow public internet access to ACR. False = private endpoint only. Enable for dev so GitHub-hosted runners can push images."
}
