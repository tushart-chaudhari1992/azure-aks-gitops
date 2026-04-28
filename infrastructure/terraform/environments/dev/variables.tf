variable "prefix" {
  type    = string
  default = "boutique-dev"
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "ci_service_principal_object_id" {
  type        = string
  description = "Object ID of the service principal used by CI pipelines."
}

variable "api_server_authorized_ip_ranges" {
  type        = list(string)
  description = "CIDR ranges allowed to reach the AKS API server. Set in terraform.tfvars per developer."
}
