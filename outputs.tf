output "cluster_name" {
  description = "Name of the OpenShift cluster."
  value       = var.cluster_name
}

output "console_url" {
  description = "OpenShift web console URL."
  value       = local.console_url
  depends_on  = [null_resource.install_cluster]
}

output "api_url" {
  description = "OpenShift API server URL."
  value       = local.api_url
  depends_on  = [null_resource.install_cluster]
}

output "kubeconfig_path" {
  description = "Absolute path to the kubeconfig file. Use with: export KUBECONFIG=<value>"
  value       = "${abspath(local.install_dir)}/auth/kubeconfig"
  depends_on  = [null_resource.install_cluster]
}

output "kubeadmin_password" {
  description = "kubeadmin password for the web console. Run: terraform output -raw kubeadmin_password"
  value       = fileexists("${local.install_dir}/auth/kubeadmin-password") ? file("${local.install_dir}/auth/kubeadmin-password") : "Not yet available"
  sensitive   = true
  depends_on  = [null_resource.install_cluster]
}

output "login_command" {
  description = "oc login command to authenticate to the cluster."
  value       = "oc login ${local.api_url} -u kubeadmin -p $(terraform output -raw kubeadmin_password)"
  depends_on  = [null_resource.install_cluster]
}

output "cluster_summary" {
  description = "Summary of the deployed cluster configuration."
  value = {
    cluster_name         = var.cluster_name
    base_domain          = var.base_domain
    aws_region           = var.aws_region
    availability_zones   = local.availability_zones
    ocp_version          = var.ocp_version
    master_count         = var.master_count
    master_instance_type = var.master_instance_type
    worker_count         = var.worker_count
    worker_instance_type = var.worker_instance_type
    network_type         = var.network_type
    publish              = var.publish
    fips_enabled         = var.fips_enabled
  }
  depends_on = [null_resource.install_cluster]
}
