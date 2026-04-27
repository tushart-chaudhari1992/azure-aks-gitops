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
