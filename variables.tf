# ─── Cluster Identity ────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the OpenShift cluster. Used as prefix for all AWS resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,26}[a-z0-9]$", var.cluster_name))
    error_message = "Cluster name must be 3-28 characters, lowercase alphanumeric and hyphens only."
  }
}

variable "base_domain" {
  description = "Base DNS domain for the cluster (e.g. example.com). A Route53 public hosted zone must exist."
  type        = string
}

variable "ocp_version" {
  description = "OpenShift version to install (e.g. 4.16.3). Must match a released version."
  type        = string
  default     = "4.16.3"
}

# ─── AWS Configuration ───────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region where the cluster will be deployed."
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "List of AWS availability zones. Leave empty to auto-select from the region."
  type        = list(string)
  default     = []
}

# ─── Control Plane (Master Nodes) ────────────────────────────────────────────

variable "master_count" {
  description = <<-EOT
    Number of control plane (master) nodes.
    - 1 = Single-node (non-HA, for dev/test only)
    - 3 = Standard HA (recommended for production)
  EOT
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3], var.master_count)
    error_message = "master_count must be 1 (non-HA) or 3 (HA)."
  }
}

variable "master_instance_type" {
  description = <<-EOT
    EC2 instance type for master nodes.
    Recommended minimum: m5.xlarge (4 vCPU, 16 GB RAM)
    Production recommendation: m5.2xlarge or m6i.2xlarge
  EOT
  type        = string
  default     = "m5.xlarge"

  validation {
    condition = contains([
      "m5.xlarge", "m5.2xlarge", "m5.4xlarge", "m5.8xlarge",
      "m6i.xlarge", "m6i.2xlarge", "m6i.4xlarge",
      "m6a.xlarge", "m6a.2xlarge", "m6a.4xlarge",
      "c5.2xlarge", "c5.4xlarge",
      "r5.xlarge", "r5.2xlarge"
    ], var.master_instance_type)
    error_message = "Invalid master instance type. See variable description for supported types."
  }
}

# ─── Compute (Worker Nodes) ───────────────────────────────────────────────────

variable "worker_count" {
  description = <<-EOT
    Number of worker (compute) nodes.
    Minimum 2 required. Recommend 3+ for production workloads.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.worker_count >= 2
    error_message = "worker_count must be at least 2."
  }
}

variable "worker_instance_type" {
  description = <<-EOT
    EC2 instance type for worker nodes.
    Choose based on workload profile:
    - General purpose: m5.large / m5.xlarge / m6i.large
    - Compute intensive: c5.xlarge / c5.2xlarge
    - Memory intensive: r5.xlarge / r5.2xlarge
  EOT
  type        = string
  default     = "m5.large"

  validation {
    condition = contains([
      "m5.large", "m5.xlarge", "m5.2xlarge", "m5.4xlarge",
      "m6i.large", "m6i.xlarge", "m6i.2xlarge", "m6i.4xlarge",
      "m6a.large", "m6a.xlarge", "m6a.2xlarge",
      "c5.xlarge", "c5.2xlarge", "c5.4xlarge",
      "r5.large", "r5.xlarge", "r5.2xlarge",
      "g4dn.xlarge", "g4dn.2xlarge"
    ], var.worker_instance_type)
    error_message = "Invalid worker instance type. See variable description for supported types."
  }
}

# ─── Authentication & Access ──────────────────────────────────────────────────

variable "pull_secret" {
  description = <<-EOT
    Red Hat pull secret JSON. Obtain from https://console.redhat.com/openshift/install/pull-secret.
    Store securely — do not commit to source control.
  EOT
  type      = string
  sensitive = true
}

variable "ssh_public_key" {
  description = "SSH public key for node access (contents of your ~/.ssh/id_rsa.pub or similar)."
  type        = string
  sensitive   = true
}

# ─── Networking ───────────────────────────────────────────────────────────────

variable "cluster_network_cidr" {
  description = "CIDR for pod networking inside the cluster."
  type        = string
  default     = "10.128.0.0/14"
}

variable "cluster_network_host_prefix" {
  description = "Subnet prefix length for each node's pod subnet."
  type        = number
  default     = 23
}

variable "machine_network_cidr" {
  description = "CIDR for the VPC/machine network."
  type        = string
  default     = "10.0.0.0/16"
}

variable "service_network_cidr" {
  description = "CIDR for OpenShift services."
  type        = string
  default     = "172.30.0.0/16"
}

variable "network_type" {
  description = "CNI plugin. OVNKubernetes is the modern default."
  type        = string
  default     = "OVNKubernetes"

  validation {
    condition     = contains(["OVNKubernetes", "OpenShiftSDN"], var.network_type)
    error_message = "network_type must be OVNKubernetes or OpenShiftSDN."
  }
}

# ─── Publish Strategy ─────────────────────────────────────────────────────────

variable "publish" {
  description = "API and console publish strategy. External = public internet. Internal = private VPC only."
  type        = string
  default     = "External"

  validation {
    condition     = contains(["External", "Internal"], var.publish)
    error_message = "publish must be External or Internal."
  }
}

# ─── Disk Configuration ───────────────────────────────────────────────────────

variable "master_root_volume_size" {
  description = "Root volume size in GB for master nodes."
  type        = number
  default     = 120
}

variable "worker_root_volume_size" {
  description = "Root volume size in GB for worker nodes."
  type        = number
  default     = 120
}

variable "root_volume_type" {
  description = "EBS volume type for all nodes."
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp2", "gp3", "io1", "io2"], var.root_volume_type)
    error_message = "root_volume_type must be gp2, gp3, io1, or io2."
  }
}

# ─── FIPS ─────────────────────────────────────────────────────────────────────

variable "fips_enabled" {
  description = "Enable FIPS 140-2 mode. Required for US government compliance."
  type        = bool
  default     = false
}
