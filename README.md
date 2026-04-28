# OpenShift on AWS — Terraform (IPI)

Terraform wrapper for deploying a Red Hat OpenShift Container Platform cluster on AWS using the **Installer Provisioned Infrastructure (IPI)** method. Exposes the most commonly tuned parameters — master count, worker count, and instance types — while keeping everything else sensible by default.

---

## Prerequisites

| Tool | Minimum Version | Install |
|------|----------------|---------|
| `terraform` | 1.5.0 | https://developer.hashicorp.com/terraform/install |
| `openshift-install` | 4.14+ | https://mirror.openshift.com/pub/openshift-v4/clients/ocp/ |
| `oc` | 4.14+ | https://mirror.openshift.com/pub/openshift-v4/clients/ocp/ |
| `aws` CLI | 2.x | https://aws.amazon.com/cli/ |
| `jq` | 1.6+ | https://jqlang.github.io/jq/ |

### AWS Requirements

- IAM user or role with [OpenShift IPI permissions](https://docs.openshift.com/container-platform/latest/installing/installing_aws/installing-aws-account.html)
- A **Route53 public hosted zone** for your `base_domain`
- Service quotas sufficient for your chosen instance types and counts (check EC2 limits in your region)

### Red Hat Pull Secret

1. Go to https://console.redhat.com/openshift/install/pull-secret
2. Download or copy your pull secret
3. Paste it into `terraform.tfvars` as the `pull_secret` value

---

## Quick Start

```bash
# 1. Clone and enter the project
cd 1-ocp-on-aws

# 2. Create your variables file
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars          # Fill in required values

# 3. Make scripts executable
chmod +x scripts/*.sh

# 4. Initialise Terraform
terraform init

# 5. Preview the plan
terraform plan

# 6. Install the cluster (30–45 minutes)
terraform apply
```

---

## Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_name` | — | Cluster name (3–28 chars, lowercase) |
| `base_domain` | — | Route53 public hosted zone domain |
| `master_count` | `3` | Number of master nodes: `1` (dev) or `3` (HA) |
| `master_instance_type` | `m5.xlarge` | EC2 type for masters |
| `worker_count` | `3` | Number of worker nodes (min 2) |
| `worker_instance_type` | `m5.large` | EC2 type for workers |
| `aws_region` | `us-east-1` | AWS deployment region |
| `pull_secret` | — | Red Hat pull secret JSON |
| `ssh_public_key` | — | SSH public key for node access |
| `publish` | `External` | `External` or `Internal` |
| `network_type` | `OVNKubernetes` | CNI plugin |
| `ocp_version` | `4.16.3` | OpenShift version |

See [`variables.tf`](variables.tf) for the full list with validation rules and descriptions.

---

## Instance Type Reference

### Master Nodes
| Type | vCPU | RAM | Use case |
|------|------|-----|----------|
| `m5.xlarge` | 4 | 16 GB | Dev / small clusters |
| `m5.2xlarge` | 8 | 32 GB | Production (recommended) |
| `m6i.2xlarge` | 8 | 32 GB | Production (latest gen) |

### Worker Nodes
| Type | vCPU | RAM | Use case |
|------|------|-----|----------|
| `m5.large` | 2 | 8 GB | Dev / light workloads |
| `m5.xlarge` | 4 | 16 GB | General purpose |
| `m6i.xlarge` | 4 | 16 GB | General purpose (latest gen) |
| `c5.2xlarge` | 8 | 16 GB | Compute intensive |
| `r5.xlarge` | 4 | 32 GB | Memory intensive |
| `g4dn.xlarge` | 4 | 16 GB | GPU / AI/ML workloads |

---

## Installation Progress

The installer streams live progress to stdout. You can also tail the log in a second terminal:

```bash
tail -f clusters/<cluster-name>/.openshift_install.log
```

Typical phase timeline:

```
 0–5 min    Infrastructure provisioning (VPC, subnets, security groups)
 5–15 min   Bootstrap node starting, control plane nodes booting
15–25 min   etcd cluster forming, API server starting
25–35 min   Bootstrap complete, worker nodes joining
35–45 min   Operators installing, cluster operators becoming available
```

---

## After Installation

```bash
# Get credentials
./scripts/get-credentials.sh <cluster-name>

# Or use Terraform outputs
terraform output console_url
terraform output -raw kubeadmin_password

# Login with oc
export KUBECONFIG=clusters/<cluster-name>/auth/kubeconfig
oc get nodes
oc get clusteroperators
```

---

## Destroy

Use the provided script to ensure proper cleanup of all AWS resources:

```bash
./scripts/destroy.sh <cluster-name>
```

Do **not** use `terraform destroy` directly — the cluster must be destroyed via `openshift-install destroy cluster` first, otherwise AWS resources (load balancers, Route53 records, S3 buckets) will be orphaned and may block future installs.

---

## Project Structure

```
1-ocp-on-aws/
├── versions.tf                   # Provider version constraints
├── variables.tf                  # All input variables
├── locals.tf                     # Computed values (AZs, URLs, paths)
├── main.tf                       # Core: install-config generation + installer invocation
├── outputs.tf                    # Cluster access outputs
├── terraform.tfvars.example      # Variable template — copy to terraform.tfvars
├── templates/
│   └── install-config.yaml.tpl   # OpenShift install-config template
└── scripts/
    ├── preflight.sh              # Pre-install checks (tools, AWS auth, DNS, quotas)
    ├── get-credentials.sh        # Display cluster login details
    └── destroy.sh                # Safe cluster teardown
```

---

## State Management

For team use, configure the S3 backend in `versions.tf`:

```hcl
backend "s3" {
  bucket         = "my-terraform-state"
  key            = "ocp-on-aws/terraform.tfstate"
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "terraform-state-lock"
}
```

---

## Security Notes

- `terraform.tfvars` is in `.gitignore` — never commit it (contains pull secret and SSH key)
- The `clusters/` directory is in `.gitignore` — it contains `kubeconfig` and `kubeadmin-password`
- `kubeadmin` is a temporary bootstrap user — create proper identity providers and disable kubeadmin post-install
- For production, set `publish = "Internal"` and access the cluster through a VPN or bastion host
