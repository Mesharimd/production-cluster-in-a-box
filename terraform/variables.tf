variable "aws_profile" {
  description = "Name of the locally configured AWS CLI profile Terraform should use."
  type        = string

  validation {
    condition     = length(trimspace(var.aws_profile)) > 0
    error_message = "aws_profile must name a locally configured AWS CLI profile."
  }
}

variable "region" {
  description = "AWS region in which to create the cluster."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = length(trimspace(var.region)) > 0
    error_message = "region must not be empty."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the single-node k3s server."
  type        = string
  default     = "c7i-flex.large"

  validation {
    condition     = length(trimspace(var.instance_type)) > 0
    error_message = "instance_type must not be empty."
  }
}

variable "ssh_public_key" {
  description = "Local path to the SSH public key Terraform will register with EC2."
  type        = string

  validation {
    condition = (
      length(trimspace(var.ssh_public_key)) > 0 &&
      endswith(trimspace(var.ssh_public_key), ".pub")
    )
    error_message = "ssh_public_key must point to a local public-key file ending in .pub."
  }
}

variable "ssh_ingress_cidr" {
  description = "IPv4 CIDR allowed to reach SSH. Restrict this to your current public IP with a /32 suffix."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrnetmask(var.ssh_ingress_cidr))
    error_message = "ssh_ingress_cidr must be a valid IPv4 CIDR."
  }
}
