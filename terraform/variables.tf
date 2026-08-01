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

variable "etcd_snapshot_schedule_cron" {
  description = "Cron schedule used by k3s for recurring embedded-etcd snapshots."
  type        = string
  default     = "0 3 * * *"

  validation {
    condition     = length(trimspace(var.etcd_snapshot_schedule_cron)) > 0
    error_message = "etcd_snapshot_schedule_cron must not be empty."
  }
}

variable "etcd_snapshot_retention" {
  description = "Number of scheduled embedded-etcd snapshots retained locally and in R2."
  type        = number
  default     = 7

  validation {
    condition = (
      var.etcd_snapshot_retention >= 1 &&
      floor(var.etcd_snapshot_retention) == var.etcd_snapshot_retention
    )
    error_message = "etcd_snapshot_retention must be a positive whole number."
  }
}

variable "r2_endpoint" {
  description = "Cloudflare R2 S3 endpoint hostname without an https:// prefix."
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(trimspace(var.r2_endpoint)) > 0 &&
      !can(regex("^https?://", trimspace(var.r2_endpoint)))
    )
    error_message = "r2_endpoint must be a non-empty hostname without an http:// or https:// prefix."
  }
}

variable "r2_bucket" {
  description = "Name of the operator-created Cloudflare R2 bucket used for etcd snapshots."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.r2_bucket)) > 0
    error_message = "r2_bucket must not be empty."
  }
}

variable "r2_region" {
  description = "S3 signing region used by Cloudflare R2."
  type        = string
  default     = "auto"

  validation {
    condition     = trimspace(var.r2_region) == "auto"
    error_message = "r2_region must be auto for Cloudflare R2."
  }
}

variable "r2_access_key_id" {
  description = "Cloudflare R2 S3 Access Key ID. Stored only in ignored tfvars, Terraform state, EC2 user data, and the root-only k3s config."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.r2_access_key_id)) > 0
    error_message = "r2_access_key_id must not be empty."
  }
}

variable "r2_secret_access_key" {
  description = "Cloudflare R2 S3 Secret Access Key. Stored only in ignored tfvars, Terraform state, EC2 user data, and the root-only k3s config."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.r2_secret_access_key)) > 0
    error_message = "r2_secret_access_key must not be empty."
  }
}
