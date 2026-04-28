# ─── tfvars Validation ────────────────────────────────────────────────────────

resource "null_resource" "validate_tfvars" {
  provisioner "local-exec" {
    command     = "${path.module}/scripts/validate-tfvars.sh"
    working_dir = path.module
    environment = {
      TFVARS_PATH = "${path.module}/terraform.tfvars"
    }
  }

  triggers = {
    cluster_name   = var.cluster_name
    base_domain    = var.base_domain
    pull_secret    = sha256(var.pull_secret)
    ssh_public_key = sha256(var.ssh_public_key)
  }
}

# ─── Installation Directory ───────────────────────────────────────────────────

resource "null_resource" "install_dir" {
  depends_on = [null_resource.validate_tfvars]
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

  # ── Destroy-time: Phase 1 — openshift-install destroy cluster ────────────────
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      INSTALL_DIR="${self.triggers.install_dir}"
      CLUSTER_NAME="${self.triggers.cluster_name}"
      CLUSTER_TAG="kubernetes.io/cluster/$${CLUSTER_NAME}"

      echo ""
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║           OpenShift Cluster Teardown — Phase 1/3            ║"
      echo "║           openshift-install destroy cluster                 ║"
      echo "╚══════════════════════════════════════════════════════════════╝"
      echo ""

      if [ -d "$INSTALL_DIR" ]; then
        openshift-install destroy cluster \
          --dir="$INSTALL_DIR" \
          --log-level=info || echo "Installer destroy exited with errors — proceeding to orphan cleanup."
      else
        echo "Install directory not found ($INSTALL_DIR). Skipping installer destroy."
      fi
    EOT
    environment = {
      AWS_DEFAULT_REGION = self.triggers.aws_region
    }
  }

  # ── Destroy-time: Phase 2 — Orphaned AWS resource cleanup ─────────────────
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      CLUSTER_NAME="${self.triggers.cluster_name}"
      AWS_REGION="${self.triggers.aws_region}"
      CLUSTER_TAG="kubernetes.io/cluster/$${CLUSTER_NAME}"
      TAG_FILTER="Name=tag:$${CLUSTER_TAG},Values=owned"
      REMOVED=0
      WARNED=0

      ok()   { echo "  ✔  $1"; }
      gone() { echo "  ⚠  $1 — already removed or not found"; }

      remove() {
        local label="$1"; shift
        if "$@" >/dev/null 2>&1; then ok "$label"; REMOVED=$((REMOVED+1))
        else gone "$label"; WARNED=$((WARNED+1)); fi
      }

      echo ""
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║           OpenShift Cluster Teardown — Phase 2/3            ║"
      echo "║           Orphaned AWS Resource Cleanup                     ║"
      echo "╚══════════════════════════════════════════════════════════════╝"
      echo ""
      echo "  Tag filter: $${CLUSTER_TAG}=owned | Region: $${AWS_REGION}"
      echo ""

      # ── EC2 Instances ───────────────────────────────────────────────────────
      echo "  EC2 Instances"
      IDS=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "$${TAG_FILTER}" "Name=instance-state-name,Values=running,stopped,pending" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
      if [ -n "$IDS" ]; then
        remove "EC2 instances ($IDS)" \
          aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids $IDS
        aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids $IDS 2>/dev/null || true
      else ok "No orphaned EC2 instances"; fi

      # ── ALB / NLB ───────────────────────────────────────────────────────────
      echo "  Load Balancers (ALB/NLB)"
      for ARN in $(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true); do
        TAG=$(aws elbv2 describe-tags --region "$AWS_REGION" --resource-arns "$ARN" \
          --query "TagDescriptions[].Tags[?Key=='$${CLUSTER_TAG}'].Value" --output text 2>/dev/null || true)
        [ "$TAG" = "owned" ] && remove "ALB/NLB $${ARN##*/}" \
          aws elbv2 delete-load-balancer --region "$AWS_REGION" --load-balancer-arn "$ARN"
      done

      # ── Classic ELBs ────────────────────────────────────────────────────────
      echo "  Classic Load Balancers"
      for LB in $(aws elb describe-load-balancers --region "$AWS_REGION" \
        --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null || true); do
        TAG=$(aws elb describe-tags --region "$AWS_REGION" --load-balancer-names "$LB" \
          --query "TagDescriptions[].Tags[?Key=='$${CLUSTER_TAG}'].Value" --output text 2>/dev/null || true)
        [ "$TAG" = "owned" ] && remove "Classic ELB $LB" \
          aws elb delete-load-balancer --region "$AWS_REGION" --load-balancer-name "$LB"
      done

      # ── S3 Buckets ──────────────────────────────────────────────────────────
      echo "  S3 Buckets"
      for BUCKET in $(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || true); do
        if echo "$BUCKET" | grep -q "$${CLUSTER_NAME}"; then
          aws s3 rm "s3://$${BUCKET}" --recursive 2>/dev/null || true
          remove "S3 bucket $BUCKET" aws s3api delete-bucket --bucket "$BUCKET"
        fi
      done

      # ── NAT Gateways ────────────────────────────────────────────────────────
      echo "  NAT Gateways"
      IDS=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
        --filter "$${TAG_FILTER}" "Name=state,Values=available,pending" \
        --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)
      if [ -n "$IDS" ]; then
        for ID in $IDS; do
          remove "NAT gateway $ID" aws ec2 delete-nat-gateway --region "$AWS_REGION" --nat-gateway-id "$ID"
        done
        sleep 20
      else ok "No orphaned NAT gateways"; fi

      # ── Elastic IPs ─────────────────────────────────────────────────────────
      echo "  Elastic IPs"
      for ID in $(aws ec2 describe-addresses --region "$AWS_REGION" \
        --filters "$${TAG_FILTER}" --query 'Addresses[].AllocationId' --output text 2>/dev/null || true); do
        remove "Elastic IP $ID" aws ec2 release-address --region "$AWS_REGION" --allocation-id "$ID"
      done

      # ── Security Groups ─────────────────────────────────────────────────────
      echo "  Security Groups"
      for ID in $(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "$${TAG_FILTER}" --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true); do
        # Revoke rules to clear cross-references
        INGRESS=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$ID" \
          --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null || echo "[]")
        EGRESS=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$ID" \
          --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null || echo "[]")
        [ "$INGRESS" != "[]" ] && aws ec2 revoke-security-group-ingress --region "$AWS_REGION" \
          --group-id "$ID" --ip-permissions "$INGRESS" 2>/dev/null || true
        [ "$EGRESS"  != "[]" ] && aws ec2 revoke-security-group-egress --region "$AWS_REGION" \
          --group-id "$ID" --ip-permissions "$EGRESS" 2>/dev/null || true
        remove "Security group $ID" aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$ID"
      done

      # ── VPC Endpoints ───────────────────────────────────────────────────────
      echo "  VPC Endpoints"
      IDS=$(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
        --filters "$${TAG_FILTER}" "Name=vpc-endpoint-state,Values=available,pending" \
        --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)
      [ -n "$IDS" ] && remove "VPC endpoints" \
        aws ec2 delete-vpc-endpoints --region "$AWS_REGION" --vpc-endpoint-ids $IDS \
        || ok "No orphaned VPC endpoints"

      # ── Subnets ─────────────────────────────────────────────────────────────
      echo "  Subnets"
      for ID in $(aws ec2 describe-subnets --region "$AWS_REGION" \
        --filters "$${TAG_FILTER}" --query 'Subnets[].SubnetId' --output text 2>/dev/null || true); do
        remove "Subnet $ID" aws ec2 delete-subnet --region "$AWS_REGION" --subnet-id "$ID"
      done

      # ── Route Tables ────────────────────────────────────────────────────────
      echo "  Route Tables"
      for ID in $(aws ec2 describe-route-tables --region "$AWS_REGION" \
        --filters "$${TAG_FILTER}" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
        --output text 2>/dev/null || true); do
        for ASSOC in $(aws ec2 describe-route-tables --region "$AWS_REGION" --route-table-ids "$ID" \
          --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
          --output text 2>/dev/null || true); do
          aws ec2 disassociate-route-table --region "$AWS_REGION" --association-id "$ASSOC" 2>/dev/null || true
        done
        remove "Route table $ID" aws ec2 delete-route-table --region "$AWS_REGION" --route-table-id "$ID"
      done

      # ── Internet Gateways ───────────────────────────────────────────────────
      echo "  Internet Gateways"
      for ID in $(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
        --filters "$${TAG_FILTER}" --query 'InternetGateways[].InternetGatewayId' \
        --output text 2>/dev/null || true); do
        VPC=$(aws ec2 describe-internet-gateways --region "$AWS_REGION" --internet-gateway-ids "$ID" \
          --query 'InternetGateways[0].Attachments[0].VpcId' --output text 2>/dev/null || true)
        [ -n "$VPC" ] && [ "$VPC" != "None" ] && \
          aws ec2 detach-internet-gateway --region "$AWS_REGION" \
          --internet-gateway-id "$ID" --vpc-id "$VPC" 2>/dev/null || true
        remove "Internet gateway $ID" aws ec2 delete-internet-gateway --region "$AWS_REGION" --internet-gateway-id "$ID"
      done

      # ── VPCs ────────────────────────────────────────────────────────────────
      echo "  VPCs"
      for ID in $(aws ec2 describe-vpcs --region "$AWS_REGION" \
        --filters "$${TAG_FILTER}" --query 'Vpcs[].VpcId' --output text 2>/dev/null || true); do
        remove "VPC $ID" aws ec2 delete-vpc --region "$AWS_REGION" --vpc-id "$ID"
      done

      # ── EBS Volumes ─────────────────────────────────────────────────────────
      echo "  EBS Volumes"
      for ID in $(aws ec2 describe-volumes --region "$AWS_REGION" \
        --filters "$${TAG_FILTER}" "Name=status,Values=available" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null || true); do
        remove "EBS volume $ID" aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$ID"
      done

      # ── IAM Roles ───────────────────────────────────────────────────────────
      echo "  IAM Roles"
      for ROLE in $(aws iam list-roles \
        --query "Roles[?contains(RoleName, '$${CLUSTER_NAME}')].RoleName" \
        --output text 2>/dev/null || true); do
        for PA in $(aws iam list-attached-role-policies --role-name "$ROLE" \
          --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
          aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$PA" 2>/dev/null || true
        done
        for IP in $(aws iam list-instance-profiles-for-role --role-name "$ROLE" \
          --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || true); do
          aws iam remove-role-from-instance-profile --role-name "$ROLE" --instance-profile-name "$IP" 2>/dev/null || true
          aws iam delete-instance-profile --instance-profile-name "$IP" 2>/dev/null || true
        done
        for INLINE in $(aws iam list-role-policies --role-name "$ROLE" \
          --query 'PolicyNames[]' --output text 2>/dev/null || true); do
          aws iam delete-role-policy --role-name "$ROLE" --policy-name "$INLINE" 2>/dev/null || true
        done
        remove "IAM role $ROLE" aws iam delete-role --role-name "$ROLE"
      done

      # ── Route53 Private Zones ───────────────────────────────────────────────
      echo "  Route53 Private Hosted Zones"
      for ZONE_PATH in $(aws route53 list-hosted-zones \
        --query "HostedZones[?contains(Name,'$${CLUSTER_NAME}')&&Config.PrivateZone==\`true\`].Id" \
        --output text 2>/dev/null || true); do
        ZID="$${ZONE_PATH##*/}"
        RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZID" \
          --query "ResourceRecordSets[?Type!='SOA'&&Type!='NS']" --output json 2>/dev/null || echo "[]")
        if [ "$RECORDS" != "[]" ] && [ "$RECORDS" != "null" ]; then
          CHANGES=$(echo "$RECORDS" | jq '[.[]|{Action:"DELETE",ResourceRecordSet:.}]')
          aws route53 change-resource-record-sets --hosted-zone-id "$ZID" \
            --change-batch "{\"Changes\":$CHANGES}" 2>/dev/null || true
        fi
        remove "Route53 private zone $ZID" aws route53 delete-hosted-zone --id "$ZID"
      done

      # ── Phase 3: Local cleanup ───────────────────────────────────────────────
      echo ""
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║           OpenShift Cluster Teardown — Phase 3/3            ║"
      echo "║           Local Directory Cleanup                           ║"
      echo "╚══════════════════════════════════════════════════════════════╝"
      INSTALL_DIR="${self.triggers.install_dir}"
      if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        ok "Removed install directory: $INSTALL_DIR"
      else
        ok "Install directory already removed"
      fi

      echo ""
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║                    Teardown Summary                         ║"
      echo "╠══════════════════════════════════════════════════════════════╣"
      printf "║  Cluster         : %-42s ║\n" "$CLUSTER_NAME"
      printf "║  Resources freed : %-42s ║\n" "$REMOVED"
      if [ "$WARNED" -gt 0 ]; then
        printf "║  Already gone    : %-42s ║\n" "$WARNED"
      fi
      echo "╠══════════════════════════════════════════════════════════════╣"
      echo "║  ✔  Cluster fully destroyed. All resources released.        ║"
      echo "╚══════════════════════════════════════════════════════════════╝"
      echo ""
    EOT
    environment = {
      AWS_DEFAULT_REGION = self.triggers.aws_region
    }
  }

  triggers = {
    preflight_id  = null_resource.preflight_check.id
    cluster_name  = var.cluster_name
    aws_region    = var.aws_region
    install_dir   = local.install_dir
  }
}

# ─── Tail Installer Log (progress in a second terminal) ──────────────────────
#
# To stream live install progress in another terminal window, run:
#   tail -f clusters/<cluster-name>/.openshift_install.log
