variable "prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "aks_subnet_id" { type = string }

variable "private_cluster_enabled" {
  type        = bool
  default     = true
  description = "Disable for dev to allow direct kubectl access. Keep true for prod."
}

variable "api_server_authorized_ip_ranges" {
  type        = list(string)
  default     = []
  description = "CIDR ranges allowed to reach the AKS API server. Only used when private_cluster_enabled = false."
}

variable "kubernetes_version" {
  type    = string
  default = "1.34"
}

variable "user_node_vm_size" {
  type    = string
  default = "Standard_D2s_v3"
}

variable "user_node_count" {
  type    = number
  default = 1
}

variable "tags" {
  type    = map(string)
  default = {}
}
