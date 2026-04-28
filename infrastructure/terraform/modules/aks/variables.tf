variable "prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "aks_subnet_id" { type = string }

variable "api_server_authorized_ip_ranges" {
  type        = list(string)
  description = "CIDR ranges allowed to reach the AKS API server. Add your machine IP as x.x.x.x/32."
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
