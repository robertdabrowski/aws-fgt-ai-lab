variable "admin_cidr" {
  type        = string
  description = "IPv4 CIDR allowed to reach FortiGate administration on TCP/22 and TCP/443."

  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "Provide a valid IPv4 CIDR, for example your public address followed by /32."
  }
}

variable "fgt_key_name" {
  type        = string
  description = "Name of an existing EC2 key pair in eu-central-1."

  validation {
    condition     = trimspace(var.fgt_key_name) != ""
    error_message = "Provide an existing EC2 key pair name."
  }
}

variable "fgt_ami_id" {
  type        = string
  description = "FortiGate-VM x86_64 BYOL AMI in eu-central-1. The default is FortiOS 8.0.2 build0251."
  default     = "ami-0f87c9d117231cd4b"
}

variable "workload_ami_id" {
  type        = string
  description = "Optional Amazon Linux 2023 x86_64 AMI ID with Python 3 and SSM Agent. Otherwise use the AWS public AMI parameter."
  default     = null
}
