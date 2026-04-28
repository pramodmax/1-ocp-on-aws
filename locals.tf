data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Use provided AZs or auto-select up to 3 from the region
  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names, 0,
    min(3, length(data.aws_availability_zones.available.names))
  )

  # Installation directory — preserved between runs, contains kubeconfig and auth
  install_dir = "${path.module}/clusters/${var.cluster_name}"

  # Sentinel file written by installer on success
  install_complete_marker = "${local.install_dir}/.install-complete"

  # URLs derived from cluster identity
  api_url     = "https://api.${var.cluster_name}.${var.base_domain}:6443"
  console_url = "https://console-openshift-console.apps.${var.cluster_name}.${var.base_domain}"
}
