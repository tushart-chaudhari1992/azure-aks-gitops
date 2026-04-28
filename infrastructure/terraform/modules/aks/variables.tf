variable "prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "aks_subnet_id" { type = string }

variable "kubernetes_version" {
  type    = string
  default = "1.34"
}

variable "user_node_vm_size" {
  type    = string
  default = "Standard_D4s_v3"
}

variable "user_node_count" {
  type    = number
  default = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}
