# ─── Installation Directory ───────────────────────────────────────────────────

resource "null_resource" "install_dir" {
  provisioner "local-exec" {
    command = "mkdir -p ${local.install_dir}"
  }

  triggers = {
    cluster_name = var.cluster_name
  }
}

# ─── Install Config ───────────────────────────────────────────────────────────

resource "local_sensitive_file" "install_config" {
  depends_on = [null_resource.install_dir]

  content = templatefile("${path.module}/templates/install-config.yaml.tpl", {
    cluster_name                = var.cluster_name
    base_domain                 = var.base_domain
    aws_region                  = var.aws_region
    availability_zones          = local.availability_zones
    master_count                = var.master_count
    master_instance_type        = var.master_instance_type
    master_root_volume_size     = var.master_root_volume_size
    worker_count                = var.worker_count
    worker_instance_type        = var.worker_instance_type
    worker_root_volume_size     = var.worker_root_volume_size
    root_volume_type            = var.root_volume_type
    cluster_network_cidr        = var.cluster_network_cidr
    cluster_network_host_prefix = var.cluster_network_host_prefix
    machine_network_cidr        = var.machine_network_cidr
    service_network_cidr        = var.service_network_cidr
    network_type                = var.network_type
    publish                     = var.publish
    fips_enabled                = var.fips_enabled
    pull_secret                 = var.pull_secret
    ssh_public_key              = var.ssh_public_key
  })

  filename        = "${local.install_dir}/install-config.yaml"
  file_permission = "0600"
}

# ─── Pre-flight Check ─────────────────────────────────────────────────────────

resource "null_resource" "preflight_check" {
  depends_on = [local_sensitive_file.install_config]

  provisioner "local-exec" {
    command = "${path.module}/scripts/preflight.sh"
    environment = {
      CLUSTER_NAME   = var.cluster_name
      BASE_DOMAIN    = var.base_domain
      AWS_REGION     = var.aws_region
      MASTER_COUNT   = var.master_count
      WORKER_COUNT   = var.worker_count
      MASTER_TYPE    = var.master_instance_type
      WORKER_TYPE    = var.worker_instance_type
      INSTALL_DIR    = local.install_dir
    }
  }

  triggers = {
    install_config_hash = local_sensitive_file.install_config.content_md5
  }
}

# ─── Cluster Installation ─────────────────────────────────────────────────────

resource "null_resource" "install_cluster" {
  depends_on = [null_resource.preflight_check]

  provisioner "local-exec" {
    command = <<-EOT
      set -e

      # Skip if cluster already installed
      if [ -f "${local.install_complete_marker}" ]; then
        echo "Cluster ${var.cluster_name} is already installed. Skipping."
        exit 0
      fi

      echo ""
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║          OpenShift Cluster Installation Starting             ║"
      echo "╠══════════════════════════════════════════════════════════════╣"
      printf "║  Cluster   : %-48s ║\n" "${var.cluster_name}.${var.base_domain}"
      printf "║  Region    : %-48s ║\n" "${var.aws_region}"
      printf "║  Masters   : %-2s x %-43s ║\n" "${var.master_count}" "${var.master_instance_type}"
      printf "║  Workers   : %-2s x %-43s ║\n" "${var.worker_count}" "${var.worker_instance_type}"
      printf "║  Network   : %-48s ║\n" "${var.network_type}"
      printf "║  Publish   : %-48s ║\n" "${var.publish}"
      echo "╚══════════════════════════════════════════════════════════════╝"
      echo ""
      echo "  Estimated time: 30-45 minutes"
      echo "  Log: ${local.install_dir}/.openshift_install.log"
      echo ""

      openshift-install create cluster \
        --dir="${local.install_dir}" \
        --log-level=info

      EXIT_CODE=$?

      if [ $EXIT_CODE -eq 0 ]; then
        # Write sentinel file so re-applies don't re-install
        touch "${local.install_complete_marker}"

        KUBEADMIN_PASSWORD=$(cat "${local.install_dir}/auth/kubeadmin-password" 2>/dev/null || echo "N/A")

        echo ""
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║              Installation Complete!                         ║"
        echo "╠══════════════════════════════════════════════════════════════╣"
        printf "║  Console : %-50s ║\n" "${local.console_url}"
        printf "║  API     : %-50s ║\n" "${local.api_url}"
        echo "╠══════════════════════════════════════════════════════════════╣"
        printf "║  Username: %-50s ║\n" "kubeadmin"
        printf "║  Password: %-50s ║\n" "$KUBEADMIN_PASSWORD"
        echo "╠══════════════════════════════════════════════════════════════╣"
        printf "║  kubeconfig: %-48s ║\n" "${local.install_dir}/auth/kubeconfig"
        echo "╚══════════════════════════════════════════════════════════════╝"
        echo ""
        echo "  Run: export KUBECONFIG=${local.install_dir}/auth/kubeconfig"
        echo "  Run: oc get nodes"
        echo ""
      else
        echo "Installation failed with exit code $EXIT_CODE"
        echo "Check full log: ${local.install_dir}/.openshift_install.log"
        exit $EXIT_CODE
      fi
    EOT
  }

  triggers = {
    preflight_id = null_resource.preflight_check.id
  }
}

# ─── Tail Installer Log (progress in a second terminal) ──────────────────────
#
# To stream live install progress in another terminal window, run:
#   tail -f clusters/<cluster-name>/.openshift_install.log
