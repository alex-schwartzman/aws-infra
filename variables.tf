#############################
# Variable to edit
#############################
variable "targets" { #TODO Change me
  description = "Web URL of the DDOS target"
  default     = ["https://tinkoff.ru"]
}

variable "replicas" {
  description = "Number of parallel replicas to start"
  default     = 90
}

variable "region" {
  description = "Region where your EKS cluster will be created"
  default     = "eu-west-3"
}

variable "azs" {
  description = "Availability zones for the VPC used by EKS cluster"
  default = [
    "eu-west-3a",
    "eu-west-3b",
    "eu-west-3c"
  ]
}

#############################
# Don't edit variables below
#############################
variable "eks" {
  default = {
    cluster = {
      name               = "ukr"
      master_k8s_version = "1.21"
      cidr_block         = "10.1.0.0/16"
    }
    node_group = {
      dev = {
        name          = "main-pool"
        machine_count = 3
        machine_min   = 3
        machine_max   = 7
        machine_type  = "t3.large"
        capacity_type = "ON_DEMAND"
        k8s_version   = "1.21"
        taints        = ""
        labels        = { nodepool_selector = "main_nodepool" }
        tags          = {}
      }
    }
  }
}
